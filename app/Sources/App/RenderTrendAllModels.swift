import SwiftUI

extension RenderMode {
    /// 今天页近 7 天卡（中号）列不完时「另 N 个模型 ›」可点（用户 11/6）：今天页一张（中号卡挨着小卡，只放得下几行），
    /// 加上点开后弹窗里的全部模型列表（「其他」拆开逐个列）；深浅色各一张。弹窗本身离屏画不出来，单独画它的内容
    static func renderTrendAllModels(model: UsageModel, dir: URL, originalTheme: UsageModel.ThemeMode) {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let tz = TimeZone(secondsFromGMT: 28800)!
        let codex = quotaMainState(now: now)
        var claude = quotaMainState(now: now)
        claude.id = .claudePlan; claude.snapshot?.provider = .claudePlan; claude.snapshot?.quota?.plan = "max"
        let local: [ProviderID: DailyModelTokens] = [
            .claudePlan: ["2026-10-13": ["claude-opus-5-5": 60_000_000, "claude-sonnet-5-5": 9_000_000],
                          "2026-10-14": ["claude-opus-5-5": 120_000_000, "claude-sonnet-5-5": 4_000_000],
                          "2026-10-15": ["claude-opus-5-5": 489_000_000, "claude-sonnet-5-5": 17_310_000, "claude-haiku-5-5": 300_000]],
            .codexPlan: ["2026-10-14": ["gpt-6-astra": 2_000_000],
                         "2026-10-15": ["gpt-6-astra": 4_210_000, "gpt-6-mini": 150_000]],
        ]
        let data = previewData(main: claude, others: [codex], now: now, timeZone: tz, localUsage: local)
        let keepData = model.data, keepState = model.mainState, keepSide = model.menuBarSide, keepPick = model.trendPick
        let keepLayout = model.todayLayout, keepHome = model.panelHome, keepTasks = model.runningTasks
        let keepNow = model.fixedNow
        model.fixedNow = now
        model.menuBarSide = nil
        model.trendPick = nil
        model.panelHome = "today"
        model.runningTasks = []
        for dark in [false, true] {
            model.themeMode = dark ? .dark : .light
            let tag = dark ? "dark" : "light"
            let p = Palette.of(dark)
            let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)
            model.data = data; model.mainState = claude
            model.todayLayout = [.init(id: "claudePlan", size: .small), .init(id: "codexPlan", size: .small),
                                 .init(id: "trend", size: .medium), .init(id: "spend", size: .small), .init(id: "running", size: .small)]
            renderFit(PanelView(model: model, p: p), name: "panel-today-allmodels-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            let chart = data.tokenChart(main: .claudePlan)
            renderFit(TrendAllModelsList(chart: chart, bar: chart.bars.count - 1, p: p).padding(12),
                      name: "trend-allmodels-\(tag)", width: 300, bg: p.bgTop, dir: dir)
        }
        model.fixedNow = keepNow
        model.data = keepData; model.mainState = keepState; model.menuBarSide = keepSide; model.trendPick = keepPick
        model.todayLayout = keepLayout; model.panelHome = keepHome; model.runningTasks = keepTasks
        model.themeMode = originalTheme
    }
}
