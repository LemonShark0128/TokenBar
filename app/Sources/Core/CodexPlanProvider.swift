import Foundation

/// Codex 套餐：读本地会话日志（~/.codex/sessions/yyyy/MM/dd/*.jsonl）里最近一条 token_count 事件的 rate_limits。
/// 不联网、不登录，也不碰 auth.json；日志里只解析 rate_limits 与时间戳，其余内容不保存、不写日志。
struct CodexPlanProvider: UsageProvider {
    private let root: @Sendable () -> URL
    /// 只用共享实例（系统文档：FileManager.default 可以在多个线程上同时用）；不存成属性，provider 才是真正的 Sendable
    private var fileManager: FileManager { .default }

    init(root: @escaping @Sendable () -> URL = { AgentDirs.current.codexSessions }) {
        self.root = root
    }

    init(root: URL) { self.root = { root } }

    var id: ProviderID { .codexPlan }
    var displayName: String { L("provider.codexPlan") }
    var capabilities: Capabilities {
        Capabilities(hasBalance: false, currency: .cny, minPollInterval: 60, dayBoundary: .local,
                     meter: .quota, needsCredentials: false)
    }
    var loginSteps: [LoginStep] { [] }

    func validate(_ c: Credentials) async -> ValidationResult { .ok(summary: "") }

    /// 每个文件只读末尾这么多字节；最多看最近修改的这么多个文件
    static let tailBytes: UInt64 = 256 * 1024
    static let maxFiles = 5
    static var noDataNote: String { L("codex.noDataNote") }

    func fetch(_ c: Credentials, now: Date, timeZone: TimeZone) async -> Result<ProviderSnapshot, ProviderError> {
        let root = root()
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            var s = Self.emptySnapshot(now: now)
            s.quotaNote = L("codex.noLogsNote")
            return .success(s)
        }
        // 会话文件按开始那天放进「年/月/日」目录；续用的旧会话还写在旧目录里，所以遍历全部日期目录、
        // 按文件修改时间取最近 8 天的（目录和文件都不多）
        let since = now.addingTimeInterval(-8 * 86400)
        var files: [(url: URL, mtime: Date)] = []
        func names(_ dir: URL) -> [String] {
            ((try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }
        for y in names(root) {
            for m in names(root.appendingPathComponent(y)) {
                for d in names(root.appendingPathComponent(y).appendingPathComponent(m)) {
                    let dir = root.appendingPathComponent(y).appendingPathComponent(m).appendingPathComponent(d, isDirectory: true)
                    for n in names(dir) where n.hasSuffix(".jsonl") {
                        let u = dir.appendingPathComponent(n)
                        let mtime = (try? fileManager.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? nil
                        guard let mtime, mtime > since else { continue }
                        files.append((u, mtime))
                    }
                }
            }
        }
        files.sort { $0.mtime > $1.mtime }

        // 几个会话同时跑时，最后修改的文件里的额度记录不一定最新：每个文件取最后一条，再挑观测时间最新的
        var best: Quota?
        var firstUnreadablePath: String?
        for f in files.prefix(Self.maxFiles) {
            let tail: Data
            let dropFirst: Bool
            do {
                let h = try FileHandle(forReadingFrom: f.url)
                defer { try? h.close() }
                let size = try h.seekToEnd()
                let start = size > Self.tailBytes ? size - Self.tailBytes : 0
                try h.seek(toOffset: start)
                tail = try h.readToEnd() ?? Data()
                dropFirst = start > 0
            } catch {
                if firstUnreadablePath == nil { firstUnreadablePath = f.url.path }
                continue
            }
            var lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
            if dropFirst, !lines.isEmpty { lines.removeFirst() }
            let key = Data("\"rate_limits\"".utf8)
            fileLoop: for line in lines.reversed() where line.range(of: key) != nil {
                switch Self.parseRateLimitLine(line, fallbackObservedAt: f.mtime) {
                case .failure(let e): return .failure(e)
                case .success(let q?):
                    if best.map({ q.observedAt > $0.observedAt }) ?? true { best = q }
                    break fileLoop
                case .success(nil): continue
                }
            }
        }
        if let q = best {
            var s = Self.emptySnapshot(now: now)
            s.quota = q
            return .success(s)
        }
        if let path = firstUnreadablePath {
            return .failure(.unavailable(L("provider.cantRead", path)))
        }
        var s = Self.emptySnapshot(now: now)
        s.quotaNote = Self.noDataNote
        return .success(s)
    }

    private static func emptySnapshot(now: Date) -> ProviderSnapshot {
        ProviderSnapshot(provider: .codexPlan, balance: nil, today: nil, month: nil, byModel: [],
                         trend7: [], source: .quota, fetchedAt: now, credential: .ok)
    }

    /// 解析一行日志里的 rate_limits。不是 codex 额度行（premium、没有 primary、不是 JSON）返回 .success(nil) 表示跳过；
    /// codex 行但缺 used_percent 返回 schemaChanged。
    static func parseRateLimitLine(_ line: Data, fallbackObservedAt: Date = Date(timeIntervalSince1970: 0)) -> Result<Quota?, ProviderError> {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let rl = payload["rate_limits"] as? [String: Any],
              (rl["limit_id"] as? String) == "codex",
              let primary = rl["primary"] as? [String: Any] else { return .success(nil) }
        let broken = ProviderError.schemaChanged(L("codex.formatChanged"))

        func window(_ o: [String: Any], position: Int) -> QuotaWindow? {
            guard let used = (o["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (o["window_minutes"] as? NSNumber)?.intValue
            let kind: QuotaWindow.Kind
            switch minutes {
            case 300: kind = .session
            case 10080: kind = .weekly
            default: kind = position == 0 ? .session : .weekly
            }
            let reset = (o["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return QuotaWindow(kind: kind, usedPercent: used, resetsAt: reset, windowMinutes: minutes)
        }

        guard let p = window(primary, position: 0) else { return .failure(broken) }
        var windows = [p]
        if let sec = rl["secondary"] as? [String: Any] {
            guard let s = window(sec, position: 1) else { return .failure(broken) }
            windows.append(s)
        }
        var observed = fallbackObservedAt
        if let ts = root["timestamp"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: ts) { observed = d }
            else {
                f.formatOptions = [.withInternetDateTime]
                if let d = f.date(from: ts) { observed = d }
            }
        }
        return .success(Quota(plan: rl["plan_type"] as? String, windows: windows, observedAt: observed))
    }
}
