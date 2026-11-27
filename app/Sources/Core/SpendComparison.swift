import Foundation

enum SpendComparison {
    static let tolerance: TimeInterval = 15 * 60
    /// 昨日同时刻低于这个金额（元）时写金额差，不写百分比
    static let smallBase = 1.0

    /// 上一整天的索引范围，覆盖两侧锚点可能借用的采样。
    static func historyInterval(now: Date, calendar: Calendar) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
        return DateInterval(start: calendar.startOfDay(for: yesterday).addingTimeInterval(-tolerance),
                            end: today.addingTimeInterval(tolerance))
    }

    static func yesterday(_ samples: [Sample], now: Date, calendar: Calendar) -> Decimal? {
        guard let target = calendar.date(byAdding: .day, value: -1, to: now),
              let month = calendar.dateInterval(of: .month, for: target) else { return nil }
        let start = calendar.startOfDay(for: target)
        let monthStart = calendar.component(.day, from: target) == 1
        let values = samples.compactMap { sample -> (t: Date, cost: Decimal)? in
            guard let cost = sample.cumulativeCost, !cost.isNaN, cost >= 0,
                  sample.t >= month.start, sample.t < month.end else { return nil }
            return (sample.t, cost)
        }.sorted { $0.t < $1.t }

        func nearest(to anchor: Date) -> Int? {
            var nearest: Int?
            var distance = tolerance
            let latest = anchor.addingTimeInterval(tolerance)
            for (i, value) in values.enumerated() {
                if value.t > latest { break }
                let gap = abs(value.t.timeIntervalSince(anchor))
                if gap <= tolerance && (nearest == nil || gap < distance) {
                    nearest = i
                    distance = gap
                }
            }
            return nearest
        }
        guard let end = nearest(to: target) else { return nil }
        if monthStart { return values[end].cost }
        guard let begin = nearest(to: start), begin <= end else { return nil }
        for i in (begin + 1)..<(end + 1) where values[i].cost < values[i - 1].cost {
            return values[end].cost
        }
        return values[end].cost - values[begin].cost
    }

    static func total(in history: [ProviderID: [Sample]], paying: [ProviderID: Currency], now: Date,
                      calendar: Calendar, usdToCny: Decimal) -> Decimal? {
        guard !paying.isEmpty else { return nil }
        var total: Decimal = 0
        for (id, currency) in paying {
            guard let samples = history[id],
                  let amount = yesterday(samples.filter { $0.currency == currency }, now: now, calendar: calendar) else { return nil }
            total += Money(amount: amount, currency: currency).converted(to: .cny, usdToCny: usdToCny).amount
        }
        return total
    }

    enum Change: Equatable {
        case increase(Int), decrease(Int), steady, zeroYesterday
        /// 昨日同时刻花费太小（< smallBase 元）时百分比没有意义（¥0.02 → ¥2.7 是 +13000%），改写金额差
        case increaseAmount(String), decreaseAmount(String)

        var text: String {
            switch self {
            case .increase(let percent): return L("today.spendDeltaUp", percent)
            case .decrease(let percent): return L("today.spendDeltaDown", percent)
            case .steady: return L("today.spendDeltaSteady")
            case .zeroYesterday: return L("today.spendYesterdayZero")
            case .increaseAmount(let amount): return L("today.spendDeltaUpAmount", amount)
            case .decreaseAmount(let amount): return L("today.spendDeltaDownAmount", amount)
            }
        }

        var a11y: String {
            switch self {
            case .increase(let percent): return L("today.spendDeltaUpA11y", percent)
            case .decrease(let percent): return L("today.spendDeltaDownA11y", percent)
            case .increaseAmount(let amount): return L("today.spendDeltaUpAmountA11y", amount)
            case .decreaseAmount(let amount): return L("today.spendDeltaDownAmountA11y", amount)
            case .steady, .zeroYesterday: return text
            }
        }
    }

    static func change(today: Double, yesterday: Double?) -> Change? {
        guard let yesterday, today.isFinite, yesterday.isFinite, today >= 0, yesterday >= 0 else { return nil }
        if yesterday == 0 { return today > 0 ? .zeroYesterday : nil }
        if yesterday < smallBase {
            let diff = today - yesterday
            if abs(diff) < 0.1 { return .steady }
            let amount = fmtCNY(abs(diff))
            return diff > 0 ? .increaseAmount(amount) : .decreaseAmount(amount)
        }
        guard let current = Decimal(string: String(today)), let prior = Decimal(string: String(yesterday)), prior > 0 else { return nil }
        var delta = (current / prior - 1) * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &delta, 0, .plain)
        guard let percent = Int(exactly: NSDecimalNumber(decimal: rounded).doubleValue) else { return nil }
        if percent >= 5 { return .increase(percent) }
        if percent <= -5 { return .decrease(-percent) }
        return .steady
    }
}
