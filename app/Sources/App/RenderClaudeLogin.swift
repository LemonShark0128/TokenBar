import SwiftUI

extension RenderMode {
    /// 登录失效仍保留旧额度；单卡绕过 ScrollView，深浅色都能检查完整操作提示。
    static func renderClaudeLogin(model: UsageModel, dir: URL, originalTheme: UsageModel.ThemeMode) {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let tz = TimeZone(secondsFromGMT: 28800)!
        var claude = PlatformState(id: .claudePlan, snapshot: nil, burn: nil, status: .offline)
        claude.snapshot = quotaMainState(now: now).snapshot
        claude.snapshot?.provider = .claudePlan
        claude.status = .credentialInvalid
        claude.errorDetail = ClaudePlanProvider.cliHint(ClaudeCLIUsage.needsLogin)
        let data = previewData(main: deepseekMainState(now: now), others: [quotaMainState(now: now), claude], now: now, timeZone: tz)
        let keepData = model.data, keepState = model.mainState, keepLayout = model.todayLayout, keepHome = model.panelHome
        let keepNow = model.fixedNow, keepTasks = model.runningTasks
        model.fixedNow = now; model.panelHome = "today"; model.runningTasks = []
        for dark in [false, true] {
            model.themeMode = dark ? .dark : .light
            let p = Palette.of(dark)
            let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)
            model.data = data; model.mainState = deepseekMainState(now: now)
            model.todayLayout = TodayLayout.defaultLayout(platformIDs: ["deepseek", "codexPlan", "claudePlan"])
            if let card = TodayCards.build(data, running: [], now: now).first(where: { $0.provider == .claudePlan }) {
                render(TodayPlatformCard(card: card, p: p, compact: false), name: "claude-login-old-quota-\(dark ? "dark" : "light")",
                       size: CGSize(width: 210, height: 155), dir: dir)
            }
            renderFit(PanelView(model: model, p: p), name: "panel-claude-login-\(dark ? "dark" : "light")", width: kPanelWidth, bg: bg, dir: dir)
        }
        model.data = keepData; model.mainState = keepState; model.todayLayout = keepLayout; model.panelHome = keepHome
        model.fixedNow = keepNow; model.runningTasks = keepTasks
        model.themeMode = originalTheme
    }
}
