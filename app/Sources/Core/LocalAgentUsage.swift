import Foundation

/// 本地日期（yyyy-MM-dd）→ 模型名 → token 数
typealias DailyModelTokens = [String: [String: Int]]

/// 读本机 Claude Code 和 Codex 的会话日志，只取模型名、token 数和时间戳，汇总成近 7 天「本地日期 × 模型 → token」。
/// 对话内容一律不解码、不保存、不写日志；目录和时钟都由调用方传入（测试用临时目录）。
enum LocalAgentUsage {
    struct Limits: Equatable {
        /// 最多读这么多个文件（按修改时间取最近的）
        var maxFiles: Int
        /// 每个文件最多读末尾这么多字节；截断时丢掉第一行残行
        var tailBytes: UInt64
        static let standard = Limits(maxFiles: 400, tailBytes: 8 * 1024 * 1024)
    }
    /// 只看近 7 天（含今天）
    static let windowDays = 7
    /// Codex 截断后不知道模型名时记成这个
    static let unknownCodexModel = "codex"

    /// 只读添加了的套餐平台：Claude 套餐读 claudeDir，Codex 套餐读 codexSessions。
    /// 传入 cache 时，修改时间和大小都没变的文件直接用上次的解析结果，不再打开；不传时每次全部重读
    static func read(enabled: Set<ProviderID>, claudeDir: URL, codexSessions: URL, now: Date, timeZone: TimeZone,
                     limits: Limits = .standard, cache: LocalUsageCache? = nil) -> [ProviderID: DailyModelTokens] {
        var out: [ProviderID: DailyModelTokens] = [:]
        if enabled.contains(.claudePlan) {
            out[.claudePlan] = claude(root: claudeDir, now: now, timeZone: timeZone, limits: limits, cache: cache)
        } else {
            cache?.clear(.claude)
        }
        if enabled.contains(.codexPlan) {
            out[.codexPlan] = codex(root: codexSessions, now: now, timeZone: timeZone, limits: limits, cache: cache)
        } else {
            cache?.clear(.codex)
        }
        return out
    }

    // ---------------------------------------------------------------- Claude Code

    /// 只声明要用的字段；content 等其余字段不解码
    private struct ClaudeLine: Decodable {
        struct Usage: Decodable {
            var input_tokens: Int?
            var output_tokens: Int?
            var cache_creation_input_tokens: Int?
            var cache_read_input_tokens: Int?
        }
        struct Message: Decodable {
            var id: String?
            var model: String?
            var usage: Usage?
        }
        var type: String?
        var timestamp: String?
        var requestId: String?
        var message: Message?
    }

    /// 一个 Claude 日志文件里的一条用量（与 7 天窗口无关，可缓存）。key 为 nil = message.id 和 requestId 都没有，各自单算
    struct ClaudeEntry: Equatable {
        var key: String?
        var day: String
        var model: String
        var tokens: Int
    }

    /// root = Claude 目录（~/.claude）。读 projects/*/*.jsonl 和 projects/*/*/subagents/*.jsonl
    static func claude(root: URL, now: Date, timeZone: TimeZone, limits: Limits = .standard,
                       cache: LocalUsageCache? = nil, fileManager fm: FileManager = .default) -> DailyModelTokens {
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        var files: [URL] = []
        for p in subdirectories(projects, fm) {
            files += jsonlFiles(in: p, fm)
            for s in subdirectories(p, fm) {
                files += jsonlFiles(in: s.appendingPathComponent("subagents", isDirectory: true), fm)
            }
        }
        let days = DayWindow(now: now, timeZone: timeZone)
        let list = recent(files, now: now, limits: limits, fm)
        let perFile: [[ClaudeEntry]]
        if let cache {
            perFile = cache.claudeEntries(for: list, timeZone: timeZone, limits: limits, minDay: days.minDay) { parseClaude($0, days: days, limits: limits) }
        } else {
            perFile = list.map { parseClaude($0.url, days: days, limits: limits) }
        }
        // 同一条回复会写成多行（也可能跨文件）：按 message.id + requestId 去重，取最后一行（文件按 recent() 的顺序）
        var latest: [String: ClaudeEntry] = [:]
        var order: [String] = []
        var anonymous = 0
        for entries in perFile {
            for e in entries where days.contains(e.day) {
                let k: String
                if let key = e.key { k = key } else { anonymous += 1; k = "#\(anonymous)" }
                if latest[k] == nil { order.append(k) }
                latest[k] = e
            }
        }
        var out: DailyModelTokens = [:]
        for k in order {
            guard let e = latest[k], e.tokens > 0 else { continue }
            out[e.day, default: [:]][e.model, default: 0] += e.tokens
        }
        return out
    }

    /// 解析一个 Claude 日志文件：按行顺序列出每条用量（日期不按窗口过滤，时间戳认不出的丢掉）
    private static func parseClaude(_ f: URL, days: DayWindow, limits: Limits) -> [ClaudeEntry] {
        autoreleasepool { parseClaudeLines(f, days: days, limits: limits) }
    }

    private static func parseClaudeLines(_ f: URL, days: DayWindow, limits: Limits) -> [ClaudeEntry] {
        let key = Data("\"usage\"".utf8)
        let dec = JSONDecoder()
        var out: [ClaudeEntry] = []
        for line in tailLines(f, limits: limits) where line.range(of: key) != nil {
            guard let l = try? dec.decode(ClaudeLine.self, from: line), l.type == "assistant",
                  let m = l.message, let model = m.model, model != "<synthetic>", let u = m.usage,
                  let ts = l.timestamp, let day = days.localDay(of: ts) else { continue }
            let tokens = (u.input_tokens ?? 0) + (u.output_tokens ?? 0)
                + (u.cache_creation_input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0)
            let k: String? = (m.id == nil && l.requestId == nil) ? nil : "\(m.id ?? "")|\(l.requestId ?? "")"
            out.append(ClaudeEntry(key: k, day: day, model: model, tokens: tokens))
        }
        return out
    }

    // ---------------------------------------------------------------- Codex

    /// turn_context（带 model）和 event_msg/token_count（带累计 total_tokens）；其余字段不解码
    private struct CodexLine: Decodable {
        struct Total: Decodable { var total_tokens: Int? }
        struct Info: Decodable { var total_token_usage: Total? }
        struct Payload: Decodable {
            var type: String?
            var model: String?
            var info: Info?
        }
        var timestamp: String?
        var type: String?
        var payload: Payload?
    }

    /// 一个 Codex 日志文件里的一段增量（与 7 天窗口无关，可缓存）
    struct CodexEntry: Equatable {
        var day: String
        var model: String
        var delta: Int
    }

    /// root = ~/.codex/sessions（下面是 yyyy/MM/dd/*.jsonl）。同一会话里 token_count 是累计值，可能重复写：按增量算
    static func codex(root: URL, now: Date, timeZone: TimeZone, limits: Limits = .standard,
                      cache: LocalUsageCache? = nil, fileManager fm: FileManager = .default) -> DailyModelTokens {
        var files: [URL] = []
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                 options: [.skipsHiddenFiles]) {
            for case let u as URL in e where u.pathExtension == "jsonl" { files.append(u) }
        }
        let days = DayWindow(now: now, timeZone: timeZone)
        let list = recent(files, now: now, limits: limits, fm)
        let perFile: [[CodexEntry]]
        if let cache {
            perFile = cache.codexEntries(for: list, timeZone: timeZone, limits: limits, minDay: days.minDay) { parseCodex($0, days: days, limits: limits) }
        } else {
            perFile = list.map { parseCodex($0.url, days: days, limits: limits) }
        }
        var out: DailyModelTokens = [:]
        for entries in perFile {
            for e in entries where days.contains(e.day) {
                out[e.day, default: [:]][e.model, default: 0] += e.delta
            }
        }
        return out
    }

    /// 解析一个 Codex 日志文件：按行顺序列出每段增量（日期不按窗口过滤）
    private static func parseCodex(_ f: URL, days: DayWindow, limits: Limits) -> [CodexEntry] {
        autoreleasepool { parseCodexLines(f, days: days, limits: limits) }
    }

    private static func parseCodexLines(_ f: URL, days: DayWindow, limits: Limits) -> [CodexEntry] {
        let turnKey = Data("\"turn_context\"".utf8), countKey = Data("\"token_count\"".utf8)
        let dec = JSONDecoder()
        var out: [CodexEntry] = []
        var truncated = false
        let lines = tailLines(f, limits: limits, truncated: &truncated)
        var model: String?
        // 读全文时从 0 起算；截断时第一条累计值只当起点（之前的用量不知道属于哪天）
        var last: Int? = truncated ? nil : 0
        for line in lines {
            let isTurn = line.range(of: turnKey) != nil
            guard isTurn || line.range(of: countKey) != nil,
                  let l = try? dec.decode(CodexLine.self, from: line) else { continue }
            if l.type == "turn_context" {
                if let m = l.payload?.model, !m.isEmpty { model = m }
                continue
            }
            guard l.type == "event_msg", l.payload?.type == "token_count",
                  let total = l.payload?.info?.total_token_usage?.total_tokens else { continue }
            defer { last = total }
            guard let prev = last else { continue }
            // 累计值变小（会话重开等）：当作从 0 重新累计
            let delta = total >= prev ? total - prev : total
            guard delta > 0, let ts = l.timestamp, let day = days.localDay(of: ts) else { continue }
            out.append(CodexEntry(day: day, model: model ?? unknownCodexModel, delta: delta))
        }
        return out
    }

    // ---------------------------------------------------------------- 共用

    /// 近 7 天的本地日期集合 + 时间戳 → 本地日期
    private struct DayWindow {
        let days: Set<String>
        let minDay: String
        let fmt: DateFormatter
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        init(now: Date, timeZone: TimeZone) {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            fmt = DateFormatter()
            fmt.calendar = cal
            fmt.timeZone = timeZone
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd"
            let f = fmt
            days = Set((0..<LocalAgentUsage.windowDays).compactMap { back in
                cal.date(byAdding: .day, value: -back, to: now).map { f.string(from: $0) }
            })
            minDay = days.min() ?? f.string(from: now)
            iso.formatOptions = [.withInternetDateTime]
            isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }
        /// 时间戳 → 本地日期（不看窗口；认不出返回 nil）
        func localDay(of ts: String) -> String? {
            guard let d = isoFrac.date(from: ts) ?? iso.date(from: ts) else { return nil }
            return fmt.string(from: d)
        }
        func contains(_ day: String) -> Bool { days.contains(day) }
    }

    static func subdirectories(_ dir: URL, _ fm: FileManager) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    static func jsonlFiles(in dir: URL, _ fm: FileManager) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension == "jsonl" }
    }

    /// 列出来要读的文件：路径 + 修改时间 + 大小（缓存按这三样判断文件变没变）
    struct FileStamp {
        var url: URL
        var mtime: Date
        var size: UInt64
    }

    /// 近 7 天修改过的文件，按修改时间从新到旧，最多 maxFiles 个
    private static func recent(_ files: [URL], now: Date, limits: Limits, _ fm: FileManager) -> [FileStamp] {
        let since = now.addingTimeInterval(-TimeInterval(windowDays) * 86400)
        let dated: [FileStamp] = files.compactMap { u in
            guard let a = try? fm.attributesOfItem(atPath: u.path),
                  let m = a[.modificationDate] as? Date, m >= since else { return nil }
            let size = (a[.size] as? NSNumber)?.uint64Value ?? 0
            return FileStamp(url: u, mtime: m, size: size)
        }
        return Array(dated.sorted { $0.mtime != $1.mtime ? $0.mtime > $1.mtime : $0.url.path < $1.url.path }.prefix(limits.maxFiles))
    }

    static func tailLines(_ url: URL, limits: Limits) -> [Data] {
        var t = false
        return tailLines(url, limits: limits, truncated: &t)
    }
    /// 读文件末尾 tailBytes 字节并按行切开；没从文件开头读起时丢掉第一行残行
    static func tailLines(_ url: URL, limits: Limits, truncated: inout Bool) -> [Data] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return [] }
        let start = size > limits.tailBytes ? size - limits.tailBytes : 0
        // 多读前一个字节：它是换行符时，截断处的第一行是完整的，不丢
        let from = start > 0 ? start - 1 : 0
        guard (try? h.seek(toOffset: from)) != nil, var data = try? h.readToEnd() else { return [] }
        truncated = start > 0
        var partialFirst = false
        if truncated {
            partialFirst = data.first != 0x0A
            data = data.dropFirst()
        }
        // 各行是同一块数据的切片，不逐行复制（8 MB 的尾巴复制一遍就多占 8 MB）
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if partialFirst, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}

/// 本机日志的逐文件解析缓存：路径 + 修改时间 + 大小都没变就直接用上次的结果，不打开文件。
/// 只存 7 天窗口起始日及以后的条目，跨天时裁剪旧条目，不重读文件；
/// 时区、Limits 变了或窗口往前移（时钟回拨）时整个作废；
/// 本次没列到的文件（被删、超出 maxFiles 或 7 天）从缓存里清掉。只存日期、模型名、token 数和去重键，不存对话内容。
/// 由 UsageModel 持有一个实例，传进后台读取任务；内部用锁保护，同一时间只有一次读取在用它
/// @unchecked Sendable：所有可变状态只在 lock 里读写
final class LocalUsageCache: @unchecked Sendable {
    enum Source { case claude, codex }
    private struct Stamp: Equatable {
        var mtime: Date
        var size: UInt64
    }
    private let lock = NSLock()
    private var timeZoneID: String?
    private var minDay: String?
    private var limits: LocalAgentUsage.Limits?
    private var claude: [String: (stamp: Stamp, entries: [LocalAgentUsage.ClaudeEntry])] = [:]
    private var codex: [String: (stamp: Stamp, entries: [LocalAgentUsage.CodexEntry])] = [:]
    private var parsed = 0

    init() {}

    /// 累计实际打开并解析了多少个文件（测试用）
    var parsedFileCount: Int { lock.withLock { parsed } }
    /// 当前缓存了多少个文件
    var cachedFileCount: Int { lock.withLock { claude.count + codex.count } }

    /// 当前缓存了多少条用量（测试用）
    var cachedEntryCount: Int {
        lock.withLock { claude.values.reduce(0) { $0 + $1.entries.count } + codex.values.reduce(0) { $0 + $1.entries.count } }
    }

    /// 某个平台没添加了：清掉它的缓存
    func clear(_ source: Source) {
        lock.withLock {
            switch source {
            case .claude: claude = [:]
            case .codex: codex = [:]
            }
        }
    }

    func claudeEntries(for files: [LocalAgentUsage.FileStamp], timeZone: TimeZone, limits: LocalAgentUsage.Limits, minDay: String,
                       parse: (URL) -> [LocalAgentUsage.ClaudeEntry]) -> [[LocalAgentUsage.ClaudeEntry]] {
        lock.withLock {
            resetIfNeeded(timeZone: timeZone, limits: limits, minDay: minDay)
            return Self.lookup(files, store: &claude, parsed: &parsed) { parse($0).filter { $0.day >= minDay } }
        }
    }

    func codexEntries(for files: [LocalAgentUsage.FileStamp], timeZone: TimeZone, limits: LocalAgentUsage.Limits, minDay: String,
                      parse: (URL) -> [LocalAgentUsage.CodexEntry]) -> [[LocalAgentUsage.CodexEntry]] {
        lock.withLock {
            resetIfNeeded(timeZone: timeZone, limits: limits, minDay: minDay)
            return Self.lookup(files, store: &codex, parsed: &parsed) { parse($0).filter { $0.day >= minDay } }
        }
    }

    /// 调用时已持有锁
    private func resetIfNeeded(timeZone: TimeZone, limits: LocalAgentUsage.Limits, minDay: String) {
        if timeZone.identifier != timeZoneID || limits != self.limits || self.minDay.map({ minDay < $0 }) == true {
            claude = [:]
            codex = [:]
        } else if self.minDay.map({ minDay > $0 }) == true {
            // 窗口往后移：两类缓存一起裁剪，文件没变就不重读
            claude = claude.mapValues { (stamp: $0.stamp, entries: $0.entries.filter { $0.day >= minDay }) }
            codex = codex.mapValues { (stamp: $0.stamp, entries: $0.entries.filter { $0.day >= minDay }) }
        }
        timeZoneID = timeZone.identifier
        self.limits = limits
        self.minDay = minDay
    }

    /// 按列表顺序取每个文件的条目：没变的用缓存，变了的重新解析；没列到的从缓存里删掉
    private static func lookup<E>(_ files: [LocalAgentUsage.FileStamp], store: inout [String: (stamp: Stamp, entries: [E])],
                                  parsed: inout Int, parse: (URL) -> [E]) -> [[E]] {
        var next: [String: (stamp: Stamp, entries: [E])] = [:]
        var out: [[E]] = []
        for f in files {
            let stamp = Stamp(mtime: f.mtime, size: f.size)
            let entries: [E]
            if let hit = store[f.url.path], hit.stamp == stamp {
                entries = hit.entries
            } else {
                entries = parse(f.url)
                parsed += 1
            }
            next[f.url.path] = (stamp, entries)
            out.append(entries)
        }
        store = next
        return out
    }
}

/// 本机日志的重读节流：添加了套餐平台才读；最多每 5 分钟读一次，新添加了平台时马上读。
/// 每次读取有一个序号：只采用最新一次的结果（晚结束的旧读取不能盖掉新结果）；正在读时不按时间再开一次
struct LocalUsageThrottle {
    static let minInterval: TimeInterval = 300
    private(set) var lastStart: Date?
    private(set) var lastEnabled: Set<ProviderID> = []
    private var generation = 0
    private var inFlight = false

    /// 现在该读就返回这次读取的序号（同时记下开始时间），否则 nil
    mutating func begin(enabled: Set<ProviderID>, now: Date) -> Int? {
        guard !enabled.isEmpty else { lastEnabled = []; return nil }
        let changed = enabled != lastEnabled
        let due = lastStart.map { now.timeIntervalSince($0) >= Self.minInterval || now < $0 } ?? true
        guard changed || (due && !inFlight) else { return nil }
        lastStart = now
        lastEnabled = enabled
        generation += 1
        inFlight = true
        return generation
    }

    /// 读完调用：true 表示这是最新一次读取，结果可以用
    mutating func finish(_ gen: Int) -> Bool {
        guard gen == generation else { return false }
        inFlight = false
        return true
    }
}
