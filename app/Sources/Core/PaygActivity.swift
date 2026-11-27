import Foundation

/// 余额下降驱动自动切换，与本机任务状态分开。没有余额的平台（OpenRouter 普通 Key 没设上限）看本月累计花费上涨。
enum PaygActivity {
    /// 10 分钟内累计花掉多少才算「正在用」：¥0.05；美元 $0.01（约 ¥0.07，同一量级，不按原数 0.05 算成 7 倍门槛）
    static func threshold(_ currency: Currency) -> Decimal {
        currency == .usd ? Decimal(string: "0.01")! : Decimal(string: "0.05")!
    }
    static let window = MainSwitcher.runningWindow
    /// 和上一条采样隔得比这久的下降不计（重启、睡眠唤醒、断网恢复后的第一次读数，扣费可能是几小时前或别的机器上的，
    /// 不是「过去 10 分钟」）。留出余量：没在用时刷新最慢 10 分钟一次
    static let maxGap: TimeInterval = 2 * window

    /// 两条相邻采样之间花了多少：都有余额看余额下降；都没有余额看本月累计上涨（换月清零变少不算）。
    /// 一条有余额、一条没有：口径不同，不比；没花（或充值）返回 nil
    static func drop(_ a: Sample, _ b: Sample) -> Decimal? {
        let d: Decimal?
        switch (a.balance, b.balance) {
        case let (x?, y?): d = x - y
        case (nil, nil): d = a.cumulativeCost.flatMap { x in b.cumulativeCost.map { $0 - x } }
        default: d = nil
        }
        return d.flatMap { $0 > 0 ? $0 : nil }
    }

    static func lastActive(samples: [Sample], now: Date) -> Date? {
        let rows = samples.filter { $0.t <= now && ($0.balance != nil || $0.cumulativeCost != nil) }.sorted { $0.t < $1.t }
        var previous: Sample?
        var drops: [(at: Date, amount: Decimal)] = []
        var active: Date?
        for row in rows {
            defer { previous = row }
            if let last = active, row.t.timeIntervalSince(last) > window { active = nil }
            drops.removeAll { row.t.timeIntervalSince($0.at) > window }
            guard let before = previous, let spent = drop(before, row),
                  row.t.timeIntervalSince(before.t) <= maxGap else { continue }
            drops.append((row.t, spent))
            if active != nil || drops.reduce(Decimal.zero, { $0 + $1.amount }) >= threshold(row.currency) {
                active = row.t
            }
        }
        guard let last = active, now.timeIntervalSince(last) <= window else { return nil }
        return last
    }
}
