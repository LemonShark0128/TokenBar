import Foundation

struct TodayCard: Identifiable {
    enum Kind: Equatable { case platform, spend, running, trend }
    struct Window: Identifiable {
        var id: String
        var title: String
        var value: String
        var remaining: Double
        var pace: Double?
        var severity: RunwaySeverity
        /// 小组件窄卡用：倒计时短写（「会话 ↻2:13」，一天以上「本周 ↻3天」）
        var shortTitle = ""
        var isReset = false
        /// 不带倒计时的窗口名（「会话」「本周」）：登录失效时写旧读数用，旧数据的倒计时会误导
        var name = ""
        var a11y: String {
            [title + " " + value, pace.map { PaceText.short(remaining: remaining, pace: $0) }]
                .compactMap { $0 }.joined(separator: L("a11y.sep"))
        }
    }
    struct Segment: Identifiable {
        var id: ProviderID
        var fraction: Double
    }
    var id: String
    var kind: Kind
    var title: String
    var provider: ProviderID? = nil
    var badge: String? = nil
    var status: String? = nil
    var riskSeverity: Int? = nil
    var footnote: String? = nil
    var footnoteWarn = false
    var footnoteMultiline = false
    var reservesFootnote = false
    var stats: [(label: String, value: String)] = []
    var runwayChip: String? = nil
    var runwayWarn = false
    var loginHint: String? = nil
    /// 登录失效时保留的旧读数：「上次读数：会话 剩余 59%，本周 剩余 77%」；没有额度为 nil
    var loginOldQuota: String? = nil
    var dimmed = false
    var lastUpdated: Date? = nil
    var activity: RunningActivity? = nil
    var value = ""
    var lines: [String] = []
    var windows: [Window] = []
    var segments: [Segment] = []
    var fullWidth = false
    var compactValue = ""
    var compactDetail = ""
    var compactRemaining: Double? = nil
    var compactPace: Double? = nil
    var spendCash = "—"
    var spendAPI = "—"
    var spendEmpty = true
    /// 状态行（标题下那一行）在没有 status 时写的「正常」状态：够用到重置 / 约 3 天 · 建议充值 / 近 7 天未使用…
    var stateLine: String? = nil
    /// 窄处（右键菜单卡）用的状态行短写；nil 时用 stateLine（目前只有英文「≈7 days · top up」和中文不同）
    var stateLineShort: String? = nil
    /// 套餐整个用不了（5 小时 / 每周窗口用完，同表盘的 quotaExhausted；「本周（Opus）」用完不算）
    var quotaBlocked = false
    var stateWarn = false
    /// 套餐卡底注在没有原有内容时写的本周预测；hintWarn = 预计重置前用完（橙）
    var hint: String? = nil
    var hintWarn = false
    /// 今日花费卡：实付和近 7 天日均差得多时的一行
    var spendNote: String? = nil
    var spendChange: SpendComparison.Change? = nil
    var a11y = ""

    var stateGlyph: AlertGlyph {
        AlertGlyph.level(status: status ?? stateLine, quotaBlocked: quotaBlocked, loginHint: loginHint,
                         riskSeverity: riskSeverity, warn: stateWarn || runwayWarn || footnoteWarn)
    }

    var footnoteGlyph: AlertGlyph { footnoteWarn ? stateGlyph : .none }
}

/// All copy and display values are prepared here; no defaults or I/O in the builder.
enum TodayCards {
    struct RunningTotal {
        var tokens: Int
        var costUSD: Double?
    }
    static func runningTotal(_ tasks: [RunningTask]) -> RunningTotal {
        let costs = tasks.compactMap(\.costUSD).filter { $0.isFinite && $0 >= 0 }
        return .init(tokens: tasks.reduce(0) { $0 + $1.tokens }, costUSD: costs.isEmpty ? nil : costs.reduce(0, +))
    }

    static func showsHome(preference: String, platformCount: Int) -> Bool {
        preference != "single" && platformCount >= 2
    }

    static func widgetPage(saved: String?, platformCount: Int) -> String {
        saved ?? (platformCount >= 2 ? "overview" : "balance")
    }

    static func widgetNavigation(isPlan: Bool, platformCount: Int, saved: String?) -> (items: [(String, String)], selected: String) {
        // Single-platform plan pickers retain both items for their hidden layout placeholder.
        var items = [("balance", L("widget.balance"))]
        if !isPlan || platformCount < 2 { items.append(("tokens", L("today.tokens"))) }
        if platformCount >= 2 { items.append(("overview", L("today.overview"))) }
        let page = widgetPage(saved: saved, platformCount: platformCount)
        return (items, isPlan && page == "tokens" ? "balance" : page)
    }

    static func planBadge(_ plan: String?) -> String? {
        guard let plan, let tier = GeminiCLIUsage.matchCanonicalTier(plan) else { return nil }
        switch tier {
        case "ultra": return L("today.badgeUltra")
        case "max": return L("today.badgeMax")
        case "plus": return L("today.badgePlus")
        case "pro": return L("today.badgePro")
        case "enterprise": return L("today.badgeEnterprise")
        case "team": return L("today.badgeTeam")
        case "free": return L("today.badgeFree")
        default: return nil
        }
    }

    static func build(_ d: AppData, running: [RunningTask], now: Date, recentAgents: Set<ProviderID>? = nil,
                      paygActive: Set<ProviderID> = []) -> [TodayCard] {
        var main = d.mainCardSide ?? AppData.Side(
            id: d.mainProvider.rawValue, name: ProviderRegistry.displayName(d.mainProvider),
            tank: d.balance.isQuota ? nil : d.balance.cny, currency: d.balance.currency ?? "CNY",
            todayCost: d.today.known ? d.today.costCny : nil, status: L("side.ok"),
            quotaRemaining: d.quota?.remainingPercent, quotaNote: d.quota?.note,
            quotaStale: d.quota?.stale ?? false, quotaRows: d.quota?.rows ?? [],
            resetCredits: d.quota?.resetCredits, resetCreditsCount: d.quota?.resetCreditsCount, plan: d.quota?.plan,
            monthCost: d.month.known ? d.month.costCny : nil, runwayDays: d.burn?.runwayDays,
            avgCnyPerDayWeek: d.burn?.avgCnyPerDayWeek,
            lastUpdated: d.balance.ageS.map { now.addingTimeInterval(-Double($0)) })
        main.resetCreditsCount = main.resetCreditsCount ?? d.quota?.resetCreditsCount
        main.plan = main.plan ?? d.quota?.plan
        main.quotaExhausted = main.quotaExhausted ?? d.quota?.exhausted     // 兜底拼的主平台也要知道用完（紧凑卡 / 菜单卡收成一行）
        let sides = [main] + d.sides
        let agents = recentAgents ?? RunningActivity.recentAgents(running, now: now)
        var cards = sides.compactMap { side in
            platform(side, now: now, recentAgents: agents, paygActive: paygActive)
        }
        var spend = TodayCard(id: "spend", kind: .spend, title: L("today.spend"), fullWidth: running.isEmpty)
        if let total = d.totalTodayCny {
            spend.value = (d.totalIsApprox ? "≈" : "") + fmtCNY(total)
            spend.spendCash = spend.value
            spend.spendEmpty = false
            spend.spendChange = SpendComparison.change(today: total, yesterday: d.yesterdaySameTimeCny)
        }
        if let total = d.totalTodayCny, d.yesterdaySameTimeCny == nil {
            // 只算有花费数据的按量付费平台；美元按卡片汇率换算，和 totalTodayCny 同口径
            let cash = sides.filter { side in
                ProviderID(rawValue: side.id).map { ProviderRegistry.meter($0) != .quota } ?? false
            }.filter { $0.todayCost != nil }
            let avgs = cash.map { side in side.avgCnyPerDayWeek.map { $0 * (side.currency == "USD" ? d.cardExchangeRate : 1) } }
            if !cash.isEmpty, avgs.allSatisfy({ $0 != nil }) {
                let avg = avgs.compactMap { $0 }.reduce(0, +)
                if avg > 0, total.isFinite {
                    let delta = (total / avg - 1) * 100
                    // 只提示「高于」：今天还没过完，上午拿到目前的花费比全天日均几乎总是「低于」
                    if delta >= 30 { spend.spendNote = L("today.paidAboveAvg", Int(delta.rounded())) }
                }
            }
        }
        if let api = d.apiValue {
            let suffix = api.partial ? L("today.partial") : ""
            spend.spendAPI = L("today.apiAmount", String(format: (api.todayUSD * 100).rounded() >= 10_000 ? "%.0f" : "%.2f", locale: Locale(identifier: "en_US_POSIX"), api.todayUSD), suffix)
            spend.spendEmpty = false
            spend.lines = [L("today.api", String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), api.todayUSD), suffix),
                           L("today.week", String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), api.weekUSD), suffix)]
        }
        let amounts: [(ProviderID, Double)] = sides.compactMap { side in
            guard let id = ProviderID(rawValue: side.id) else { return nil }
            let amount: Double
            if ProviderRegistry.meter(id) == .quota {
                amount = (d.apiValue?.perProvider[side.id] ?? 0) * d.cardExchangeRate
            } else {
                // A missing cash column must not contribute hidden value to the bar.
                guard d.totalTodayCny != nil else { return nil }
                amount = (side.todayCost ?? 0) * (side.currency == "USD" ? d.cardExchangeRate : 1)
            }
            return amount.isFinite && amount > 0 ? (id, amount) : nil
        }
        let total = amounts.reduce(0) { $0 + $1.1 }
        if total > 0 { spend.segments = amounts.map { .init(id: $0.0, fraction: $0.1 / total) } }
        spend.a11y = spend.spendEmpty ? spoken([spend.title, L("common.noData")])
            : spoken([spend.title, L("today.paid"), spend.spendCash, L("today.apiLabel"), spend.spendAPI]
                     + Array(spend.lines.dropFirst()) + [spend.spendChange?.a11y ?? spend.spendNote ?? ""])
        cards.append(spend)
        // 加了会「在跑」的平台（Claude / Codex）时，没有任务也留这张卡写空状态，格子不空着
        let canRun = sides.contains { ProviderID(rawValue: $0.id).map(MenuBarSecondary.canRun) ?? false }
        if running.isEmpty && canRun {
            var card = TodayCard(id: "running", kind: .running, title: L("today.running"))
            card.status = L("today.runningEmpty")
            card.footnote = L("today.runningEmptyHint")
            card.a11y = spoken([card.title, L("today.runningEmpty")])
            cards.append(card)
        }
        if !running.isEmpty {
            var card = TodayCard(id: "running", kind: .running, title: L("today.running"), badge: String(running.count))
            if !agents.isEmpty { card.activity = .unspecified }
            let total = runningTotal(running)
            var summary = L("today.runningTotal", RunningTaskText.tokens(total.tokens))
            if let cost = total.costUSD {
                summary += L("today.runningCost", String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), cost))
            }
            card.footnote = summary
            card.a11y = spoken([card.title, L("today.count", running.count), card.footnote ?? ""] + RunningTaskText.visible(running).shown.map { RunningTaskText.a11y($0, now: now) })
            cards.append(card)
        }
        let chart = d.tokenChart(main: d.mainProvider)
        if !chart.isEmpty {
            var card = TodayCard(id: "trend", kind: .trend, title: L("today.trend"), fullWidth: true)
            card.a11y = chart.a11yLabel(incomplete: d.trendIncomplete)
            cards.append(card)
        }
        return cards
    }

    private static func spoken(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.map { A11yText.speak($0) }.joined(separator: L("a11y.sep"))
    }

    /// 本周窗口按整段窗口的平均节奏（条上那根竖线的口径）推算：重置时还剩多少，或会在重置前哪天用完。
    /// 窗口刚开始（已过不到 10%）、没用过、已重置或读数异常时为 nil
    static func weeklyForecast(_ row: AppData.QuotaRow, now: Date) -> (remainingAtReset: Double?, runsOutAt: Date?)? {
        let span: TimeInterval = 7 * 86400
        guard !row.isReset, let reset = row.resetsAt, reset > now, row.usedPercent.isFinite else { return nil }
        let used = max(0, min(100, row.usedPercent))
        let elapsed = span - reset.timeIntervalSince(now)
        guard used > 0, used < 100, elapsed >= span * 0.1, elapsed < span else { return nil }
        let perSecond = used / elapsed
        let projected = perSecond * span
        if projected < 100 { return (max(0, 100 - projected), nil) }
        return (nil, now.addingTimeInterval((100 - used) / perSecond))
    }

    /// 「已用完 · 21:36 恢复」；跨天时只写日期（「已用完 · 11/12 恢复」，带时刻小卡放不下）
    static func usedUpBack(_ side: AppData.Side) -> String? {
        guard let clock = side.quotaExhausted?.clock else { return nil }
        let parts = clock.split(separator: " ")
        return parts.count >= 2 ? L("today.usedUpBackDay", String(parts[0])) : L("today.usedUpBack", clock)
    }

    /// 「周六」「Sat」；当天写「今天」
    static func weekdayText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L("today.weekday.today") }
        let names = L("today.weekdays").split(separator: ",").map(String.init)
        let i = calendar.component(.weekday, from: date) - 1
        guard names.indices.contains(i) else { return "" }
        return QuotaText.weekdayName(date, now: now, calendar: calendar, name: names[i])     // 7 天后的同一天写「下周四」
    }

    private static func platform(_ side: AppData.Side, now: Date, recentAgents: Set<ProviderID>,
                                 paygActive: Set<ProviderID>) -> TodayCard? {
        guard let id = ProviderID(rawValue: side.id) else { return nil }
        let quota = ProviderRegistry.meter(id) == .quota
        var c = TodayCard(id: side.id, kind: .platform, title: side.name, provider: id,
                          badge: quota ? planBadge(side.plan) : nil,
                          status: side.needsAttention ? side.status : ((side.riskSeverity ?? 0) > 0 ? side.riskText : nil),
                          dimmed: side.quotaStale || side.dataStale || AppDataMapping.isCredentialProblem(side.status),
                          lastUpdated: side.lastUpdated,
                          activity: RunningActivity.kind(for: id, recentAgents: recentAgents, paygActive: paygActive))
        c.riskSeverity = side.riskSeverity
        // 用完时状态行带上恢复时刻（「已用完 · 21:36 恢复」）
        if c.status == L("quota.usedUp"), let back = usedUpBack(side) { c.status = back }
        c.reservesFootnote = quota
        c.footnote = c.status
        c.footnoteWarn = c.status != nil
        if quota {
            if c.footnote == nil {
                c.footnote = side.resetCreditsCount.flatMap { $0 > 0 ? L("today.resetCredits", $0) : nil } ?? side.resetCredits
            }
            // Include only the session and weekly windows, in that order.
            let session = side.quotaRows.first { $0.windowKind == "session" }
            let weekly = side.quotaRows.first { $0.windowKind == "weekly" || $0.id == "weekly" }
            let rows = [session, weekly].compactMap { $0 }
            let visible = rows.isEmpty ? Array(side.quotaRows.prefix(2)) : rows
            c.windows = visible.map { row in
                let reset = row.isReset || row.resetsAt.map { $0 <= now } == true
                let remaining = row.remaining(at: now) ?? 100
                let name = row.windowKind == "session" ? L("today.session") : row.windowKind == "weekly" ? L("today.weekly") : row.name
                let title = !reset ? (row.countdown ?? row.resetShort ?? row.reset).map { L("today.reset", name, $0) } ?? name : name
                let narrowName = row.windowKind == "session" ? L("today.sessionNarrow") : name
                var shortTitle = narrowName
                if !reset, let at = row.resetsAt, at > now {
                    let minutes = max(1, Int(at.timeIntervalSince(now) / 60))
                    // 一天以上只写天数（「6天23小时」窄卡放不下）
                    let short = minutes < 1440 ? String(format: "%d:%02d", minutes / 60, minutes % 60)
                        : L("quota.countdown.days", minutes / 1440)
                    shortTitle = L("today.resetShort", narrowName, short)
                } else if !reset, let text = row.countdown ?? row.resetShort {
                    shortTitle = L("today.resetShort", narrowName, text)
                }
                return TodayCard.Window(id: row.id, title: title,
                                        value: reset ? L("quota.windowResetShort") : quotaLeftText(remaining),
                                        remaining: remaining, pace: reset ? nil : row.paceRemainingPercent,
                                        severity: QuotaLevel.severity(usedPercent: 100 - remaining),
                                        shortTitle: shortTitle, isReset: reset, name: name)
            }
            c.footnoteMultiline = c.windows.isEmpty
            if c.windows.isEmpty {
                // 「读不到记录」本身不说原因：有原因（如 Claude Code 没登录、怎么登）时底注写原因，状态仍在上面；
                // 凭据失效等别的状态照旧优先
                if c.status == L("side.noRecords"), let note = side.quotaNote {
                    c.footnote = note
                } else {
                    c.footnote = c.status ?? side.quotaNote ?? c.footnote
                }
            }

            if (id == .claudePlan || id == .geminiPlan), AppDataMapping.isCredentialProblem(side.status) {
                c.loginHint = side.quotaNote ?? L(id == .geminiPlan ? "gemini.cli.needsLogin" : "cli.needsLogin")
                if !c.windows.isEmpty {
                    c.loginOldQuota = L("today.loginOldQuota", c.windows.map { "\($0.name) \($0.value)" }.joined(separator: L("today.loginOldQuotaSep")))
                }
                c.footnote = c.loginHint
                c.footnoteMultiline = true
                c.footnoteWarn = true
            }

            // 用完时（含每周用完、5 小时窗口还有余）紧凑卡按显示口径写 0%，不写 5 小时窗口的余量（同表盘）
            let blocked = side.quotaExhausted != nil
            c.quotaBlocked = blocked
            c.compactRemaining = blocked ? (side.quotaRemaining ?? 0) : (c.windows.first?.remaining ?? side.quotaRemaining)
            c.compactPace = blocked ? nil : c.windows.first?.pace
            c.compactValue = c.compactRemaining.map { quotaRemainingPercent($0) } ?? "—"
            if !c.windows.isEmpty && !c.dimmed {
                let forecast = side.quotaRows.first { $0.windowKind == "weekly" || $0.id == "weekly" }
                    .flatMap { weeklyForecast($0, now: now) }
                let runsOut = forecast?.runsOutAt.map { L("today.weekRunsOut", weekdayText($0, now: now)) }
                if c.windows.contains(where: { !$0.isReset && QuotaText.isExhausted(remaining: $0.remaining) }) {
                    // 有窗口见底却没走风险判定（例如显示的不是那个窗口）：不能写「够用」
                    c.stateLine = usedUpBack(side) ?? L("quota.usedUp")
                    c.stateWarn = true
                    c.riskSeverity = c.riskSeverity ?? RunwaySeverity.danger.rawValue
                } else if let runsOut {
                    c.stateLine = runsOut
                    c.stateWarn = true
                } else {
                    c.stateLine = L("runway.enough")
                }
                // 底注原有内容（账号说明、可重置次数）优先；状态行被风险占着时，本周用完的预测挪到底注
                if bottomNote(c) == nil {
                    if let runsOut {
                        if c.status != nil { c.hint = runsOut; c.hintWarn = true }
                    } else if let left = forecast?.remainingAtReset {
                        c.hint = L("today.weekAtReset", Int(left.rounded()))
                    }
                }
            }
        } else {
            c.value = fmtMoney(side.tank, side.currency)
            c.compactValue = c.value
            if let today = side.todayCost {
                c.compactDetail = L("today.cashToday", fmtMoney(today, side.currency))
                c.stats.append((L("today.statToday"), fmtMoney(today, side.currency)))
            }
            if let month = side.monthCost { c.stats.append((L("today.statMonth"), fmtMoney(month, side.currency))) }
            // 有账单 / 估算花费时才有日均（没有花费数据时 7 天都是 0，不能当「没用」）
            let avg = side.monthCost == nil ? nil : side.avgCnyPerDayWeek.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            if let avg { c.stats.append((L("today.statAvg"), fmtMoney(avg, side.currency))) }
            if let days = side.runwayDays, days.isFinite, days <= 30 {
                c.runwayChip = Runway.paygDays(days, days: "today.runwayChip", hours: "today.runwayHoursChip", underHour: "today.runwayUnderHourChip")
                c.runwayWarn = days < 7
            }
            if !c.dimmed {
                // 按余额变化估算花费的平台（Kimi）刚添加 / 采样稀疏时日均也是 0，不能判「未使用」
                let estimated = ProviderRegistry.capabilities(id).estimatesSpendFromBalance
                if avg == 0 && (side.todayCost ?? 0) == 0 && !estimated {
                    // 日均只覆盖几天（OpenRouter 月初又是周初）就照实写几天；只有今天一天不写（今日 0 已在下面）
                    let days = side.avgDays ?? 7
                    if days >= 7 { c.stateLine = L("today.unused7d") } else if days >= 2 { c.stateLine = L("today.unusedDays", days) }
                } else if let days = side.runwayDays, days.isFinite {
                    c.stateLine = days < 7
                        ? Runway.paygDays(days, days: "today.runwayTopUp", hours: "today.runwayHoursTopUp", underHour: "today.runwayUnderHourTopUp")
                        : days <= 30 ? L("today.runwayChip", String(Int(days))) : L("today.runwayLong")
                    if days < 7 {
                        c.stateLineShort = Runway.paygDays(days, days: "today.runwayTopUpShort", hours: "today.runwayHoursTopUpShort",
                                                           underHour: "today.runwayUnderHourTopUpShort")
                    }
                    c.stateWarn = days < 7
                }
            }
            // 金额是 Key 剩余上限（OpenRouter，用户 11/7 选乙）：写在大数字上面那行；底注放不下（会把大数字挤小）
            if side.tankIsKeyLimit {
                if c.stateWarn, let days = side.runwayDays, days.isFinite {
                    // 快用完：充值没用，要调高 Key 上限，所以不写「建议充值」；窄处的短写同一句
                    c.stateLine = Runway.paygDays(days, days: "today.keyLimitRunsOutDays", hours: "today.keyLimitRunsOutHours",
                                                  underHour: "today.keyLimitRunsOutUnderHour")
                    c.stateLineShort = c.stateLine
                } else {
                    c.stateLine = c.stateLine.map { L("today.keyLimitState", $0) } ?? L("today.keyLimitNote")
                }
            }
        }
        // 状态行有没有念过天数（只写了「Key 剩余额度」不算）
        let stateSaysDays = c.stateLine != nil && c.stateLine != L("today.keyLimitNote")
        var details = c.stats.map { $0.label + " " + $0.value }
        if let resets = side.resetCredits { details.append(resets) }
        if quota, let note = side.quotaNote { details.append(note) }
        if !quota, let days = side.runwayDays, days.isFinite, !stateSaysDays || days > 30 {   // 状态行已念过天数就不重复
            details.append(Runway.paygDays(days, days: "today.runway", hours: "today.runwayHours", underHour: "today.runwayUnderHour"))
        }
        if let hint = c.hint { details.append(hint) }
        let activityLabel = c.activity == nil ? "" : L("today.runningLabel")
        if let hint = c.loginHint {
            c.a11y = spoken([c.title, activityLabel, c.badge ?? "", c.loginOldQuota ?? "", hint, L("a11y.notLatest")])
            return c
        }
        c.a11y = spoken([c.title, activityLabel, c.badge ?? "", c.status ?? c.stateLine ?? "", c.value]
                        + c.windows.map(\.a11y) + details)
        return c
    }
}
