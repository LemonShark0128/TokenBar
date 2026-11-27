import Foundation

/// 平台没有账单接口（Kimi）时，按余额采样的下降量估算今日 / 本月花费和近 7 天每天花了多少（纯函数）。
/// 充值（余额上升）不计；每段区间的起点取区间开始前最后一个采样，短间隔跨零点算进后一天，超过两小时的间隔按时间分摊
enum BalanceSpendEstimate {
    struct Result: Equatable {
        var today: Decimal
        var month: Decimal
        /// 近 7 天（含今天），从旧到新；只有花费，没有 token
        var week: [DayUsage]
    }

    static func estimate(samples: [Sample], now: Date, timeZone: TimeZone, currency: Currency) -> Result {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let sorted = samples.filter { $0.balance != nil && $0.t <= now }.sorted { $0.t < $1.t }
        let todayStart = cal.startOfDay(for: now)
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? todayStart
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        var week: [DayUsage] = []
        for back in stride(from: 6, through: 0, by: -1) {
            guard let start = cal.date(byAdding: .day, value: -back, to: todayStart),
                  let end = cal.date(byAdding: .day, value: 1, to: start) else { continue }
            week.append(DayUsage(day: fmt.string(from: start), tokens: 0,
                                 cost: Money(amount: spent(sorted, from: start, to: end), currency: currency)))
        }
        return Result(today: spent(sorted, from: todayStart, to: now.addingTimeInterval(1)),
                      month: spent(sorted, from: monthStart, to: now.addingTimeInterval(1)), week: week)
    }

    static let maxGap: TimeInterval = 2 * 3600

    /// 短间隔归入后一个采样的窗口；长间隔取与窗口的交集，包括窗口后的端点。
    static func spent(_ sorted: [Sample], from: Date, to: Date) -> Decimal {
        guard to > from else { return 0 }
        var total: Decimal = 0
        for (prev, next) in zip(sorted, sorted.dropFirst()) {
            guard let p = prev.balance, let n = next.balance, n < p else { continue }
            let gap = next.t.timeIntervalSince(prev.t)
            if gap > maxGap {
                let overlap = min(next.t, to).timeIntervalSince(max(prev.t, from))
                if overlap > 0 { total += (p - n) * Decimal(overlap) / Decimal(gap) }
            } else if next.t >= from && next.t < to {
                total += p - n
            }
        }
        return total
    }
}

/// UsageStore 持有的内存缓存；月份、日界或时区改变时只重算一次历史部分。
struct BalanceSpendCache {
    private struct Entry {
        var month: Date
        var day: Date
        var zone: TimeZone
        var amount: Decimal
        var closed: Bool
    }
    private var entries: [ProviderID: Entry] = [:]

    mutating func remove(_ id: ProviderID) { entries[id] = nil }

    mutating func estimate(id: ProviderID, now: Date, timeZone: TimeZone, currency: Currency,
                           load: (Date) throws -> [Sample]) rethrows -> BalanceSpendEstimate.Result {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = cal.startOfDay(for: now)
        let month = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? day
        let since = cal.date(byAdding: .day, value: -8, to: day)!
        let recent = try load(since).filter { $0.balance != nil && $0.t <= now }.sorted { $0.t < $1.t }
        var result = BalanceSpendEstimate.estimate(samples: recent, now: now, timeZone: timeZone, currency: currency)
        let old = entries[id]
        if old?.month != month || old?.day != day || old?.zone != timeZone || old?.closed != true {
            let history = month >= since ? recent : try load(month).filter { $0.balance != nil && $0.t <= now }.sorted { $0.t < $1.t }
            entries[id] = Entry(month: month, day: day, zone: timeZone,
                                amount: BalanceSpendEstimate.spent(history, from: month, to: day),
                                closed: history.last.map { $0.t >= day } ?? false)
        }
        result.month = (entries[id]?.amount ?? 0) + result.today
        return result
    }
}
