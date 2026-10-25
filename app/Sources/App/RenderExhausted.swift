import SwiftUI

extension RenderMode {
    /// 套餐用完（用户 10-19）：数字位置不写「剩 0%」，写下次重置时间（表盘：小字「下次重置」+ 大字「10:13」）。
    /// Codex 会话用完、当天重置；Claude 会话和本周都用完、跨天重置
    static func renderExhausted(model: UsageModel, dir: URL, originalTheme: UsageModel.ThemeMode) {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let tz = TimeZone(secondsFromGMT: 28800)!
        var codex = quotaMainState(now: now), deepseek = deepseekMainState(now: now)
        codex.snapshot?.quota?.windows[0].usedPercent = 100
        var claude = codex
        claude.id = .claudePlan
        claude.snapshot?.provider = .claudePlan
        claude.snapshot?.quota?.plan = nil
        claude.snapshot?.quota?.windows[0].usedPercent = 99.6
        claude.snapshot?.quota?.windows[1].usedPercent = 100
        claude.snapshot?.quota?.windows[1].resetsAt = now.addingTimeInterval(86400 + 3600)

        let keepData = model.data, keepState = model.mainState, keepSide = model.menuBarSide, keepPage = model.widgetPage
        let keepAlert = model.balanceAlertCny
        model.syncingAlert = true; model.balanceAlertCny = 10; model.syncingAlert = false
        model.fixedNow = now; model.fixedTimeZone = tz
        model.menuBarSide = nil
        for dark in [false, true] {
            model.themeMode = dark ? .dark : .light
            let p = Palette.of(dark)
            let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)
            model.data = previewData(main: codex, others: [deepseek, claude], now: now, timeZone: tz); model.mainState = codex
            renderFit(PanelView(model: model, p: p), name: "exhausted-main-\(dark ? "dark" : "light")", width: kPanelWidth, bg: bg, dir: dir)
        }
        model.themeMode = .light
        let p = Palette.of(false)
        let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)

        model.data = previewData(main: deepseek, others: [codex, claude], now: now, timeZone: tz); model.mainState = deepseek
        renderFit(PanelView(model: model, p: p), name: "exhausted-side-row", width: kPanelWidth, bg: bg, dir: dir)
        render(MenuInfoCard(model: model, hover: HoverState()).environment(\.colorScheme, .light)
                .padding(.vertical, 6).background(Color(white: 0.965)),
               name: "exhausted-menucard", size: CGSize(width: MenuCardHost.width, height: 170), dir: dir)

        model.data = previewData(main: codex, others: [deepseek], now: now, timeZone: tz); model.mainState = codex
        render(MenuBarPreview(model: model, quota: true), name: "exhausted-menubar", size: CGSize(width: 300, height: 286), dir: dir)
        model.widgetPage = "balance"
        renderFit(WidgetView(model: model), name: "exhausted-widget", width: 270, bg: bg, dir: dir)

        model.syncingAlert = true; model.balanceAlertCny = keepAlert; model.syncingAlert = false
        model.fixedNow = nil; model.fixedTimeZone = nil
        model.data = keepData; model.mainState = keepState; model.menuBarSide = keepSide; model.widgetPage = keepPage
        model.themeMode = originalTheme
    }
}
