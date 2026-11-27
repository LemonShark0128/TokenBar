import Foundation

struct TodayCardDetail {
    struct Row: Identifiable {
        var id: String
        var label: String
        var value: String
        var provider: ProviderID? = nil
    }
    struct Bar: Identifiable {
        var id: String
        var label: String
        var value: Double
        var text: String
        var fraction: Double = 0
    }
    var rows: [Row] = []
    var models: [Row] = []
    var more: String? = nil
    var bars: [Bar] = []
    var sparkline: [Bar] = []
    var chartTitle = ""
    var tasks: [Row] = []
    var chart: TokenChart? = nil
}

extension TodayCards {
    static func needsRiskRow(id: String, cards: [TodayCard], placements: [TodayLayout.Placement]) -> Bool {
        guard let own = placements.first(where: { $0.id == id }) else { return false }
        let peers = Set(placements.filter { $0.row == own.row }.map(\.id))
        return cards.contains { $0.kind == .platform && peers.contains($0.id) && ($0.status != nil || $0.runwayChip != nil || $0.stateLine != nil) }   // 只看平台卡：「正在跑」空状态的说明不算状态行
    }

    static func bottomNote(_ card: TodayCard) -> String? {
        card.footnote == card.status ? nil : card.footnote
    }

    /// trend7 belongs to mainProvider; secondary providers have explicitly tagged tokenSources.
    /// Never reuse the main provider's data for another platform.
    private static func source(_ d: AppData, provider: ProviderID) -> TokenSource? {
        if provider != d.mainProvider { return d.tokenSources.first { $0.provider == provider } }
        guard !d.trend7.isEmpty else { return d.tokenSources.first { $0.provider == provider } }
        let days = Dictionary(d.trend7.map { day -> (String, [String: Int]) in
            var models = day.byModel
            let remainder = day.totalTokens - models.values.reduce(0, +)
            if remainder > 0 { models["", default: 0] += remainder }
            return (day.iso, models)
        }, uniquingKeysWith: { _, b in b })
        let costs = Dictionary(d.trend7.compactMap { day -> (String, [String: Double])? in
            guard let detail = day.detail, !detail.isEmpty else { return nil }
            // Day.Detail predates optional amounts: mapping uses zero for unavailable cost.
            // Match TokenChart's historical-cost rule instead of inventing free usage.
            return (day.iso, detail.filter { $0.value.costCny > 0 }.mapValues(\.costCny))
        }, uniquingKeysWith: { _, b in b })
        return .init(provider: provider, byDay: days, costByDay: costs, currency: d.balance.currency)
    }

    private static func normalized(_ bars: [TodayCardDetail.Bar]) -> [TodayCardDetail.Bar] {
        let peak = bars.map(\.value).max() ?? 0
        return bars.map { bar in var b = bar; b.fraction = peak > 0 ? b.value / peak : 0; return b }
    }

    private static func daily(_ source: TokenSource?, today: String, money: Bool) -> [TodayCardDetail.Bar] {
        guard let source else { return [] }
        let dates = TokenChart.lastDays(today, count: 7)
        return normalized(dates.compactMap { iso in
            let value: Double
            if money {
                guard let costs = source.costByDay?[iso], !costs.isEmpty,
                      costs.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
                      (source.byDay[iso] ?? [:]).filter({ $0.value > 0 }).keys.allSatisfy({ costs[$0] != nil }) else { return nil }
                value = costs.values.reduce(0, +)
            } else {
                guard let models = source.byDay[iso], !models.isEmpty else { return nil }
                value = Double(models.values.reduce(0, +))
            }
            return .init(id: iso, label: String(iso.suffix(5)), value: value,
                         text: money ? fmtMoney(value, source.currency ?? "CNY") : cnCount(Int(value)))
        })
    }

    private static func taskRows(_ tasks: [RunningTask], limit: Int, detailed: Bool, now: Date) -> [TodayCardDetail.Row] {
        tasks.prefix(limit).enumerated().map { index, task in
            .init(id: "\(task.sessionKey)-\(index)", label: task.project,
                  value: detailed ? RunningTaskText.detail(task) : [task.model, RunningTaskText.clock(task, now: now)].compactMap { $0 }.joined(separator: " · "),
                  provider: task.provider)
        }
    }

    static func detail(_ card: TodayCard, size: TodayCardSize, data d: AppData,
                       running: [RunningTask], now: Date) -> TodayCardDetail {
        var out = TodayCardDetail()
        guard size != .small else { return out }
        let today = String(d.nowLocal.prefix(10))
        switch card.kind {
        case .platform:
            guard let provider = card.provider else { return out }
            let side = ([d.mainCardSide].compactMap { $0 } + d.sides).first { $0.id == card.id }
            let src = source(d, provider: provider)
            if ProviderRegistry.meter(provider) == .quota {
                let resets = (side?.resetCreditsCount ?? (provider == d.mainProvider ? d.quota?.resetCreditsCount : nil)).flatMap { $0 > 0 ? $0 : nil }
                if let resets { out.rows.append(.init(id: "resets", label: L("today.resetCredits", resets), value: "")) }
                else if let note = side?.resetCredits ?? (provider == d.mainProvider ? d.quota?.resetCredits : nil) {
                    out.rows.append(.init(id: "resets", label: note, value: ""))
                }
                if let tokens = src?.byDay[today], !tokens.isEmpty {
                    out.rows.append(.init(id: "tokens", label: L("today.todayTokens"), value: cnCount(tokens.values.reduce(0, +))))
                }
                if let api = d.apiValue?.perProvider[card.id], api.isFinite, api >= 0 {
                    out.rows.append(.init(id: "api", label: L("today.apiLabel"), value: L("today.apiAmount", String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), api), d.apiValue?.partial == true ? L("today.partial") : "")))
                }
                // 近 7 天 token 合计
                if let src {
                    let week = TokenChart.lastDays(today, count: 7).reduce(0) { $0 + (src.byDay[$1]?.values.reduce(0, +) ?? 0) }
                    if week > 0 { out.rows.append(.init(id: "week", label: L("today.trend"), value: cnCount(week))) }
                }
                let mine = running.filter { $0.provider == provider }
                if size == .medium && !mine.isEmpty {
                    out.rows.append(.init(id: "running", label: L("today.runningCount", mine.count), value: ""))
                }
                // 今天按模型（只有 token，套餐不按次计费）
                let models = (src?.byDay[today] ?? [:]).filter { !$0.key.isEmpty && $0.value > 0 }
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                let shownModels = size == .large ? 8 : 3
                out.models = models.prefix(shownModels).map {
                    .init(id: $0.key, label: TokenChart.shortModel($0.key, provider: provider), value: cnCount($0.value))
                }
                if size == .large {
                    if models.count > shownModels { out.more = L("today.moreModels", models.count - shownModels) }
                    out.bars = daily(src, today: today, money: false)
                    out.chartTitle = L("today.dailyTokens")   // 上面已有「近 7 天 token」合计行，图标题换个说法
                    out.tasks = taskRows(mine, limit: 3, detailed: false, now: now)
                }
            } else {
                if let days = side?.runwayDays ?? (provider == d.mainProvider ? d.burn?.runwayDays : nil), days.isFinite {
                    out.rows.append(.init(id: "runway", label: Runway.paygDays(days, days: "today.runway", hours: "today.runwayHours", underHour: "today.runwayUnderHour"), value: ""))
                }
                out.sparkline = daily(src, today: today, money: true)
                out.chartTitle = L("today.dailySpend")
                let currency = src?.currency ?? side?.currency ?? d.balance.currency ?? "CNY"
                if let tokens = src?.byDay[today]?.values.reduce(0, +), tokens > 0 {
                    out.rows.append(.init(id: "tokens", label: L("today.todayTokens"), value: cnCount(tokens)))
                }
                // 有用量却算不出花费的日子会被折线跳过：这时合计偏少，不显示
                let daysWithUsage = TokenChart.lastDays(today, count: 7).filter { iso in
                    (src?.byDay[iso] ?? [:]).contains { $0.value > 0 }
                }.count
                if !out.sparkline.isEmpty && out.sparkline.count >= daysWithUsage {
                    out.rows.append(.init(id: "weekSpend", label: L("today.weekSpend"), value: fmtMoney(out.sparkline.map(\.value).reduce(0, +), currency)))
                }
                var ranked: [(key: String, label: String, tokens: Int, cost: Double?)] = []
                if provider == d.mainProvider {
                    ranked = d.models.map { ($0.key, $0.label, $0.todayTokens, $0.todayCostKnown == false ? nil : $0.todayCny) }
                } else if let src {
                    ranked = (src.byDay[today] ?? [:]).filter { !$0.key.isEmpty }.map {
                        ($0.key, TokenChart.shortModel($0.key, provider: provider), $0.value, src.costByDay?[today]?[$0.key])
                    }
                }
                ranked.sort {
                    if $0.cost != $1.cost { return ($0.cost ?? -1) > ($1.cost ?? -1) }
                    if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
                    return $0.key < $1.key
                }
                out.models = ranked.prefix(size == .large ? 8 : 3).map { model in
                    let value = model.cost.map { L("today.modelUsage", cnCount(model.tokens), fmtMoney($0, src?.currency ?? side?.currency ?? d.balance.currency ?? "CNY")) } ?? cnCount(model.tokens)
                    return .init(id: model.key, label: model.label, value: value)
                }
                if size == .large {
                    out.bars = out.sparkline
                    if ranked.count > 8 { out.more = L("today.moreModels", ranked.count - 8) }
                }
            }
        case .spend:
            var sides = d.sides
            if let main = d.mainCardSide { sides.insert(main, at: 0) }
            else { sides.insert(.init(id: d.mainProvider.rawValue, name: ProviderRegistry.displayName(d.mainProvider), tank: nil, currency: d.balance.currency ?? "CNY", todayCost: d.today.known ? d.today.costCny : nil, status: L("side.ok")), at: 0) }
            for side in sides {
                guard let id = ProviderID(rawValue: side.id) else { continue }
                if ProviderRegistry.meter(id) == .quota {
                    if let api = d.apiValue?.perProvider[side.id] {
                        out.rows.append(.init(id: side.id, label: side.name, value: L("today.apiAmount", String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), api), d.apiValue?.partial == true ? L("today.partial") : ""), provider: id))
                    }
                } else if d.totalTodayCny != nil, let cost = side.todayCost {
                    out.rows.append(.init(id: side.id, label: side.name, value: fmtMoney(cost, side.currency), provider: id))
                }
            }
            if size == .large {
                // Daily plan API equivalents are not in AppData. This chart, like totalTodayCny, is paid cash only.
                let cash = sides.compactMap { ProviderID(rawValue: $0.id) }.filter { ProviderRegistry.meter($0) != .quota }
                let series = cash.map { id -> [TodayCardDetail.Bar] in
                    let src = source(d, provider: id)
                    let rate = src?.currency == "USD" ? d.cardExchangeRate : 1
                    return daily(src, today: today, money: true).map { b in
                        var b = b; b.value *= rate; b.text = fmtCNY(b.value); return b
                    }
                }
                if !series.isEmpty {
                    out.bars = normalized(TokenChart.lastDays(today, count: 7).compactMap { iso in
                        let values = series.compactMap { $0.first { $0.id == iso }?.value }
                        guard values.count == series.count else { return nil }
                        let total = values.reduce(0, +)
                        return .init(id: iso, label: String(iso.suffix(5)), value: total, text: fmtCNY(total))
                    })
                }
                out.chartTitle = L("today.dailySpend")
            }
        case .running:
            out.tasks = taskRows(running, limit: size == .large ? running.count : 3, detailed: size == .large, now: now)
        case .trend:
            let chart = d.tokenChart(main: d.mainProvider)
            if !chart.isEmpty && BalanceEstimatePresentation.showsTokenTrend(d) { out.chart = chart }
        }
        if let note = bottomNote(card) { out.rows.removeAll { $0.label == note && $0.value.isEmpty } }
        return out
    }

    static func dayDetail(_ d: AppData, iso: String?) -> [TodayCardDetail.Row] {
        guard let iso, let day = d.trend7.first(where: { $0.iso == iso }), let details = day.detail else { return [] }
        return details.keys.sorted { (details[$0]?.tokens ?? 0) > (details[$1]?.tokens ?? 0) || (details[$0]?.tokens == details[$1]?.tokens && $0 < $1) }.compactMap { key in
            guard let item = details[key] else { return nil }
            return .init(id: key, label: TokenChart.shortModel(key, provider: d.mainProvider),
                         value: item.costCny > 0 ? L("today.modelUsage", cnCount(item.tokens), fmtMoney(item.costCny, d.balance.currency ?? "CNY")) : cnCount(item.tokens))
        }
    }
}
