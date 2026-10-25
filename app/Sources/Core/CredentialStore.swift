import Foundation
import Security

/// 读钥匙串的结果：「没有这一项」和「读不出来（拒绝授权、钥匙串锁着…）」要分开，后者不能当成没添加过
enum CredentialRead: Equatable {
    case found(Credentials)
    case notFound
    case error(Int32)
}

/// 凭据只存钥匙串；界面和平台模块都只通过这个协议读写
protocol CredentialStore: Sendable {
    func read(_ p: ProviderID) -> CredentialRead
    func save(_ c: Credentials, for p: ProviderID) throws
    func delete(_ p: ProviderID) throws
    /// 用户主动保存（重新登录、添加平台）前调用：清掉本次启动记住的读取失败，下次 read 重新访问钥匙串
    func clearFailure()
}

extension CredentialStore {
    func clearFailure() {}

    func load(_ p: ProviderID) -> Credentials? {
        if case .found(let c) = read(p) { return c }
        return nil
    }
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { L("keychain.error", status) }
}

/// 钥匙串的四个底层操作；默认直连系统，测试可注入替身模拟失败
protocol KeychainOperations: Sendable {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
    func add(_ query: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainOperations: KeychainOperations {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        return (status, out)
    }
    func add(_ query: [String: Any]) -> OSStatus { SecItemAdd(query as CFDictionary, nil) }
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// 所有平台的凭据合在钥匙串的一条通用密码里：service = "<前缀>.all"，account = "credentials"，
/// 值是 JSON：{"version":1,"providers":{"deepseek":{"apiKey":"…"},…}}。
/// 为什么合并：App 是 ad-hoc 签名，每次重装或更新签名都会变，钥匙串会对每一条逐个弹框问授权；
/// 合成一条后每次重装只问一次。
///
/// - 一次启动只读一次钥匙串：第一次读成功后整份缓存在内存里，之后的 read 都走内存；
///   save / delete 对整条做「读-改-写」，写成功后才更新内存缓存。
/// - 读合并条目被拒（除「没有这一条」和「暂时不允许交互」外的状态）：本次启动记住这个失败，
///   之后的 read 直接返回同一个 .error，不再逐个平台弹框；save / delete（用户主动操作）和 clearFailure 会清掉它再试。
/// - JSON 解不开：read 返回 .error、不动它；save / delete 时先把坏条目备份到 "<前缀>.all.corrupt"，再写新条目。
///   version 比本版本新时照读 providers（降级兼容）。
/// - 迁移：合并条目不存在、且从没写出过合并条目时，按旧存法（service = "<前缀>.<平台>"，account = 键名）
///   只读「添加过」的平台的旧条目（一个「添加过」标记都没有的老安装读全部平台），读到了就写出合并条目，写成功才缓存；旧条目先不删，记下哪些平台还有旧条目，
///   移除这些平台时才去删。写出过合并条目后它又不见了（被外部删掉）就按空处理，不再迁移，免得旧 key 复活。
/// @unchecked Sendable：可变的 cache / failure 只在 lock 里读写，其余属性都是常量
final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    /// 已知的凭据键；迁移旧条目时逐个读取（旧式文件钥匙串不支持「一次取回全部条目的数据」）
    static let knownKeys = ["apiKey", "webToken", "adminKey", "subjectId", "webTokenExpiresAt"]
    static let mergedAccount = "credentials"
    static let formatVersion = 1
    static let mergedWrittenKey = "credentials.mergedWritten"
    static func legacyLeftKey(_ p: ProviderID) -> String { "credentials.legacyLeft.\(p.rawValue)" }
    let servicePrefix: String
    let ops: any KeychainOperations
    let defaults: UserDefaults
    /// 写钥匙串失败时记一行（只记状态码，不记凭据）
    let failures: WriteFailureLog

    private let lock = NSLock()
    /// 内存里的整份凭据：平台原始名 → 键 → 值（用字符串作键，保留本版本不认识的平台，写回时不丢）
    private var cache: [String: [String: String]]?
    /// 本次启动记住的读取失败（拒绝授权、JSON 坏了等），避免同一次启动反复弹框
    private var failure: LoadFailure?

    init(servicePrefix: String = "com.lemon.deepseek-tokenbar", ops: any KeychainOperations = SystemKeychainOperations(),
         defaults: UserDefaults = .standard, failures: WriteFailureLog = .shared) {
        self.servicePrefix = servicePrefix
        self.ops = ops
        self.defaults = defaults
        self.failures = failures
    }

    private var mergedService: String { "\(servicePrefix).all" }
    private func legacyService(_ p: ProviderID) -> String { "\(servicePrefix).\(p.rawValue)" }

    private struct Stored: Codable {
        var version: Int
        var providers: [String: [String: String]]
    }

    private enum LoadFailure: Error {
        case keychain(OSStatus)
        case corrupt(Data)
        var status: OSStatus {
            switch self {
            case .keychain(let s): return s
            case .corrupt: return errSecDecode
            }
        }
    }

    private var mergedQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: mergedService,
            kSecAttrAccount as String: Self.mergedAccount,
        ]
    }

    // MARK: 协议

    func read(_ p: ProviderID) -> CredentialRead {
        lock.lock(); defer { lock.unlock() }
        switch loadState() {
        case .failure(let e):
            return .error(e.status)
        case .success(let all):
            guard let values = all[p.rawValue], !values.isEmpty else { return .notFound }
            return .found(Credentials(values: values))
        }
    }

    func clearFailure() {
        lock.lock(); defer { lock.unlock() }
        failure = nil
    }

    /// 整体替换这个平台的凭据：整条一次写入，失败抛错，钥匙串和内存里原来的值都不变
    func save(_ c: Credentials, for p: ProviderID) throws {
        lock.lock(); defer { lock.unlock() }
        var all = try loadForWrite().all
        if c.values.isEmpty { all[p.rawValue] = nil } else { all[p.rawValue] = c.values }
        try writeMerged(all)
        cache = all
    }

    /// 从合并条目里去掉这个平台并写回；这个平台还有旧条目时再尽力删掉（忽略错误），
    /// 保证「移除平台会从钥匙串删除凭据」仍然成立
    func delete(_ p: ProviderID) throws {
        lock.lock(); defer { lock.unlock() }
        let (loaded, recovered) = try loadForWrite()
        var all = loaded
        if all[p.rawValue] != nil || recovered {
            all[p.rawValue] = nil
            try writeMerged(all)
            cache = all
        }
        guard defaults.bool(forKey: Self.legacyLeftKey(p)) else { return }
        for key in Self.knownKeys {
            var q: [String: Any] = mergedQuery
            q[kSecAttrService as String] = legacyService(p)
            q[kSecAttrAccount as String] = key
            _ = ops.delete(q)
        }
        defaults.removeObject(forKey: Self.legacyLeftKey(p))
    }

    // MARK: 内部（调用方须已持锁）

    /// 用户主动写入：清掉记住的失败再读一次；合并条目坏了就先备份，再从空状态开始写（recovered = true）
    private func loadForWrite() throws -> (all: [String: [String: String]], recovered: Bool) {
        failure = nil
        switch loadState() {
        case .success(let all):
            return (all, false)
        case .failure(.corrupt(let bad)):
            backupCorrupt(bad)
            failure = nil
            return ([:], true)
        case .failure(let e):
            throw KeychainError(status: e.status)
        }
    }

    /// 把解不开的合并条目原样存到 "<前缀>.all.corrupt"（尽力而为，失败不影响写新条目）
    private func backupCorrupt(_ bad: Data) {
        var q = mergedQuery
        q[kSecAttrService as String] = "\(mergedService).corrupt"
        var status = ops.update(q, [kSecValueData as String: bad])
        if status == errSecItemNotFound {
            q[kSecValueData as String] = bad
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = ops.add(q)
        }
        if status != errSecSuccess { failures.failed("钥匙串备份坏条目", KeychainError(status: status)) }
    }

    /// 取整份凭据：有缓存用缓存；记住了失败就直接返回；否则读合并条目，没有就迁移旧条目。
    private func loadState() -> Result<[String: [String: String]], LoadFailure> {
        if let cache { return .success(cache) }
        if let failure { return .failure(failure) }
        var q = mergedQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, out) = ops.copyMatching(q)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data,
                  let stored = try? JSONDecoder().decode(Stored.self, from: data),
                  stored.version >= Self.formatVersion else {
                return remember(.corrupt(out as? Data ?? Data()))   // 被外部改坏：只读时不覆盖
            }
            cache = stored.providers
            return .success(stored.providers)
        case errSecItemNotFound:
            if defaults.bool(forKey: Self.mergedWrittenKey) {
                cache = [:]                     // 写出过又不见了：按空处理，不再迁移
                return .success([:])
            }
            return migrateLegacy()
        default:
            return remember(.keychain(status))  // 拒绝授权等：不是「没添加」
        }
    }

    /// 记住失败；「暂时不允许交互」（钥匙串锁着、无界面）不记，下次再试
    private func remember(_ f: LoadFailure) -> Result<[String: [String: String]], LoadFailure> {
        if f.status != errSecInteractionNotAllowed { failure = f }
        return .failure(f)
    }

    /// 按旧存法逐个读「添加过」的平台的旧条目（每个平台每个键一条）；读到了就写出合并条目
    private func migrateLegacy() -> Result<[String: [String: String]], LoadFailure> {
        var all: [String: [String: String]] = [:]
        // 早于「添加过」标记的老安装一个标记都没有：照旧迁移全部平台
        let flagged = ProviderID.allCases.contains { defaults.object(forKey: "accountAdded.\($0.rawValue)") != nil }
        for p in ProviderID.allCases where !flagged || defaults.bool(forKey: "accountAdded.\(p.rawValue)") {
            for key in Self.knownKeys {
                var q = mergedQuery
                q[kSecAttrService as String] = legacyService(p)
                q[kSecAttrAccount as String] = key
                q[kSecReturnData as String] = true
                q[kSecMatchLimit as String] = kSecMatchLimitOne
                let (status, out) = ops.copyMatching(q)
                switch status {
                case errSecSuccess:
                    if let data = out as? Data, let s = String(data: data, encoding: .utf8) {
                        all[p.rawValue, default: [:]][key] = s
                    }
                case errSecItemNotFound:
                    continue
                default:
                    return remember(.keychain(status))   // 不写合并条目
                }
            }
        }
        if !all.isEmpty {
            do { try writeMerged(all) } catch let e as KeychainError { return .failure(.keychain(e.status)) } catch {
                return .failure(.keychain(errSecIO))
            }
            for id in all.keys { defaults.set(true, forKey: "credentials.legacyLeft.\(id)") }   // 同 legacyLeftKey
        }
        cache = all   // 都没有就缓存空状态，不写钥匙串
        return .success(all)
    }

    /// 整条写入：已有用 update，没有再 add（AfterFirstUnlock）；成功后记下「写出过合并条目」
    private func writeMerged(_ all: [String: [String: String]]) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(Stored(version: Self.formatVersion, providers: all))
        } catch {
            throw KeychainError(status: errSecParam)
        }
        let q = mergedQuery
        var status = ops.update(q, [kSecValueData as String: data])
        if status == errSecItemNotFound {
            var addQuery = q
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = ops.add(addQuery)
        }
        guard status == errSecSuccess else {
            failures.failed("钥匙串写入", KeychainError(status: status))
            throw KeychainError(status: status)
        }
        failures.succeeded("钥匙串写入")
        defaults.set(true, forKey: Self.mergedWrittenKey)
    }
}

/// 测试与预览用。@unchecked Sendable：items 只在 lock 里读写
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ProviderID: Credentials] = [:]
    func read(_ p: ProviderID) -> CredentialRead { lock.withLock { items[p].map { .found($0) } ?? .notFound } }
    func save(_ c: Credentials, for p: ProviderID) throws { lock.withLock { items[p] = c } }
    func delete(_ p: ProviderID) throws { lock.withLock { items[p] = nil } }
}
