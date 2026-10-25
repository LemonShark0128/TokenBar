import Foundation

/// 一个平台近 7 天按模型的 token（主平台以外的按量付费平台取 trend7，套餐平台取本机日志）
struct TokenSource: Codable, Equatable {
    var provider: ProviderID
    /// 日期 → 模型 → token；模型名为空串表示该平台当天没有按模型拆分
    var byDay: DailyModelTokens
    /// 日期 → 模型 → 当天花费（按 currency）；只放平台账单里明确给了金额的模型，没有的不写（看不到 ≠ 没花）
    var costByDay: [String: [String: Double]]? = nil
    /// costByDay 的币种（「CNY」「USD」）
    var currency: String? = nil
}

/// 「近 7 天 token」合并图的数据：每天一根柱，按模型分段；前 4 名单独成段，其余合成「其他」
struct TokenChart: Equatable {
    struct Series: Equatable {
        /// 「平台|模型」
        var key: String
        var label: String
        var isOther: Bool
        /// 今天的花费：nil = 看不到（不写）
        var todayCost: Cost? = nil
    }
    /// 图例里一行的今日花费
    enum Cost: Equatable {
        case money(Double, currency: String?)
        /// 套餐平台：按月付费，没有按量花费
        case plan
    }
    /// 图例下面「今天合计」那一行
    struct TodaySummary: Equatable {
        enum Trend: Equatable { case up, down, flat, none }
        /// 「1.34亿」
        var total: String
        /// 「比前 6 天日均 +38%」「和前 6 天日均持平」；前几天没有用量时为 nil
        var change: String?
        var trend: Trend
        /// 「1.34亿 · 比前 6 天日均 +38%」
        var text: String { [total, change].compactMap { $0 }.joined(separator: " · ") }
    }
    struct Bar: Equatable {
        var iso: String
        /// MM-dd
        var date: String
        var total: Int
        /// 与 series 一一对应
        var parts: [Int]
    }
    struct LegendItem: Equatable {
        var series: Int
        var tokens: Int
    }
    var series: [Series]
    var bars: [Bar]
    /// 今天以前各天的花费：日期 → 序列下标 → 花费（今天的在 Series.todayCost）；看不到的不放
    var dayCosts: [String: [Int: Cost]] = [:]
    /// 近 7 天里有用量的平台不止一个：画分段柱和图例，标签带平台简称
    var multiPlatform: Bool

    static let topN = 4
    static var otherLabel: String { L("chart.other") }

    var isEmpty: Bool { bars.allSatisfy { $0.total == 0 } }
    var today: Bar? { bars.last }

    /// main：主平台（按量付费时 mainDays 是它的 trend7）；others：其他平台；todayISO：主平台没有 trend7 时横轴的最后一天
    /// mainTodayCost：主平台今天按模型的花费（模型名 → 金额，来自 AppData.models），mainCurrency 是它的币种；
    /// 主平台只有余额时传 nil，图例就不写花费
    static func build(main: ProviderID?, mainDays: [AppData.Day], others: [TokenSource], todayISO: String,
                      topN: Int = TokenChart.topN,
                      mainTodayCost: [String: Double]? = nil, mainCurrency: String? = nil) -> TokenChart {
        // 横轴：主平台的 trend7 以今天结尾就沿用（老用户的柱子与原来逐根一致）；
        // 没有、或停在昨天（离线跨过午夜）时按今天往前 7 天，本机今天的用量不丢
        let axis: [(iso: String, date: String)] = mainDays.last?.iso == todayISO
            ? mainDays.map { ($0.iso, $0.date) }
            : lastDays(todayISO, count: 7).map { ($0, String($0.suffix(5))) }
        let onAxis = Set(axis.map(\.iso))

        // 全部来源合成 [日期: [序列 key: token]]
        var cells: [String: [String: Int]] = [:]
        var meta: [String: (provider: ProviderID, model: String)] = [:]
        func add(_ p: ProviderID, _ model: String, _ iso: String, _ v: Int) {
            guard v > 0, onAxis.contains(iso) else { return }
            let k = "\(p.rawValue)|\(model)"
            meta[k] = (p, model)
            cells[iso, default: [:]][k, default: 0] += v
        }
        if let main {
            for d in mainDays {
                for (m, v) in d.byModel { add(main, m, d.iso, v) }
                add(main, "", d.iso, d.totalTokens - d.byModel.values.reduce(0, +))
            }
        }
        for s in others {
            for (iso, models) in s.byDay { for (m, v) in models { add(s.provider, m, iso, v) } }
        }

        var totals: [String: Int] = [:]
        for c in cells.values { for (k, v) in c { totals[k, default: 0] += v } }
        let ranked = totals.keys.sorted { totals[$0]! != totals[$1]! ? totals[$0]! > totals[$1]! : $0 < $1 }
        // 有主平台以外的来源就写平台名：只有 Claude Code 有用量时不能画得像是主平台的
        let providers = Set(ranked.compactMap { meta[$0]?.provider })
        let multi = providers.count > 1 || (main.map { m in providers.contains { $0 != m } } ?? false)
        // 正好比上限多一个时也合成「其他」：段数固定最多 topN + 1，颜色才够分
        let top = Array(ranked.prefix(topN))
        let rest = Set(ranked.dropFirst(topN))
        // 某一天每个序列的花费：套餐平台写「套餐」；按量付费平台只认账单里明确给了金额的模型
        // （主平台今天取 mainTodayCost；以前的日子取那天明细里的金额，是 0 的当作看不到）
        let todayISO = axis.last?.iso ?? todayISO
        func cost(_ k: String, _ iso: String) -> Cost? {
            guard let m = meta[k] else { return nil }
            if ProviderRegistry.meter(m.provider) == .quota { return .plan }
            if m.provider == main {
                if iso == todayISO { return mainTodayCost?[m.model].map { .money($0, currency: mainCurrency) } }
                guard let v = mainDays.first(where: { $0.iso == iso })?.detail?[m.model]?.costCny, v > 0 else { return nil }
                return .money(v, currency: mainCurrency)
            }
            guard let s = others.first(where: { $0.provider == m.provider }),
                  let v = s.costByDay?[iso]?[m.model] else { return nil }
            return .money(v, currency: s.currency)
        }
        // 「其他」：那天有用量的成员花费都知道、币种一样才合计；全是套餐写「套餐」；否则不写
        func otherCost(_ iso: String) -> Cost? {
            let members = rest.filter { (cells[iso]?[$0] ?? 0) > 0 }.map { cost($0, iso) }
            if !members.isEmpty, members.allSatisfy({ $0 == .plan }) { return .plan }
            guard !members.isEmpty, !members.contains(where: { $0 == nil }) else { return nil }
            let money = members.compactMap { c -> (Double, String?)? in
                if case let .money(v, cur)? = c { return (v, cur) } else { return nil }
            }
            // 套餐成员没有按量花费，合计只算按量付费的那部分会少算：混着套餐时也不写
            guard money.count == members.count, Set(money.map { $0.1 ?? "CNY" }).count == 1 else { return nil }
            return .money(money.reduce(0) { $0 + $1.0 }, currency: money[0].1)
        }
        var series = top.map { k -> Series in
            let m = meta[k]!
            return Series(key: k, label: label(provider: m.provider, model: m.model, multi: multi), isOther: false,
                          todayCost: cost(k, todayISO))
        }
        if !rest.isEmpty {
            series.append(Series(key: "", label: otherLabel, isOther: true, todayCost: otherCost(todayISO)))
        }
        var dayCosts: [String: [Int: Cost]] = [:]
        for a in axis where a.iso != todayISO {
            var c: [Int: Cost] = [:]
            for (i, k) in top.enumerated() { if let v = cost(k, a.iso) { c[i] = v } }
            if !rest.isEmpty, let v = otherCost(a.iso) { c[top.count] = v }
            if !c.isEmpty { dayCosts[a.iso] = c }
        }

        let bars = axis.map { a -> Bar in
            let c = cells[a.iso] ?? [:]
            var parts = top.map { c[$0] ?? 0 }
            if !rest.isEmpty { parts.append(c.filter { rest.contains($0.key) }.values.reduce(0, +)) }
            return Bar(iso: a.iso, date: a.date, total: parts.reduce(0, +), parts: parts)
        }
        return TokenChart(series: series, bars: bars, dayCosts: dayCosts, multiPlatform: multi)
    }

    /// 今天的图例：用量从多到少，「其他」放最后，0 的不列
    func todayLegend() -> [LegendItem] { bars.isEmpty ? [] : legend(bar: bars.count - 1) }

    /// 某一天（柱子下标）的图例，规则同今天
    func legend(bar i: Int) -> [LegendItem] {
        guard bars.indices.contains(i) else { return [] }
        let t = bars[i]
        let items = t.parts.enumerated().filter { $0.element > 0 }.map { LegendItem(series: $0.offset, tokens: $0.element) }
        return items.filter { !series[$0.series].isOther }.sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.series < $1.series }
            + items.filter { series[$0.series].isOther }
    }

    /// 图例一行的今日花费文字：「¥2.68」「套餐」；看不到花费时 nil（不写 ¥0）
    func costText(series s: Int) -> String? { costText(series: s, bar: bars.count - 1) }

    /// 某一天图例一行的花费文字
    func costText(series s: Int, bar i: Int) -> String? {
        if planOnly(bar: i) { return nil }   // 单平台全是套餐：合计行写一次「套餐」，每行不重复
        switch cost(series: s, bar: i) {
        case let .money(v, cur)?: return fmtMoney(v, cur)
        case .plan?: return L("chart.plan")
        case nil: return nil
        }
    }

    /// 某一天一个序列的花费：今天取 Series.todayCost，以前的日子取 dayCosts
    func cost(series s: Int, bar i: Int) -> Cost? {
        guard bars.indices.contains(i) else { return nil }
        return i == bars.count - 1 ? series[s].todayCost : dayCosts[bars[i].iso]?[s]
    }

    /// 单平台、今天图例里全是套餐：每行不写「套餐」，合计行写一次
    var planOnly: Bool { planOnly(bar: bars.count - 1) }

    func planOnly(bar i: Int) -> Bool {
        guard !multiPlatform else { return false }
        let items = legend(bar: i)
        return !items.isEmpty && items.allSatisfy { cost(series: $0.series, bar: i) == .plan }
    }

    /// 某一天的合计：今天同 todaySummary；以前的日子只写总量、不和平时比；那天没有用量时为 nil
    func daySummary(bar i: Int, incomplete: Bool = false) -> TodaySummary? {
        guard bars.indices.contains(i) else { return nil }
        if i == bars.count - 1 { return todaySummary(incomplete: incomplete) }
        return bars[i].total > 0 ? TodaySummary(total: cnCount(bars[i].total), change: nil, trend: .none) : nil
    }

    /// 今天合计与前几天（图里今天之前的柱子）日均的比较；今天没有用量时为 nil。
    /// 日均只算有用量的天（没用的天不拉低日均）；近 7 天数据不完整时只写合计、不比较；今天有用量时跌幅最多写 -99%
    func todaySummary(incomplete: Bool = false) -> TodaySummary? {
        guard let t = today, t.total > 0 else { return nil }
        let prev = bars.dropLast()
        let active = prev.filter { $0.total > 0 }
        guard !incomplete, !active.isEmpty else { return TodaySummary(total: cnCount(t.total), change: nil, trend: .none) }
        let avg = Double(active.reduce(0) { $0 + $1.total }) / Double(active.count)
        let pct = max(-99, Int((Double(t.total) / avg * 100 - 100).rounded()))
        // 「平时」= 前几天里有用量的那些天的日均（第 4 节术语统一：不写「有用量的 N 天日均 -84%」）
        if pct == 0 { return TodaySummary(total: cnCount(t.total), change: L("chart.flat"), trend: .flat) }
        return TodaySummary(total: cnCount(t.total), change: L(pct > 0 ? "chart.more" : "chart.less", abs(pct)),
                            trend: pct > 0 ? .up : .down)
    }

    /// 读屏描述：图的类型 + 今天合计（及与前几天日均的比较）+ 今天每个模型的用量和花费
    func a11yLabel(incomplete: Bool) -> String {
        let kind = multiPlatform ? L("chart.kindStacked") : L("chart.kind")
        let head = kind + (incomplete ? L("chart.incomplete") : "") + L("chart.sentenceEnd")
        guard let t = today, t.total > 0 else { return head + L("chart.noUsageToday") }
        let parts = todayLegend().map { it -> String in
            var s = "\(series[it.series].label) \(cnCount(it.tokens))"
            switch series[it.series].todayCost {
            case .money?: s += L("chart.spent") + (costText(series: it.series) ?? "")
            case .plan?: if !planOnly { s += L("chart.planSuffix") }
            case nil: break
            }
            return s
        }.joined(separator: L("chart.changeSep"))
        let change = todaySummary(incomplete: incomplete)?.change.map { L("chart.changeSep") + $0 } ?? ""
        return head + L("chart.todayTotal", cnCount(t.total), planOnly ? L("chart.planParen") : "", change) + parts
    }

    /// 一段的悬停提示：「Claude · opus-5-5 1234万」
    func partText(bar: Int, series s: Int) -> String {
        "\(series[s].label) \(cnCount(bars[bar].parts[s]))"
    }

    // ---------------------------------------------------------------- 名字

    static func platformShort(_ p: ProviderID) -> String {
        switch p {
        case .deepseek: return "DeepSeek"
        case .siliconflow: return L("provider.siliconflowShort")
        case .claudePlan: return "Claude"
        case .codexPlan: return "Codex"
        }
    }

    /// 模型短名：DeepSeek 与面板其他地方一致（V4 Pro）；硅基取「/」后一段；Claude 去掉「claude-」和日期后缀
    static func shortModel(_ name: String, provider: ProviderID) -> String {
        switch provider {
        case .deepseek: return AppDataMapping.modelLabel(name)
        case .siliconflow: return name.split(separator: "/").last.map(String.init) ?? name
        case .claudePlan:
            var s = name.hasPrefix("claude-") ? String(name.dropFirst(7)) : name
            if let r = s.range(of: "-[0-9]{8}$", options: .regularExpression) { s.removeSubrange(r) }
            return s
        case .codexPlan: return name
        }
    }

    static func label(provider: ProviderID, model: String, multi: Bool) -> String {
        guard !model.isEmpty else { return platformShort(provider) }
        let m = shortModel(model, provider: provider)
        return multi ? "\(platformShort(provider)) · \(m)" : m
    }

    /// todayISO 往前 count 天（含当天），从早到晚
    static func lastDays(_ todayISO: String, count: Int) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: todayISO) else { return [] }
        return (0..<count).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: d).map(f.string) }
    }
}

extension AppData {
    /// 合并图：主平台的 trend7 + tokenSources；横轴的「今天」取 nowLocal 的日期
    /// 主平台的今日花费取 models（今日按模型的账单）；只有余额 / 离线时没有 models，图例就不写花费
    func tokenChart(main: ProviderID?) -> TokenChart {
        // 账单里没金额的模型不写（看不到 ≠ 没花）；同名模型里有一条没金额，整行都不写
        let unknown = Set(models.filter { $0.todayCostKnown == false }.map(\.key))
        let cost: [String: Double]? = models.isEmpty ? nil
            : Dictionary(models.filter { !unknown.contains($0.key) }.map { ($0.key, $0.todayCny) }, uniquingKeysWith: +)
        return TokenChart.build(main: main, mainDays: trend7, others: tokenSources, todayISO: String(nowLocal.prefix(10)),
                                mainTodayCost: cost, mainCurrency: balance.currency)
    }
}
