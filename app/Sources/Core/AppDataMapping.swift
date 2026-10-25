import Foundation

/// UsageStore 的平台状态 → 现有界面使用的 AppData（字段与原 /api/app 一一对应，界面代码不用大改）
enum AppDataMapping {
    static func appData(main: PlatformState, others: [PlatformState], now: Date, timeZone: TimeZone,
                        usdToCny: Decimal = Decimal(string: "7.1")!,
                        localUsage: [ProviderID: DailyModelTokens] = [:]) -> AppData {
        let s = main.snapshot
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

        // 余额：有快照用快照；冷启动断网用最后一次采样
        let balanceValue = s?.balance?.amount ?? main.lastSample?.balance
        let seenAt = s?.fetchedAt ?? main.lastSample?.t
        let balance = AppData.Balance(cny: balanceValue.map(double), source: "平台",
                                      status: s == nil || main.snapshotFromDisk ? "离线" : "可用",
                                      ageS: seenAt.map { Int(now.timeIntervalSince($0)) },
                                      currency: currencyCode(of: main))

        let isBill = s?.source == .bill
        // 没有快照（冷启动断网）时显示的是最后一次采样：标「离线」，不能当成「只有余额」去提示登录控制台
        let source = s == nil ? "离线" : (isBill ? "平台账单" : "只有余额")
        let todayTokens = (s?.byModel ?? []).reduce(0) { $0 + $1.cacheHit + $1.cacheMiss + $1.output }
        // 本月：按本月日桶的按模型汇总（旧快照没有这项时为 0，不再拿近 7 天顶替）
        let monthModels = s?.monthByModel ?? []
        let monthTokens = monthModels.reduce(0) { $0 + $1.cacheHit + $1.cacheMiss + $1.output }

        let models = (s?.byModel ?? []).map { m -> AppData.ModelUse in
            let tokens = m.cacheHit + m.cacheMiss + m.output
            return AppData.ModelUse(key: m.model, label: modelLabel(m.model), cacheHit: m.cacheHit,
                                    cacheMiss: m.cacheMiss, output: m.output, todayTokens: tokens,
                                    todayCny: double(m.cost?.amount ?? 0),
                                    monthCny: double(monthModels.first { $0.model == m.model }?.cost?.amount ?? 0),
                                    hitRate: hitRate(m.cacheHit, m.cacheMiss), calls: m.requests,
                                    todayCostKnown: m.cost != nil)
        }

        let trend = (s?.trend7 ?? []).map { day -> AppData.Day in
            var byModel: [String: Int] = [:]
            var detail: [String: AppData.Day.Detail] = [:]
            for m in day.models {
                let t = m.cacheHit + m.cacheMiss + m.output
                byModel[m.model] = t
                detail[m.model] = AppData.Day.Detail(tokens: t, costCny: double(m.cost?.amount ?? 0), cacheHit: m.cacheHit,
                                                     cacheMiss: m.cacheMiss, output: m.output,
                                                     hitRate: hitRate(m.cacheHit, m.cacheMiss))
            }
            return AppData.Day(date: String(day.day.suffix(5)), iso: day.day, totalTokens: day.tokens,
                               byModel: byModel, detail: detail)
        }

        let burn = main.burn.map {
            AppData.Burn(cnyPerHourRate: $0.perHourRecent.map(double), cnyPerDayRate: $0.perHourDay.map(double),
                         avgCnyPerDayWeek: double($0.avgPerDayWeek), runwayDays: $0.runwayDays.map(double),
                         spike: $0.spike)
        }

        var d = AppData(nowLocal: fmt.string(from: now), balance: balance,
                        today: AppData.CostTok(costCny: double(s?.today?.amount ?? 0), tokens: todayTokens, source: source),
                        month: AppData.CostTok(costCny: double(s?.month?.amount ?? 0), tokens: monthTokens, source: source),
                        models: models, trend7: trend, burn: burn)
        d.trendIncomplete = s?.detailTruncated == true
        d.monthModelsIncomplete = s?.monthByModelPartial == true
        d.sides = others.filter { $0.status != .notAdded }.map { side($0, now: now, timeZone: timeZone) }
        if ProviderRegistry.meter(main.id) == .quota { applyQuota(&d, main: main, now: now, timeZone: timeZone) }
        d.tokenSources = tokenSources(main: main, others: others, localUsage: localUsage)

        // 今日合计：主平台 + 各辅助平台，美元按设置汇率换成人民币
        var total: Decimal = 0, any = false, usd = false
        for st in [main] + others {
            guard st.status != .notAdded, let t = st.snapshot?.today else { continue }
            total += t.converted(to: .cny, usdToCny: usdToCny).amount
            any = true
            if t.currency == .usd { usd = true }
        }
        d.totalTodayCny = any ? double(total) : nil
        d.totalIsApprox = usd
        return d
    }

    /// 套餐平台作主平台：油箱读数 = 剩余百分比；金额类字段清空，额度明细放进 d.quota
    private static func applyQuota(_ d: inout AppData, main: PlatformState, now: Date, timeZone: TimeZone) {
        defer {
            if case .stale = main.status { d.quota?.staleNote = statusText(main, now: now) }
            d.quota?.stale = main.quotaTooOld(now: now)
        }
        let s = main.snapshot
        let q = s?.quota
        d.balance = AppData.Balance(cny: q?.displayRemainingPercent(at: now), source: AppData.quotaSource,
                                    status: s == nil ? "离线" : "可用",
                                    ageS: s.map { Int(now.timeIntervalSince($0.fetchedAt)) }, currency: "PCT")
        d.today = AppData.CostTok(costCny: 0, tokens: 0, source: "无")
        d.month = AppData.CostTok(costCny: 0, tokens: 0, source: "无")
        d.models = []; d.trend7 = []; d.burn = nil
        d.trendIncomplete = false; d.monthModelsIncomplete = false
        guard let q else {
            d.quota = AppData.QuotaView(remainingPercent: nil, headline: nil, secondLine: nil, rows: [],
                                        lastUsed: nil, note: s?.quotaNote ?? main.errorDetail)
            return
        }
        let display = q.displayWindow
        func resetLine(_ w: QuotaWindow) -> String? {
            w.isReset(at: now) ? nil : QuotaText.resetText(w, now: now, timeZone: timeZone)
        }
        var headline: String?, headlineCompact: String?
        if let t = display {
            let r = QuotaText.resetText(t, now: now, timeZone: timeZone)
            headline = [QuotaText.windowName(t.kind), r].compactMap { $0 }.joined(separator: " · ")
            if t.resetIsEstimated {
                headlineCompact = [QuotaText.windowName(t.kind), QuotaText.resetText(t, now: now, timeZone: timeZone, marker: false)]
                    .compactMap { $0 }.joined(separator: " · ")
            }
        }
        var second: String?
        if let other = q.windows.first(where: { $0 != display }) {
            let name = QuotaText.windowName(other.kind)
            if other.isReset(at: now) { second = L("quota.windowReset", name) }
            else {
                second = [L("quota.windowUsed", name, Int(other.effectiveUsed(at: now).rounded())), resetLine(other)]
                    .compactMap { $0 }.joined(separator: " · ")
            }
        }
        let rows = q.windows.map { w in
            AppData.QuotaRow(id: QuotaText.windowName(w.kind), name: QuotaText.windowName(w.kind),
                             usedPercent: w.effectiveUsed(at: now), isReset: w.isReset(at: now),
                             reset: w.isReset(at: now) ? nil : QuotaText.resetText(w, now: now, timeZone: timeZone, marker: false),
                             resetShort: w.isReset(at: now) ? nil
                                : QuotaText.resetCompact(w, now: now, timeZone: timeZone))
        }
        d.quota = AppData.QuotaView(remainingPercent: q.displayRemainingPercent(at: now), headline: headline, secondLine: second,
                                    rows: rows, lastUsed: QuotaText.lastUsed(q.observedAt, now: now) + (q.estimated ? L("quota.estimatedSuffix") : ""), note: nil,
                                    plan: QuotaText.planName(q.plan), headlineCompact: headlineCompact,
                                    exhausted: QuotaText.exhaustion(q, now: now, timeZone: timeZone))
    }

    /// 合并图的其他来源：已添加的按量付费平台取有账单的 trend7（主平台的 trend7 已在 AppData.trend7 里），
    /// 套餐平台（包括作主平台的）取本机日志；没有用量的平台不列
    static func tokenSources(main: PlatformState, others: [PlatformState],
                             localUsage: [ProviderID: DailyModelTokens]) -> [TokenSource] {
        var out: [TokenSource] = []
        for st in [main] + others where st.status != .notAdded {
            var byDay: DailyModelTokens = [:]
            // 按量付费平台：账单里明确给了金额的模型才记花费（图例写「¥x」）；金额为 nil 的不记，免得写成 ¥0
            var costByDay: [String: [String: Double]] = [:]
            var currency: String? = nil
            if ProviderRegistry.meter(st.id) == .quota {
                byDay = localUsage[st.id] ?? [:]
            } else if st.id != main.id, let s = st.snapshot, s.source == .bill {
                currency = currencyCode(of: st)
                for day in s.trend7 {
                    var models: [String: Int] = [:]
                    var costs: [String: Double] = [:]
                    var unknown: Set<String> = []     // 同名模型里有一条没金额：整行不写花费
                    for m in day.models {
                        models[m.model, default: 0] += m.cacheHit + m.cacheMiss + m.output
                        if let c = m.cost { costs[m.model, default: 0] += double(c.amount) } else { unknown.insert(m.model) }
                    }
                    for m in unknown { costs[m] = nil }
                    let rest = day.tokens - models.values.reduce(0, +)
                    if rest > 0 { models[""] = rest }
                    // 当天完全没有按模型拆分：整天的花费就是这一段的花费
                    if day.models.isEmpty, let c = day.cost { costs[""] = double(c.amount) }
                    models = models.filter { $0.value > 0 }
                    costs = costs.filter { models[$0.key] != nil }
                    if !models.isEmpty { byDay[day.day] = models }
                    if !costs.isEmpty { costByDay[day.day] = costs }
                }
            }
            byDay = byDay.filter { !$0.value.isEmpty }
            if !byDay.isEmpty {
                out.append(TokenSource(provider: st.id, byDay: byDay, costByDay: costByDay.isEmpty ? nil : costByDay,
                                       currency: costByDay.isEmpty ? nil : currency))
            }
        }
        return out
    }

    /// 小组件标题行的平台名：添加了不止一个平台时才写，只用一个平台时界面不变
    static func widgetTitle(mainName: String, otherCount: Int) -> String? {
        otherCount > 0 ? mainName : nil
    }

    struct PlatformMenuItem: Equatable { var id: String; var title: String; var isMain: Bool }

    /// 小组件标题点开的平台列表：当前主平台在最前（打勾），其余按面板「其他平台」的顺序；只有一个平台时不弹
    static func widgetPlatformMenu(mainID: String, mainName: String, sides: [AppData.Side]) -> [PlatformMenuItem] {
        guard !sides.isEmpty else { return [] }
        return [PlatformMenuItem(id: mainID, title: mainName, isMain: true)]
            + sides.map { PlatformMenuItem(id: $0.id, title: $0.name, isMain: false) }
    }

    /// 平台币种：有快照按快照里的金额，否则按注册表
    static func currencyCode(of st: PlatformState) -> String {
        let s = st.snapshot
        let c = s?.balance?.currency ?? s?.today?.currency ?? ProviderRegistry.currency(st.id)
        return c.rawValue
    }

    /// 一个平台的「一行」数据；金额保持该平台的币种
    static func side(_ st: PlatformState, now: Date, timeZone: TimeZone = .current) -> AppData.Side {
        let s = st.snapshot
        if ProviderRegistry.meter(st.id) == .quota {
            let q = s?.quota
            return AppData.Side(id: st.id.rawValue, name: ProviderRegistry.displayName(st.id),
                                tank: nil, currency: "PCT", todayCost: nil,
                                status: statusText(st, now: now),
                                quotaRemaining: q?.displayRemainingPercent(at: now),
                                quotaReset: q?.displayWindow.flatMap { QuotaText.resetCompact($0, now: now, timeZone: timeZone) },
                                quotaExhausted: QuotaText.exhaustion(q, now: now, timeZone: timeZone),
                                menuQuota: MenuBarText.quotaReading(q, now: now, timeZone: timeZone),
                                quotaNote: q == nil ? (s?.quotaNote ?? st.errorDetail) : nil,
                                quotaStale: st.quotaTooOld(now: now))
        }
        let tank = s?.balance?.amount ?? st.lastSample?.balance
        let today = s?.source == .bill ? s?.today?.amount : nil
        return AppData.Side(id: st.id.rawValue, name: ProviderRegistry.displayName(st.id),
                            tank: tank.map(double), currency: currencyCode(of: st),
                            todayCost: today.map(double), status: statusText(st, now: now))
    }

    /// 平台状态 → 一行里的短文字
    static func statusText(_ st: PlatformState, now: Date) -> String {
        switch st.status {
        case .loading: return L("side.connecting")
        case .credentialInvalid: return L("side.credentialInvalid")
        case .consoleLoginNeeded: return L("side.consoleLoginExpired")
        case .schemaChanged: return L("side.apiChanged")
        case .rateLimited: return L("side.rateLimited")
        case .offline: return ProviderRegistry.meter(st.id) == .quota ? L("side.noRecords") : L("side.cantReach")
        case .notAdded: return L("side.notAdded")
        case .stale(let m):
            if ProviderRegistry.meter(st.id) == .quota {
                let mins = st.quotaAge(now: now).map { Int($0 / 60) } ?? m
                return L("status.minAgoNotUpdated", mins)
            }
            return L("status.minAgo", m)
        case .ok:
            if case .expiring(let d)? = st.snapshot?.credential { return d <= 0 ? L("side.loginExpiresToday") : L("side.loginExpiresInDays", d) }
            // 套餐平台数据来自本机日志/钩子，fetchedAt 旧不代表过时
            if ProviderRegistry.meter(st.id) != .quota, let t = st.snapshot?.fetchedAt, now.timeIntervalSince(t) > 600 {
                return L("status.minAgo", Int(now.timeIntervalSince(t) / 60))
            }
            return L("side.ok")
        }
    }

    /// deepseek-v4-pro → V4 Pro（与原 Python 采集的 _model_label 一致）
    static func modelLabel(_ name: String) -> String {
        name.replacingOccurrences(of: "deepseek-", with: "").replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "-", with: " ").capitalized
    }

    /// 界面上的命中率：没有缓存数据（硅基流动等）显示「—」，与总览「缓存命中」一致
    static func hitRateText(hit: Int, miss: Int, rate: Double) -> String {
        hit + miss > 0 ? String(format: "%.2f%%", rate) : "—"
    }

    static func hitRate(_ hit: Int, _ miss: Int) -> Double {
        hit + miss > 0 ? (Double(hit) * 10000 / Double(hit + miss)).rounded() / 100 : 0
    }

    /// 经字符串转换：NSDecimalNumber.doubleValue 会把 6.27 变成 6.2700000000000005
    static func double(_ d: Decimal) -> Double { Double("\(d)") ?? NSDecimalNumber(decimal: d).doubleValue }
}
