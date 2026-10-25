import SwiftUI

extension RenderMode {
    /// 「近 7 天 token」点了昨天（用户 10-19）：图例换成那天各模型的用量和花费，合计写「10-14 合计」，其余柱子变淡；
    /// 按量付费主平台右上角多「明细 ›」。数据同 renderTokenChart
    static func renderTrendPick(model: UsageModel, dir: URL, originalTheme: UsageModel.ThemeMode) {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let tz = TimeZone(secondsFromGMT: 28800)!
        func m(_ v: String) -> Money { Money(amount: Decimal(string: v)!, currency: .cny) }
        let qwen = ModelUsage(model: "Qwen/Qwen3-Coder-480B", cacheHit: 0, cacheMiss: 9_000_000, output: 200_000, requests: 40, cost: m("1.20"))
        var sfSnap = ProviderSnapshot(provider: .siliconflow, balance: m("12.00"), today: m("1.20"), month: m("8.00"),
                                      byModel: [qwen], trend7: [], source: .bill, fetchedAt: now, credential: .ok)
        sfSnap.trend7 = ["2026-10-12", "2026-10-13", "2026-10-15"].map { DayUsage(day: $0, tokens: 9_200_000, cost: m("1.20"), models: [qwen]) }
        let sf = PlatformState(id: .siliconflow, snapshot: sfSnap, burn: nil, status: .ok, lastSampleAt: now, lastSample: nil)
        let codex = quotaMainState(now: now)
        var claude = quotaMainState(now: now)
        claude.id = .claudePlan; claude.snapshot?.provider = .claudePlan; claude.snapshot?.quota?.plan = nil
        let local: [ProviderID: DailyModelTokens] = [
            .claudePlan: ["2026-10-11": ["claude-opus-5-5": 41_000_000], "2026-10-13": ["claude-opus-5-5": 88_000_000, "claude-haiku-5": 3_000_000],
                          "2026-10-14": ["claude-opus-5-5": 120_000_000], "2026-10-15": ["claude-opus-5-5": 52_340_000, "claude-haiku-5": 1_200_000]],
            .codexPlan: ["2026-10-10": ["gpt-5": 18_000_000], "2026-10-14": ["gpt-5": 26_000_000], "2026-10-15": ["gpt-5": 7_600_000]],
        ]
        let multi = previewData(main: deepseekMainState(now: now), others: [sf, codex, claude], now: now, timeZone: tz, localUsage: local)
        let claudeMain = previewData(main: claude, others: [deepseekMainState(now: now), codex], now: now, timeZone: tz, localUsage: local)
        let single = sampleData()
        let keepData = model.data, keepState = model.mainState, keepSide = model.menuBarSide, keepPick = model.trendPick
        model.fixedNow = now
        model.menuBarSide = nil
        for dark in [false, true] {
            model.themeMode = dark ? .dark : .light
            let tag = dark ? "dark" : "light"
            let p = Palette.of(dark)
            let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)
            model.trendPick = "2026-10-14"
            model.data = multi; model.mainState = deepseekMainState(now: now)
            renderFit(PanelView(model: model, p: p), name: "panel-trend-pick-multi-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            model.data = claudeMain; model.mainState = claude
            renderFit(PanelView(model: model, p: p), name: "panel-trend-pick-claude-main-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            let yesterday = single.trend7.dropLast().last?.iso
            renderFit(TrendStrip(chart: single.tokenChart(main: .deepseek), days: single.trend7, onPick: { _ in }, p: p,
                                 picked: yesterday, onSelect: { _ in }).padding(20),
                      name: "trend-pick-single-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
        }
        model.fixedNow = nil
        model.data = keepData; model.mainState = keepState; model.menuBarSide = keepSide; model.trendPick = keepPick
        model.themeMode = originalTheme
    }
}
