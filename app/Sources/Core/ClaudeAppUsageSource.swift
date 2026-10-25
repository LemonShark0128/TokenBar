import Foundation

/// Claude 桌面 App 自己记录的套餐额度：~/Library/Application Support/Claude/plan-usage-history.json。
/// 桌面 App 定期往里追加一条读数（百分比），只保留约一个月。文件里没有重置时间，这里按历史读数推算。
/// 纯函数、时间由调用方给。条目里带组织 UUID：只用最新一条读数所在组织的读数（不读 ~/.claude.json 去认是哪个组织）
enum ClaudeAppUsageSource {
    /// 读文件的上限：正常一个月的记录只有几十 KB
    static let maxBytes = 1 << 20

    static var standardURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    /// 一条读数：fh = 5 小时窗口已用 %，sd = 7 天已用 %，so / sn = 7 天 Opus / Sonnet 已用 %（键可能缺）
    struct Sample: Equatable {
        var t: Date
        var fh: Double? = nil
        var sd: Double? = nil
        var so: Double? = nil
        var sn: Double? = nil
        /// 组织 UUID（v1 或缺失时为 nil）
        var org: String? = nil
    }

    enum Parsed: Equatable {
        /// 按时间排好序
        case samples([Sample])
        /// 不是 JSON、顶层不是对象、没有 samples 数组
        case corrupt
        /// 版本号不是 1 或 2（或没有）：不猜
        case unknownVersion
    }

    enum Outcome: Equatable {
        case missing, tooLarge, corrupt, unknownVersion
        /// 文件在，但没有带额度字段的读数
        case noRecentData
        /// 最新一条读数已超过 staleAfter（桌面 App 没再记录）：不推算，界面写停在什么时候
        case stale(Date)
        case quota(Quota)
    }

    static let session: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86400
    static let day: TimeInterval = 86400
    /// 读数时间比现在晚多少以内还算正常（两边时钟的小偏差）
    static let futureSlack: TimeInterval = 300
    /// 最新读数超过这么久就算记录过旧（桌面 App 在记录时每 5–15 分钟一条）
    static let staleAfter: TimeInterval = 3600

    // MARK: 读文件

    static func read(_ url: URL, now: Date) -> Outcome {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return .missing }
        if isDir.boolValue { return .corrupt }
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > maxBytes {
            return .tooLarge
        }
        guard let h = try? FileHandle(forReadingFrom: url) else { return .corrupt }
        defer { try? h.close() }
        // 读的过程中文件变大也不超过上限
        guard let data = try? h.read(upToCount: maxBytes + 1) ?? Data() else { return .corrupt }
        if data.count > maxBytes { return .tooLarge }
        switch parse(data) {
        case .corrupt: return .corrupt
        case .unknownVersion: return .unknownVersion
        case .samples(let s):
            let withData = s.filter { ($0.fh ?? $0.sd ?? $0.so ?? $0.sn) != nil && $0.t.timeIntervalSince(now) <= futureSlack }
            guard let latest = withData.map(\.t).max() else { return .noRecentData }
            if now.timeIntervalSince(latest) > staleAfter { return .stale(latest) }
            return quota(from: s, now: now).map { .quota($0) } ?? .noRecentData
        }
    }

    // MARK: 解析

    static func parse(_ data: Data) -> Parsed {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .corrupt }
        guard let v = version(root) else { return .unknownVersion }
        guard let raw = root["samples"] as? [Any] else { return .corrupt }
        var out: [Sample] = []
        for item in raw {
            guard let o = item as? [String: Any], let t = number(o["t"]) else { continue }
            // v2：读数在 u 里；v1：直接平铺在条目上
            let u: [String: Any] = v == 2 ? (o["u"] as? [String: Any] ?? [:]) : o
            out.append(Sample(t: Date(timeIntervalSince1970: t / 1000),
                              fh: number(u["fh"]), sd: number(u["sd"]), so: number(u["so"]), sn: number(u["sn"]),
                              org: o["org"] as? String))
        }
        return .samples(out.sorted { $0.t < $1.t })
    }

    /// 认识的版本号：1、2；其他（含字符串、缺失）为 nil
    private static func version(_ root: [String: Any]) -> Int? {
        guard let n = root["version"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        return v == 1 || v == 2 ? Int(v) : nil
    }

    /// 数字（JSON 里的整数或小数）；字符串、布尔、null 不算
    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    // MARK: 推算

    /// 由读数得到额度窗口：5 小时（fh）、每周（sd）、每周 Opus（so）、每周 Sonnet（sn）。没有有效窗口为 nil
    static func quota(from samples: [Sample], now: Date) -> Quota? {
        // 超过 7 天的读数丢弃；比现在晚超过几分钟的（时钟回拨）也丢弃，免得一直当作最新
        let valid = samples.filter { now.timeIntervalSince($0.t) <= week && $0.t.timeIntervalSince(now) <= futureSlack }
            .sorted { $0.t < $1.t }
        // 多个组织交替记录时，只看最新一条所在的组织，不把组织间的来回跳当成重置
        guard let org = valid.last.map({ $0.org }) else { return nil }
        let recent = valid.filter { $0.org == org }
        guard let latest = recent.last else { return nil }
        var windows: [QuotaWindow] = []
        if let w = sessionWindow(recent, now: now) { windows.append(w) }
        let weekly: [(KeyPath<Sample, Double?>, QuotaWindow.Kind)] = [(\.sd, .weekly), (\.so, .weeklyModel("Opus")), (\.sn, .weeklyModel("Sonnet"))]
        for (key, kind) in weekly {
            if let w = weeklyWindow(recent, key: key, kind: kind, now: now) { windows.append(w) }
        }
        return windows.isEmpty ? nil : Quota(plan: nil, windows: windows, observedAt: latest.t)
    }

    /// 5 小时窗口：从最新的 fh 读数往回找一段连续 >0 的读数（读数变小说明中间重置过，到那里为止；
    /// 离最新一条已有 5 小时的读数不可能在同一个窗口里，也到那里为止——空闲期间桌面 App 可能没记下 0），
    /// 这段第一条的时间 + 5 小时就是重置时间。最新的 fh 读数超过 5 小时当作没有数据
    private static func sessionWindow(_ samples: [Sample], now: Date) -> QuotaWindow? {
        let pts = samples.compactMap { s in s.fh.map { (t: s.t, v: $0) } }
        guard let last = pts.last, now.timeIntervalSince(last.t) <= session else { return nil }
        var reset: Date?
        if last.v > 0 {
            var i = pts.count - 1
            while i > 0, pts[i - 1].v > 0, pts[i - 1].v <= pts[i].v, last.t.timeIntervalSince(pts[i - 1].t) < session { i -= 1 }
            reset = pts[i].t.addingTimeInterval(session)
        }
        return keepWindow(QuotaWindow(kind: .session, usedPercent: last.v, resetsAt: reset, windowMinutes: 300,
                                      resetIsEstimated: reset != nil), latest: last.t, now: now)
    }

    /// 每周窗口：找最后一次「下降」（后一条比前一条小），重置发生在这两条之间——取前一条之后的第一个 UTC 整点；
    /// 那次重置已经发生，下一次在它之后每 7 天，取第一个晚于最新读数的。找不到下降就没有重置时间
    private static func weeklyWindow(_ samples: [Sample], key: KeyPath<Sample, Double?>, kind: QuotaWindow.Kind,
                                     now: Date) -> QuotaWindow? {
        let pts = samples.compactMap { s in s[keyPath: key].map { (t: s.t, v: $0) } }
        guard let last = pts.last else { return nil }
        var reset: Date?
        if let i = pts.indices.dropFirst().last(where: { pts[$0].v < pts[$0 - 1].v }) {
            var r = nextUTCHour(after: pts[i - 1].t).addingTimeInterval(week)
            while r <= last.t { r.addTimeInterval(week) }
            reset = r
        }
        return keepWindow(QuotaWindow(kind: kind, usedPercent: last.v, resetsAt: reset, windowMinutes: 10080,
                                      resetIsEstimated: reset != nil), latest: last.t, now: now)
    }

    /// 过期规则：推算出的重置时间已过 → 丢弃；没有重置时间且最新读数超过 1 天 → 丢弃
    static func keepWindow(_ w: QuotaWindow, latest: Date, now: Date) -> QuotaWindow? {
        if let r = w.resetsAt { return r > now ? w : nil }
        return now.timeIntervalSince(latest) > day ? nil : w
    }

    /// 严格晚于 t 的第一个 UTC 整点
    static func nextUTCHour(after t: Date) -> Date {
        let s = t.timeIntervalSince1970
        return Date(timeIntervalSince1970: (floor(s / 3600) + 1) * 3600)
    }
}
