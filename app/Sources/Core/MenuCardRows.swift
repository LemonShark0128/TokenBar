import Foundation

/// 右键菜单卡片：每个平台一行（图标 · 名称 · 状态话 · 读数），状态话直接取「今天」页平台卡的状态行，
/// 两处由同一份计算得出，说法和颜色永远一致（用户 11/5 选方案甲）。
struct MenuCardRow: Identifiable {
    struct Window: Identifiable {
        var id: String
        /// 「会话 ↻0:59」「本周 ↻1天」
        var title: String
        var remaining: Double
        var pace: Double?
        var severity: RunwaySeverity
        var value: String
    }
    var id: String
    var provider: ProviderID?
    var name: String
    var isMain: Bool
    /// 状态话；nil 时只显示名称和读数
    var state: String?
    /// 状态话颜色：riskSeverity 优先（红 / 橙），否则 warn 为提醒橙、其余灰（同今天卡 reminderTint）
    var severity: Int?
    var warn: Bool
    /// 没有额度数据时的说明（如「打开 Claude 桌面 App…」）可折行
    var stateMultiline = false
    var value: String
    var windows: [Window] = []
    var tasks: [RunningTask] = []
    var dimmed: Bool
    var a11y: String
    /// Claude 套餐登录失效：整行不灰显（提示要读得清），只把旧读数灰显
    var loginHint = false
    var glyph: AlertGlyph = .none
    var activity: RunningActivity? = nil
    var lastUpdated: Date? = nil
}

enum MenuCardRows {
    static func build(_ d: AppData, running: [RunningTask], now: Date, recentAgents: Set<ProviderID>? = nil,
                      paygActive: Set<ProviderID> = []) -> [MenuCardRow] {
        let agents = recentAgents ?? RunningActivity.recentAgents(running, now: now)
        let cards = TodayCards.build(d, running: [], now: now, recentAgents: agents, paygActive: paygActive)
            .filter { $0.kind == .platform }
        return cards.enumerated().map { index, c in
            let quota = c.provider.map { ProviderRegistry.meter($0) == .quota } ?? false
            var state = c.status ?? c.stateLineShort ?? c.stateLine ?? c.runwayChip
            var multiline = false
            if state == nil, quota, c.windows.isEmpty {
                // 没有额度数据：写引导（原卡片的兜底同此）
                state = c.footnote ?? L("codex.noDataNote")
                multiline = true
            }
            if let hint = c.loginHint { state = hint; multiline = true }
            let loginHint = c.loginHint != nil
            // 用完的套餐只写一行（状态话里已有恢复时刻）；过期 / 登录失效的不画条。
            // 用完按整个套餐算（同表盘、今天卡）：只有「本周（Opus）」见底时别的模型还能用，照常画条、写余量
            let exhausted = c.quotaBlocked
            // 用完时读数是 0%（本周用完、会话还剩 60% 时不能写「剩余 60%」；compactRemaining 用完时已是 0）
            let shown = c.compactRemaining
            let value = quota ? (shown.map { quotaLeftText($0) } ?? "—") : (c.value.isEmpty ? "—" : c.value)
            let windows = quota && !exhausted && !c.dimmed ? c.windows.map {
                MenuCardRow.Window(id: $0.id, title: $0.shortTitle.isEmpty ? $0.title : $0.shortTitle,
                                   remaining: $0.remaining, pace: $0.pace,
                                   severity: $0.severity, value: $0.value)
            } : []
            // 所属平台不在卡片里的任务挂到主平台下，不悄悄丢掉
            let tasks = running.filter { t in t.provider == c.provider || (index == 0 && !cards.contains { $0.provider == t.provider }) }
            let activityLabel = c.activity == nil ? "" : L("today.runningLabel")
            var parts = [c.title, activityLabel, state ?? "", value]
            for w in windows {
                parts.append(w.title + " " + w.value)
                if let pace = w.pace { parts.append(PaceText.short(remaining: w.remaining, pace: pace)) }
            }
            parts += tasks.map { RunningTaskText.a11y($0, now: now) }
            if c.dimmed { parts.append(L("a11y.notLatest")) }
            return MenuCardRow(id: c.id, provider: c.provider, name: c.title, isMain: index == 0,
                               state: state, severity: c.riskSeverity,
                               warn: c.footnoteWarn || c.runwayWarn || c.stateWarn,
                               stateMultiline: multiline, value: value, windows: windows, tasks: tasks,
                               dimmed: c.dimmed,
                               a11y: parts.filter { !$0.isEmpty }.map { A11yText.speak($0) }.joined(separator: L("a11y.sep")),
                               loginHint: loginHint, glyph: c.stateGlyph, activity: c.activity, lastUpdated: c.lastUpdated)
        }
    }

    /// 底部左侧：「今日实付 ¥2.53」；没有按量付费花费时为 nil
    static func paidLine(_ d: AppData) -> String? {
        d.totalTodayCny.map { L("menu.paidToday", d.totalIsApprox ? "≈" : "", fmtCNY($0)) }
    }
}
