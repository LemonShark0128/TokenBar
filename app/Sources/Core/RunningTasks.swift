import Foundation

/// 本机 Claude Code / Codex 一个还没收轮的轮次（只来自日志的结构字段，不含对话内容）
struct RunningTask: Equatable {
    var provider: ProviderID      // .claudePlan / .codexPlan
    var sessionKey: String        // 文件路径，做稳定排序的次键
    var project: String           // 工作目录最后一段；没有工作目录时「未知项目」
    var model: String?            // 已简写
    var startedAt: Date
    var lastActivity: Date
    var tokens: Int
}

/// 扫描最近改过的会话日志末尾，找出每个会话文件里未收轮的轮次。
/// 只解析 type / timestamp / stop_reason / model / cwd / usage / isSidechain 等结构字段；
/// Claude 的 user 内容只用来比较开头前缀，不保存。结果只在内存里
enum RunningTasks {
    static let staleAfter: TimeInterval = 300
    static let dropAfter: TimeInterval = 1800
    /// 每个文件末尾最多读这么多字节
    static let tailBytes: UInt64 = 2 * 1024 * 1024
    static var unknownProject: String { L("task.unknownProject") }

    /// 只扫 enabled 里的 .claudePlan（claudeDir/projects/<子目录>/*.jsonl）和 .codexPlan（codexSessions/yyyy/MM/dd/*.jsonl）；
    /// 文件修改时间在 30 分钟内才读；去掉最后活动早于 30 分钟的，按开始时间升序、同时间按 sessionKey 升序
    /// cache：App 每 10 或 30 秒扫一次，传同一个缓存，没变的文件不再读（测试不传时每次全读）
    static func scan(enabled: Set<ProviderID>, claudeDir: URL, codexSessions: URL, now: Date,
                     cache: RunningTasksCache? = nil, fileManager fm: FileManager = .default) -> [RunningTask] {
        scanDetailed(enabled: enabled, claudeDir: claudeDir, codexSessions: codexSessions, now: now, cache: cache, fileManager: fm).tasks
    }

    /// 同 scan，另外给出各平台会话日志最近一次修改时间（30 分钟内改过的才算；刷新频率按它判断有没有在用）
    static func scanDetailed(enabled: Set<ProviderID>, claudeDir: URL, codexSessions: URL, now: Date,
                             cache: RunningTasksCache? = nil,
                             fileManager fm: FileManager = .default) -> (tasks: [RunningTask], lastChange: [ProviderID: Date]) {
        var items: [(url: URL, parse: (URL) -> RunningTask?)] = []
        var lastChange: [ProviderID: Date] = [:]
        if enabled.contains(.claudePlan) {
            let projects = claudeDir.appendingPathComponent("projects", isDirectory: true)
            let files = LocalAgentUsage.subdirectories(projects, fm).flatMap { LocalAgentUsage.jsonlFiles(in: $0, fm) }
            let f = fresh(files, now: now, fm)
            lastChange[.claudePlan] = f.map(\.mtime).max()
            items += f.map { ($0.url, { Self.claude($0) }) }
        }
        if enabled.contains(.codexPlan) {
            let f = fresh(codexFiles(codexSessions, now: now, fm), now: now, fm)
            lastChange[.codexPlan] = f.map(\.mtime).max()
            items += f.map { ($0.url, { Self.codex($0) }) }
        }
        // 每个文件读完立刻释放读进来的数据（不然一轮扫描的临时对象要等整轮结束才放）
        let out = cache?.tasks(items, fm) ?? items.compactMap { it in autoreleasepool { it.parse(it.url) } }
        let tasks = out.filter { now.timeIntervalSince($0.lastActivity) < dropAfter }
            .sorted { $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.sessionKey < $1.sessionKey }
        return (tasks, lastChange)
    }

    /// claude-opus-4-7 → opus 4.7；claude-sonnet-4-5-20250929 → sonnet 4.5；不是 claude- 开头的原样
    static func shortModel(_ raw: String) -> String {
        guard raw.hasPrefix("claude-") else { return raw }
        var parts = raw.dropFirst("claude-".count).split(separator: "-").map(String.init)
        // 去掉结尾的日期（8 位数字）
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first else { return raw }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? family : "\(family) \(version)"
    }

    // ---------------------------------------------------------------- 文件

    private static func fresh(_ files: [URL], now: Date, _ fm: FileManager) -> [(url: URL, mtime: Date)] {
        let since = now.addingTimeInterval(-dropAfter)
        return files.compactMap { u in
            guard let m = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date, m >= since else { return nil }
            return (u, m)
        }
    }

    /// Codex 会话文件按开始那天放；续用的旧会话还写在旧目录里，所以遍历全部日期目录，按文件修改时间取最近 8 天的
    private static func codexFiles(_ root: URL, now: Date, _ fm: FileManager) -> [URL] {
        let since = now.addingTimeInterval(-8 * 86400)
        var out: [URL] = []
        for y in LocalAgentUsage.subdirectories(root, fm) {
            for m in LocalAgentUsage.subdirectories(y, fm) {
                for d in LocalAgentUsage.subdirectories(m, fm) {
                    out += LocalAgentUsage.jsonlFiles(in: d, fm).filter { u in
                        let mtime = (try? fm.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? nil
                        return mtime.map { $0 > since } ?? false
                    }
                }
            }
        }
        return out
    }

    private static func lines(_ f: URL, truncated: inout Bool) -> [Data] {
        LocalAgentUsage.tailLines(f, limits: .init(maxFiles: 1, tailBytes: tailBytes), truncated: &truncated)
    }

    private static func date(_ ts: String?) -> Date? {
        guard let ts else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: ts) { return d }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: ts)
    }

    /// 项目名：最近的工作目录；中途 cd 进了子目录时，取读到的范围里出现过的、是它上级的最短目录（会话启动目录）
    private static func project(_ cwds: [String]) -> String {
        guard let latest = cwds.last else { return unknownProject }
        let cwd = cwds.filter { latest == $0 || latest.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .min { $0.count < $1.count } ?? latest
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? unknownProject : name
    }

    // ---------------------------------------------------------------- Claude Code

    /// 每行都解的结构字段；message.content 不在这里解
    private struct ClaudeLine: Decodable {
        /// 「已写」只算输出 token（输入和缓存读取每调一次工具都重算一遍，累加起来不像「用了多少」）
        struct Usage: Decodable { var output_tokens: Int? }
        struct Message: Decodable {
            var id: String?
            var model: String?
            var stop_reason: String?
            var usage: Usage?
        }
        var type: String?
        var timestamp: String?
        var isSidechain: Bool?
        var cwd: String?
        var requestId: String?
        var message: Message?
    }

    /// 只在 user 行上解 content，判断「全是工具结果」和开头前缀
    private struct ClaudeUserLine: Decodable {
        struct Block: Decodable { var type: String?; var text: String? }
        enum Content: Decodable {
            case text(String), blocks([Block])
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .text(s) } else { self = .blocks(try c.decode([Block].self)) }
            }
        }
        struct Message: Decodable { var content: Content? }
        var message: Message?
    }

    private enum UserKind { case prompt, toolResult, closes }

    private static let closingStops: Set<String> = ["end_turn", "stop_sequence", "max_tokens", "refusal"]
    private static let closingPrefixes = ["[Request interrupted by user", "<local-command-std"]

    private static func userKind(_ line: Data, _ dec: JSONDecoder) -> UserKind {
        guard let u = try? dec.decode(ClaudeUserLine.self, from: line), let content = u.message?.content else { return .prompt }
        let text: String?
        switch content {
        case .text(let s): text = s
        case .blocks(let bs):
            if !bs.isEmpty, bs.allSatisfy({ $0.type == "tool_result" }) { return .toolResult }
            text = bs.first { $0.type == "text" }?.text
        }
        if let text, closingPrefixes.contains(where: { text.hasPrefix($0) }) { return .closes }
        return .prompt
    }

    private static func claude(_ f: URL) -> RunningTask? {
        var truncated = false
        let all = lines(f, truncated: &truncated)
        let dec = JSONDecoder()
        var open = false
        // 截断时还不知道开头在不在读到的范围里：第一条主线回复之前没见到开轮 / 收轮，就当作进行中
        var unknown = truncated
        var firstSeen: Date?
        var start: Date?, last: Date?
        var model: String?, cwds: [String] = []
        var usage: [String: Int] = [:]
        var anonymous = 0
        func reset() { start = nil; model = nil; usage = [:] }
        for line in all {
            guard let l = try? dec.decode(ClaudeLine.self, from: line) else { continue }
            let t = date(l.timestamp)
            if let t, firstSeen == nil { firstSeen = t }
            if let c = l.cwd, !c.isEmpty, cwds.last != c { cwds.append(c) }
            let side = l.isSidechain == true
            switch l.type {
            case "user" where !side:
                switch userKind(line, dec) {
                case .closes: open = false; unknown = false; reset()
                case .prompt where !open:
                    open = true; unknown = false; reset(); start = t
                default: break
                }
            case "assistant":
                if !side, !open, unknown { open = true; start = firstSeen }
                if !side { unknown = false }
                guard open, let m = l.message else { break }
                if let n = m.usage?.output_tokens {
                    let k: String
                    if let id = m.id ?? l.requestId { k = id } else { anonymous += 1; k = "#\(anonymous)" }
                    usage[k] = n
                }
                if !side, let raw = m.model, raw != "<synthetic>" { model = shortModel(raw) }
                if !side, let s = m.stop_reason, closingStops.contains(s) { open = false; reset() }
            default: break
            }
            if open, let t { last = t }
        }
        guard open, let start, let last else { return nil }
        return RunningTask(provider: .claudePlan, sessionKey: f.path, project: project(cwds), model: model,
                           startedAt: start, lastActivity: max(start, last), tokens: usage.values.reduce(0, +))
    }

    // ---------------------------------------------------------------- Codex

    private struct CodexLine: Decodable {
        struct Total: Decodable { var output_tokens: Int? }
        struct Info: Decodable { var total_token_usage: Total? }
        struct Payload: Decodable {
            var type: String?
            var model: String?
            var cwd: String?
            var info: Info?
        }
        var timestamp: String?
        var type: String?
        var payload: Payload?
    }

    private static func codex(_ f: URL) -> RunningTask? {
        var truncated = false
        let all = lines(f, truncated: &truncated)
        let dec = JSONDecoder()
        var open = false, unknown = truncated
        var firstSeen: Date?, start: Date?, last: Date?
        var model: String?, cwd: String?
        // 读全文时累计值从 0 起算；截断时第一条累计值只当起点
        var total: Int? = truncated ? nil : 0
        var base: Int?
        for line in all {
            guard let l = try? dec.decode(CodexLine.self, from: line) else { continue }
            let t = date(l.timestamp)
            if let t, firstSeen == nil { firstSeen = t }
            if l.type == "turn_context" {
                if let m = l.payload?.model, !m.isEmpty { model = m }
                if let c = l.payload?.cwd, !c.isEmpty { cwd = c }
            } else if l.type == "event_msg" {
                switch l.payload?.type {
                case "task_started":
                    open = true; unknown = false; start = t; base = total
                case "task_complete", "turn_aborted":
                    open = false; unknown = false
                case "token_count":
                    if let n = l.payload?.info?.total_token_usage?.output_tokens {
                        if !open, unknown { open = true; unknown = false; start = firstSeen; base = total ?? n }
                        if open, base == nil { base = total ?? n }
                        total = n
                    }
                default: break
                }
            }
            if open, let t { last = t }
        }
        guard open, let start, let last else { return nil }
        let tokens = max(0, (total ?? 0) - (base ?? 0))
        return RunningTask(provider: .codexPlan, sessionKey: f.path, project: project(cwd.map { [$0] } ?? []), model: model,
                           startedAt: start, lastActivity: max(start, last), tokens: tokens)
    }
}

/// 正在跑的任务的显示文字（纯函数，界面和读屏共用）
enum RunningTaskText {
    static let maxShown = 3

    static func isStale(_ t: RunningTask, now: Date) -> Bool {
        now.timeIntervalSince(t.lastActivity) >= RunningTasks.staleAfter
    }

    private static func elapsed(_ t: RunningTask, now: Date) -> Int { max(0, Int(now.timeIntervalSince(t.startedAt))) }
    private static func stoppedMinutes(_ t: RunningTask, now: Date) -> Int { max(0, Int(now.timeIntervalSince(t.lastActivity)) / 60) }

    /// 「12:04」「1:02:04」；停住时「停了 7 分钟」
    static func clock(_ t: RunningTask, now: Date) -> String {
        if isStale(t, now: now) { return L("task.stoppedMin", stoppedMinutes(t, now: now)) }
        let e = elapsed(t, now: now)
        let h = e / 3600, m = e % 3600 / 60, s = e % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 999 → 999，1000 → 1k，18234 → 18.2k，1340000 → 1.3M
    static func tokens(_ n: Int) -> String {
        func one(_ v: Double) -> String {
            let s = String(format: "%.1f", v)
            return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        }
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return one(Double(n) / 1000) + "k" }
        return one(Double(n) / 1_000_000) + "M"
    }

    /// 「opus 4.7 · 已写 18.2k」；不知道模型时「已写 18.2k」
    static func detail(_ t: RunningTask) -> String {
        let tok = L("task.written", tokens(t.tokens))
        return t.model.map { "\($0) · \(tok)" } ?? tok
    }

    static func visible(_ tasks: [RunningTask]) -> (shown: [RunningTask], more: Int) {
        (Array(tasks.prefix(maxShown)), max(0, tasks.count - maxShown))
    }

    static func header(count: Int) -> String { L("task.header", count) }
    static func moreLine(_ more: Int) -> String { L("task.more", more) }
    static func tooltipLine(count: Int) -> String? { count > 0 ? L("task.tooltip", count) : nil }

    /// 「Claude，token-dashboard，已跑 12 分钟，opus 4.7，已写 2万 token」
    static func a11y(_ t: RunningTask, now: Date) -> String {
        let name = t.provider == .codexPlan ? "Codex" : "Claude"
        let time = isStale(t, now: now) ? L("task.stoppedMin", stoppedMinutes(t, now: now)) : L("task.ranMin", elapsed(t, now: now) / 60)
        return ([name, t.project, time] + (t.model.map { [$0] } ?? []) + [L("task.writtenTokens", cnCount(t.tokens))]).joined(separator: L("a11y.sep"))
    }
}

/// 正在跑的任务的逐文件缓存：路径 + 修改时间 + 大小都没变就用上次的结果，不打开文件；
/// 本轮没列到的文件（超过 30 分钟没动、被删）从缓存里清掉。由 UsageModel 持有，内部加锁
/// @unchecked Sendable：所有可变状态只在 lock 里读写
final class RunningTasksCache: @unchecked Sendable {
    private struct Entry { var mtime: Date; var size: UInt64; var task: RunningTask? }
    private let lock = NSLock()
    private var store: [String: Entry] = [:]
    private var parsed = 0

    init() {}

    /// 累计实际读了多少个文件（测试用）
    var parsedFileCount: Int { lock.withLock { parsed } }
    /// 当前缓存了多少个文件（测试用）
    var cachedFileCount: Int { lock.withLock { store.count } }

    func tasks(_ items: [(url: URL, parse: (URL) -> RunningTask?)], _ fm: FileManager) -> [RunningTask] {
        lock.withLock {
            var next: [String: Entry] = [:]
            var out: [RunningTask] = []
            for it in items {
                let a = try? fm.attributesOfItem(atPath: it.url.path)
                let mtime = a?[.modificationDate] as? Date ?? .distantPast
                let size = (a?[.size] as? NSNumber)?.uint64Value ?? 0
                let e: Entry
                if let hit = store[it.url.path], hit.mtime == mtime, hit.size == size {
                    e = hit
                } else {
                    e = Entry(mtime: mtime, size: size, task: autoreleasepool { it.parse(it.url) })
                    parsed += 1
                }
                next[it.url.path] = e
                if let t = e.task { out.append(t) }
            }
            store = next
            return out
        }
    }
}
