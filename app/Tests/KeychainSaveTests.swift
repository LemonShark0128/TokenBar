import Foundation
import Security

/// 内存版钥匙串操作替身：按 service + account 存值，可模拟写入失败
final class FakeKeychainOperations: KeychainOperations, @unchecked Sendable {
    var items: [String: Data] = [:]
    var failAdd = false
    var failUpdate = false
    var calls: [String] = []
    /// copyMatching 被调用的次数与依次查询的「service|account」
    var copyCount = 0
    var copyLog: [String] = []
    /// 按「service|account」强行返回某个状态（模拟拒绝授权、钥匙串锁着等）
    var copyStatus: [String: OSStatus] = [:]

    private func key(_ q: [String: Any]) -> String {
        "\(q[kSecAttrService as String] as? String ?? "")|\(q[kSecAttrAccount as String] as? String ?? "")"
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        copyCount += 1
        copyLog.append(key(query))
        if let st = copyStatus[key(query)] { return (st, nil) }
        guard let d = items[key(query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, d as CFData)
    }
    func add(_ query: [String: Any]) -> OSStatus {
        calls.append("add:\(query[kSecAttrAccount as String] as? String ?? "")")
        if failAdd { return errSecIO }
        let k = key(query)
        if items[k] != nil { return errSecDuplicateItem }
        items[k] = query[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        calls.append("update:\(query[kSecAttrAccount as String] as? String ?? "")")
        if failUpdate { return errSecIO }
        let k = key(query)
        guard items[k] != nil else { return errSecItemNotFound }
        items[k] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        calls.append("delete:\(query[kSecAttrAccount as String] as? String ?? "")")
        return items.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
    }
}

@MainActor
func registerKeychainSaveTests() {
    func make() -> (FakeKeychainOperations, KeychainCredentialStore) {
        let ops = FakeKeychainOperations()
        return (ops, KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: freshDefaults()))
    }
    /// 迁移只导入「添加过」的平台：测试里先把这些平台标成添加过
    func addedDefaults(_ ids: [ProviderID] = ProviderID.allCases) -> UserDefaults {
        let d = freshDefaults()
        for id in ids { d.set(true, forKey: "accountAdded.\(id.rawValue)") }
        return d
    }
    let merged = "fake.all|credentials"
    /// 解出替身里合并条目的 providers 部分
    func mergedProviders(_ ops: FakeKeychainOperations) throws -> [String: [String: String]] {
        guard let d = ops.items[merged],
              let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw TestFailure(description: "替身里没有可解析的合并条目")
        }
        try check(obj["version"] as? Int == 1, "version 应为 1：\(obj)")
        return obj["providers"] as? [String: [String: String]] ?? [:]
    }

    test("keychainSaveFailureKeepsOldKey") {
        let (ops, s) = make()
        try s.save(Credentials(values: ["apiKey": "sk-old-0000"]), for: .deepseek)
        ops.failAdd = true
        ops.failUpdate = true
        var threw = false
        do { try s.save(Credentials(values: ["apiKey": "sk-new-1111"]), for: .deepseek) } catch { threw = true }
        try check(threw, "写入失败应抛错")
        try checkEqual(s.load(.deepseek), Credentials(values: ["apiKey": "sk-old-0000"]))
    }
    // 合并成一条后整条一次写入：更新失败时原来的各个键（含 webToken）都应保留
    test("keychainSaveNewKeyAddFailureKeepsExistingKeys") {
        let (ops, s) = make()
        try s.save(Credentials(values: ["apiKey": "sk-old-0000", "webToken": "tok-old"]), for: .deepseek)
        ops.failUpdate = true
        ops.failAdd = true
        do { try s.save(Credentials(values: ["apiKey": "sk-new-1111", "adminKey": "adm-new"]), for: .deepseek) } catch {}
        try check(s.load(.deepseek)?.values["webToken"] == "tok-old", "写入失败时不应丢掉旧的 webToken")
        try checkEqual(try mergedProviders(ops)["deepseek"], ["apiKey": "sk-old-0000", "webToken": "tok-old"])
    }
    test("keychainSaveExistingUsesUpdate") {
        let (ops, s) = make()
        try s.save(Credentials(values: ["apiKey": "sk-old-0000"]), for: .deepseek)
        ops.calls = []
        try s.save(Credentials(values: ["apiKey": "sk-new-1111"]), for: .deepseek)
        try check(ops.calls.contains("update:credentials"), "已有合并条目应走 update：\(ops.calls)")
        try check(!ops.calls.contains { $0.hasPrefix("delete:") }, "不应先删：\(ops.calls)")
        try checkEqual(s.load(.deepseek), Credentials(values: ["apiKey": "sk-new-1111"]))
    }
    test("keychainSaveRemovesStaleKeys") {
        let (_, s) = make()
        try s.save(Credentials(values: ["apiKey": "sk-old-0000", "webToken": "tok-old"]), for: .deepseek)
        try s.save(Credentials(values: ["apiKey": "sk-new-1111"]), for: .deepseek)
        try checkEqual(s.load(.deepseek), Credentials(values: ["apiKey": "sk-new-1111"]))
    }

    // —— 合并成一条通用密码 ——
    test("keychainMergedSingleItemForTwoProviders") {
        let (ops, s) = make()
        try s.save(Credentials(values: ["apiKey": "sk-test-0000"]), for: .deepseek)
        try s.save(Credentials(values: ["apiKey": "sk-test-1111"]), for: .siliconflow)
        try checkEqual(Array(ops.items.keys), [merged])
        try checkEqual(try mergedProviders(ops), ["deepseek": ["apiKey": "sk-test-0000"], "siliconflow": ["apiKey": "sk-test-1111"]])
        // 新实例从钥匙串读回
        let s2 = KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: freshDefaults())
        try checkEqual(s2.load(.deepseek), Credentials(values: ["apiKey": "sk-test-0000"]))
        try checkEqual(s2.load(.siliconflow), Credentials(values: ["apiKey": "sk-test-1111"]))
        try checkEqual(s2.read(.codexPlan), .notFound)
    }
    test("keychainMergedReadsKeychainOnce") {
        let (ops, s) = make()
        try s.save(Credentials(values: ["apiKey": "sk-test-0000"]), for: .deepseek)
        let s2 = KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: freshDefaults())
        ops.copyCount = 0
        for p in ProviderID.allCases { _ = s2.read(p) }
        _ = s2.read(.deepseek)
        _ = s2.read(.claudePlan)
        try checkEqual(ops.copyCount, 1)
        try checkEqual(s2.load(.deepseek), Credentials(values: ["apiKey": "sk-test-0000"]))
    }
    test("keychainMergedSaveAddsAccessibleAfterFirstUnlock") {
        final class Spy: KeychainOperations, @unchecked Sendable {
            let inner = FakeKeychainOperations()
            var lastAdd: [String: Any] = [:]
            func copyMatching(_ q: [String: Any]) -> (OSStatus, CFTypeRef?) { inner.copyMatching(q) }
            func add(_ q: [String: Any]) -> OSStatus { lastAdd = q; return inner.add(q) }
            func update(_ q: [String: Any], _ a: [String: Any]) -> OSStatus { inner.update(q, a) }
            func delete(_ q: [String: Any]) -> OSStatus { inner.delete(q) }
        }
        let spy = Spy()
        let s = KeychainCredentialStore(servicePrefix: "fake", ops: spy, defaults: freshDefaults())
        try s.save(Credentials(values: ["apiKey": "sk-test-0000"]), for: .deepseek)
        try check((spy.lastAdd[kSecAttrAccessible as String] as? String) == (kSecAttrAccessibleAfterFirstUnlock as String),
                  "合并条目应以 AfterFirstUnlock 写入")
        try checkEqual(spy.lastAdd[kSecAttrService as String] as? String, "fake.all")
        try checkEqual(spy.lastAdd[kSecAttrAccount as String] as? String, "credentials")
    }

    // —— 迁移旧条目 ——
    test("keychainMigratesLegacyItemsOnce") {
        let ops = FakeKeychainOperations()
        ops.items["fake.deepseek|apiKey"] = Data("sk-test-0000".utf8)
        ops.items["fake.deepseek|webToken"] = Data("tok-test".utf8)
        ops.items["fake.codexPlan|subjectId"] = Data("sub-test".utf8)
        let defaults = addedDefaults()
        let s = KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: defaults)
        try checkEqual(s.load(.deepseek), Credentials(values: ["apiKey": "sk-test-0000", "webToken": "tok-test"]))
        try checkEqual(s.load(.codexPlan), Credentials(values: ["subjectId": "sub-test"]))
        try checkEqual(s.read(.siliconflow), .notFound)
        // 写出了合并条目，旧条目先不删
        try checkEqual(try mergedProviders(ops), ["deepseek": ["apiKey": "sk-test-0000", "webToken": "tok-test"],
                                                  "codexPlan": ["subjectId": "sub-test"]])
        try check(ops.items["fake.deepseek|apiKey"] != nil && ops.items["fake.codexPlan|subjectId"] != nil, "旧条目应保留")
        // 第二个实例只读合并条目
        let s2 = KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: defaults)
        ops.copyLog = []
        try checkEqual(s2.load(.deepseek), Credentials(values: ["apiKey": "sk-test-0000", "webToken": "tok-test"]))
        try checkEqual(ops.copyLog, [merged])
    }
    test("keychainNoLegacyNoMergedIsEmpty") {
        let (ops, s) = make()
        try checkEqual(s.read(.deepseek), .notFound)
        let n = ops.copyCount
        try checkEqual(s.read(.siliconflow), .notFound)
        try checkEqual(ops.copyCount, n)   // 空状态也缓存，不再访问钥匙串
    }
    // I2：读被拒后本次启动记住失败，不再逐个平台反复弹框；用户主动保存时清掉失败再试
    test("keychainMergedReadDeniedIsCachedUntilSave") {
        let (ops, s) = make()
        ops.items["fake.deepseek|apiKey"] = Data("sk-test-0000".utf8)
        ops.copyStatus[merged] = -128      // 用户点了「拒绝」
        try checkEqual(s.read(.deepseek), .error(-128))
        try checkEqual(ops.copyLog, [merged])          // 不回退去读旧条目
        try check(ops.calls.isEmpty, "不应写任何东西：\(ops.calls)")
        for p in ProviderID.allCases { try checkEqual(s.read(p), .error(-128)) }
        try checkEqual(ops.copyLog, [merged])          // 失败已记住，不再访问钥匙串
        // 用户重新登录：先清掉失败，再试一次；仍被拒则 save 抛错、不覆盖
        s.clearFailure()
        var threw = false
        do { try s.save(Credentials(values: ["apiKey": "sk-test-1111"]), for: .siliconflow) } catch { threw = true }
        try check(threw, "读合并条目失败时 save 应抛错")
        try checkEqual(ops.copyLog, [merged, merged])
        try check(ops.calls.isEmpty, "不应写任何东西：\(ops.calls)")
        // 这次允许了：清掉失败后能读到
        ops.copyStatus = [:]
        ops.items[merged] = Data(#"{"version":1,"providers":{"deepseek":{"apiKey":"sk-test-2222"}}}"#.utf8)
        s.clearFailure()
        try checkEqual(s.load(.deepseek), Credentials(values: ["apiKey": "sk-test-2222"]))
    }
    // 钥匙串锁着、不允许交互（-25308）是暂时的，不记住
    test("keychainInteractionNotAllowedIsNotCached") {
        let (ops, s) = make()
        ops.copyStatus[merged] = errSecInteractionNotAllowed
        try checkEqual(s.read(.deepseek), .error(errSecInteractionNotAllowed))
        ops.copyStatus = [:]
        try checkEqual(s.read(.deepseek), .notFound)
    }
    test("keychainLegacyReadErrorDoesNotWriteMerged") {
        let ops = FakeKeychainOperations()
        let s = KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: addedDefaults())
        ops.items["fake.deepseek|apiKey"] = Data("sk-test-0000".utf8)
        ops.copyStatus["fake.siliconflow|apiKey"] = errSecInteractionNotAllowed
        try checkEqual(s.read(.deepseek), .error(errSecInteractionNotAllowed))
        try check(ops.items[merged] == nil, "迁移出错时不应写合并条目")
        try check(ops.calls.isEmpty, "不应写任何东西：\(ops.calls)")
        // 下次再试：这次能读了就迁移成功
        ops.copyStatus = [:]
        try checkEqual(s.load(.deepseek), Credentials(values: ["apiKey": "sk-test-0000"]))
        try check(ops.items[merged] != nil, "重试成功后应写出合并条目")
    }
    test("keychainMigrationWriteFailureIsErrorNotCached") {
        let ops = FakeKeychainOperations()
        let s = KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: addedDefaults())
        ops.items["fake.deepseek|apiKey"] = Data("sk-test-0000".utf8)
        ops.failAdd = true
        if case .error = s.read(.deepseek) {} else { throw TestFailure(description: "写合并条目失败应返回 .error") }
        ops.failAdd = false
        try checkEqual(s.load(.deepseek), Credentials(values: ["apiKey": "sk-test-0000"]))
        try check(ops.items[merged] != nil)
    }

    // —— 删除 ——
    test("keychainDeleteRemovesFromMergedAndLegacy") {
        let ops = FakeKeychainOperations()
        ops.items["fake.deepseek|apiKey"] = Data("sk-test-0000".utf8)
        ops.items["fake.deepseek|webToken"] = Data("tok-test".utf8)
        ops.items["fake.siliconflow|apiKey"] = Data("sk-test-1111".utf8)
        let defaults = addedDefaults()
        let s = KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: defaults)
        try s.delete(.deepseek)
        try checkEqual(s.read(.deepseek), .notFound)
        try checkEqual(s.load(.siliconflow), Credentials(values: ["apiKey": "sk-test-1111"]))
        try checkEqual(try mergedProviders(ops), ["siliconflow": ["apiKey": "sk-test-1111"]])
        try check(ops.items["fake.deepseek|apiKey"] == nil && ops.items["fake.deepseek|webToken"] == nil, "旧条目也应删掉")
        try check(ops.items["fake.siliconflow|apiKey"] != nil, "另一个平台的旧条目不受影响")
        let s2 = KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: defaults)
        try checkEqual(s2.read(.deepseek), .notFound)
    }
    test("keychainDeleteMissingDoesNotThrow") {
        let (_, s) = make()
        try s.delete(.siliconflow)
        try checkEqual(s.read(.siliconflow), .notFound)
    }

    // —— 合并条目被外部改坏（I1）——
    test("keychainCorruptMergedReadIsErrorButSaveRecovers") {
        let (ops, s) = make()
        let bad = Data("{not json".utf8)
        ops.items[merged] = bad
        if case .error = s.read(.deepseek) {} else { throw TestFailure(description: "JSON 解不开应返回 .error") }
        try checkEqual(ops.items[merged], bad)   // 只读时不动它
        // 用户重新登录：坏条目备份到 .corrupt，再写新条目
        s.clearFailure()
        try s.save(Credentials(values: ["apiKey": "sk-test-0000"]), for: .deepseek)
        try checkEqual(ops.items["fake.all.corrupt|credentials"], bad)
        try checkEqual(try mergedProviders(ops), ["deepseek": ["apiKey": "sk-test-0000"]])
        try checkEqual(s.load(.deepseek), Credentials(values: ["apiKey": "sk-test-0000"]))
    }
    test("keychainCorruptMergedDeleteRecovers") {
        let (ops, s) = make()
        ops.items[merged] = Data("{not json".utf8)
        try s.delete(.deepseek)
        try checkEqual(try mergedProviders(ops), [:])
        try check(ops.items["fake.all.corrupt|credentials"] != nil, "坏条目应先备份")
    }
    // 降级兼容：version 比本版本新时照读 providers
    test("keychainNewerVersionStillReadable") {
        let (ops, s) = make()
        ops.items[merged] = Data(#"{"version":2,"providers":{"deepseek":{"apiKey":"sk-test-0000"}},"extra":true}"#.utf8)
        try checkEqual(s.load(.deepseek), Credentials(values: ["apiKey": "sk-test-0000"]))
    }

    // —— 旧值不复活（I3）——
    test("keychainNoRemigrationAfterMergedWritten") {
        let ops = FakeKeychainOperations()
        ops.items["fake.deepseek|apiKey"] = Data("sk-test-old".utf8)
        let defaults = addedDefaults()
        let s = KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: defaults)
        try s.save(Credentials(values: ["apiKey": "sk-test-new"]), for: .deepseek)
        ops.items[merged] = nil                        // 合并条目被外部删掉
        let s2 = KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: defaults)
        try checkEqual(s2.read(.deepseek), .notFound)  // 不再从旧条目迁移，旧 key 不会写回
        try check(ops.items[merged] == nil, "不应重新写出合并条目")
    }
    test("keychainMigrationOnlyImportsAddedProviders") {
        let ops = FakeKeychainOperations()
        ops.items["fake.deepseek|apiKey"] = Data("sk-test-0000".utf8)
        ops.items["fake.siliconflow|apiKey"] = Data("sk-test-1111".utf8)   // 移除时没删掉的旧条目
        let s = KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: addedDefaults([.deepseek]))
        try checkEqual(s.load(.deepseek), Credentials(values: ["apiKey": "sk-test-0000"]))
        try checkEqual(s.read(.siliconflow), .notFound)
        try checkEqual(try mergedProviders(ops), ["deepseek": ["apiKey": "sk-test-0000"]])
        try check(!ops.copyLog.contains { $0.hasPrefix("fake.siliconflow|") }, "没添加过的平台不读旧条目：\(ops.copyLog)")
    }
    // 早于「添加过」标记的老安装：一个标记都没有时照旧迁移全部平台，免得丢 key
    test("keychainMigrationWithoutAnyAddedFlagImportsAll") {
        let ops = FakeKeychainOperations()
        ops.items["fake.deepseek|apiKey"] = Data("sk-test-0000".utf8)
        let s = KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: freshDefaults())
        try checkEqual(s.load(.deepseek), Credentials(values: ["apiKey": "sk-test-0000"]))
    }
    // M10：只在这个平台还有旧条目时才去删旧条目
    test("keychainDeleteSkipsLegacyWhenNoneLeft") {
        let (ops, s) = make()
        try s.save(Credentials(values: ["apiKey": "sk-test-0000"]), for: .deepseek)
        ops.calls = []
        try s.delete(.deepseek)
        try check(!ops.calls.contains { $0.hasPrefix("delete:") }, "没有旧条目时不应逐条删除：\(ops.calls)")
        // 迁移过的平台删一次后，第二次也不再删
        let ops2 = FakeKeychainOperations()
        ops2.items["fake.deepseek|apiKey"] = Data("sk-test-0000".utf8)
        let s2 = KeychainCredentialStore(servicePrefix: "fake", ops: ops2, defaults: addedDefaults([.deepseek]))
        try s2.delete(.deepseek)
        try check(ops2.calls.contains("delete:apiKey"), "有旧条目时应删除：\(ops2.calls)")
        ops2.calls = []
        try s2.delete(.deepseek)
        try check(!ops2.calls.contains { $0.hasPrefix("delete:") }, "第二次不应再删：\(ops2.calls)")
    }

    // —— 写失败时内存缓存不变 ——
    test("keychainSaveFailureKeepsCache") {
        let (ops, s) = make()
        try s.save(Credentials(values: ["apiKey": "sk-test-0000"]), for: .deepseek)
        ops.failUpdate = true
        ops.failAdd = true
        var threw = false
        do { try s.save(Credentials(values: ["apiKey": "sk-test-1111"]), for: .siliconflow) } catch { threw = true }
        try check(threw, "写入失败应抛错")
        try checkEqual(s.read(.siliconflow), .notFound)
        do { try s.delete(.deepseek) } catch { threw = true }
        try checkEqual(s.load(.deepseek), Credentials(values: ["apiKey": "sk-test-0000"]))
    }
}

/// 第四批第 7 条：按整个 App 启动（UsageStore 刷新所有平台）数钥匙串访问次数。
/// 每次访问一个不归当前签名所有的条目都可能弹一次框，所以次数就是弹框次数的上限
@MainActor
func registerKeychainLaunchCountTests() {
    @MainActor func launch(_ ops: FakeKeychainOperations, _ d: UserDefaults, refreshes: Int = 2) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let samples = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
        let clock = FakeClock()
        let ps = [FakeProvider([.success(snap(clock.now))], id: .deepseek),
                  FakeProvider([.success(snap(clock.now))], id: .siliconflow)]
        let store = UsageStore(providers: ps, credentials: KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: d),
                               samples: samples, intervalSeconds: 120, clock: { clock.now },
                               timeZone: { TimeZone(secondsFromGMT: 28800)! }, defaults: d)
        for _ in 0..<refreshes { await store.refresh() }
    }
    testAsync("keychainOrdinaryLaunchTouchesOneItemOnce") {
        let ops = FakeKeychainOperations(), d = freshDefaults()
        d.set(true, forKey: "accountAdded.deepseek"); d.set(true, forKey: "accountAdded.siliconflow")
        let seed = KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: d)
        try seed.save(Credentials(values: ["apiKey": "sk-test-0000"]), for: .deepseek)
        try seed.save(Credentials(values: ["webToken": "tok-test"]), for: .siliconflow)
        ops.copyCount = 0; ops.copyLog = []
        try await launch(ops, d)
        try checkEqual(ops.copyCount, 1)                     // 平时启动：只读合并条目一次
        try checkEqual(ops.copyLog, ["fake.all|credentials"])
    }
    testAsync("keychainMigrationLaunchThenNextLaunchOnce") {
        // 第一次装合并版：按旧条目逐条读（每条可能问一次）；迁移成功后下次启动只读合并条目一次
        let ops = FakeKeychainOperations(), d = freshDefaults()
        d.set(true, forKey: "accountAdded.deepseek"); d.set(true, forKey: "accountAdded.siliconflow")
        ops.items["fake.deepseek|apiKey"] = Data("sk-test-0000".utf8)
        ops.items["fake.deepseek|webToken"] = Data("tok-test".utf8)
        ops.items["fake.siliconflow|webToken"] = Data("tok-test".utf8)
        try await launch(ops, d)
        let existing = ops.copyLog.filter { ops.items[$0] != nil && $0 != "fake.all|credentials" }
        try checkEqual(existing.count, 3)                   // 只有真实存在的旧条目会弹框：每条一次，不重复
        ops.copyCount = 0; ops.copyLog = []
        try await launch(ops, d)
        try checkEqual(ops.copyLog, ["fake.all|credentials"])
    }
}
