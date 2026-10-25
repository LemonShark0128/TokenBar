import Foundation

/// 油箱按什么量：金额（按量付费）或套餐额度百分比
enum Meter: String, Codable {
    case money, quota
}

/// 套餐里的一个额度窗口（5 小时 / 每周 / 每周某模型）
struct QuotaWindow: Equatable, Codable {
    enum Kind: Equatable, Codable { case session, weekly, weeklyModel(String) }
    var kind: Kind
    /// 0–100，可能 >100，显示时按 100
    var usedPercent: Double
    var resetsAt: Date?
    var windowMinutes: Int?
    /// resetsAt 是按历史读数推算的（Claude 桌面 App 的记录里没有重置时间），界面写「约 … 后重置（推算）」
    var resetIsEstimated: Bool = false
}

extension QuotaWindow {
    private enum CodingKeys: String, CodingKey { case kind, usedPercent, resetsAt, windowMinutes, resetIsEstimated }
    /// 旧快照缓存里没有 resetIsEstimated：按 false 解码
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        usedPercent = try c.decode(Double.self, forKey: .usedPercent)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        windowMinutes = try c.decodeIfPresent(Int.self, forKey: .windowMinutes)
        resetIsEstimated = try c.decodeIfPresent(Bool.self, forKey: .resetIsEstimated) ?? false
    }
}

struct Quota: Equatable, Codable {
    /// Codex 的 plan_type；Claude 没有
    var plan: String?
    var windows: [QuotaWindow]
    /// 数据产生的时间（日志行时间 / 钩子写入时间）
    var observedAt: Date
    /// 读数来自桌面 App 历史记录，属于推算。
    var estimated: Bool = false
}

extension Quota {
    private enum CodingKeys: String, CodingKey { case plan, windows, observedAt, estimated }
    /// 兼容没有推算标记的旧快照。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        windows = try c.decode([QuotaWindow].self, forKey: .windows)
        observedAt = try c.decode(Date.self, forKey: .observedAt)
        estimated = try c.decodeIfPresent(Bool.self, forKey: .estimated) ?? false
    }
}

extension QuotaWindow {
    /// 已到重置时间（now >= resetsAt）
    func isReset(at now: Date) -> Bool {
        resetsAt.map { now >= $0 } ?? false
    }

    /// 有效已用：已重置按 0，否则夹到 0…100
    func effectiveUsed(at now: Date) -> Double {
        isReset(at: now) ? 0 : min(100, max(0, usedPercent))
    }
}

extension Quota {
    /// 界面读数：优先 5 小时窗口，再用每周窗口，最后取第一个窗口。
    var displayWindow: QuotaWindow? {
        windows.first { $0.kind == .session } ?? windows.first { $0.kind == .weekly } ?? windows.first
    }

    /// 显示口径的剩余百分比；已重置按剩余 100%。
    func displayRemainingPercent(at now: Date) -> Double? {
        displayWindow.map { 100 - $0.effectiveUsed(at: now) }
    }

    /// 预警口径的最紧窗口：剩余最少；剩余相同取数组里靠前的
    func tightest(at now: Date) -> QuotaWindow? {
        var best: QuotaWindow?
        for w in windows where best == nil || w.effectiveUsed(at: now) > best!.effectiveUsed(at: now) {
            best = w
        }
        return best
    }

    /// 预警口径：最紧窗口的剩余百分比；没有窗口为 nil
    func remainingPercent(at now: Date) -> Double? {
        tightest(at: now).map { 100 - $0.effectiveUsed(at: now) }
    }

    /// 判断「在用」看的窗口：优先第一个 5 小时窗口，其次第一个每周窗口
    var activityWindow: QuotaWindow? {
        windows.first { $0.kind == .session } ?? windows.first { $0.kind == .weekly }
    }
}

enum QuotaActivity {
    /// 近 1 小时额度已用百分点的涨幅。相邻两点只计正差值（负值是窗口重置，nil 的点跳过）
    static func risePP(_ samples: [Sample], now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-3600)
        let sorted = samples.sorted { $0.t < $1.t }
        let recent = sorted.filter { $0.t > cutoff }
        var pts = recent
        if let base = sorted.last(where: { $0.t <= cutoff }) { pts.insert(base, at: 0) }
        var total = 0.0
        for (a, b) in zip(pts, pts.dropFirst()) {
            guard let x = a.quotaUsed, let y = b.quotaUsed, y > x else { continue }
            total += y - x
        }
        return total
    }
}
