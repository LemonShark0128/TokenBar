import Foundation

/// 面板、小组件、右键卡的读屏文案（第 17 条）
@MainActor
func registerA11yPanelTextTests() {
    test("a11yCountSaysWanAndYi") {
        try checkEqual(A11yText.count(0), "0")
        try checkEqual(A11yText.count(9_999), "9999")
        try checkEqual(A11yText.count(10_000), "1 万")
        try checkEqual(A11yText.count(123_456), "12.3 万")
        try checkEqual(A11yText.count(120_000), "12 万")
        try checkEqual(A11yText.count(99_960_000), "9996 万")
        try checkEqual(A11yText.count(123_456_789), "1.23 亿")
        try checkEqual(A11yText.count(200_000_000), "2 亿")
    }
    test("a11yMoneyAndPercent") {
        try checkEqual(A11yText.money(12.346, currency: nil), "12.35 元")
        try checkEqual(A11yText.money(1.2, currency: "USD"), "1.20 美元")
        try checkEqual(A11yText.money(nil, currency: nil), "未知")
        try checkEqual(A11yText.money(.nan, currency: "CNY"), "未知")
        // 剩余一律向下取整：59.9% 读 59%，不能读成 60%
        try checkEqual(A11yText.remaining(59.9), "剩余 59%")
        try checkEqual(A11yText.remaining(0.4), "额度已用完")
        try checkEqual(A11yText.remaining(nil), "剩余未知")
        try checkEqual(A11yText.remaining(120), "剩余 100%")
    }
    test("a11ySpeakRewritesSymbols") {
        try checkEqual(A11yText.speak("¥12.34"), "12.34 元")
        try checkEqual(A11yText.speak("$1.20"), "1.20 美元")
        try checkEqual(A11yText.speak("今日合计 ≈¥3.00"), "今日合计 约 3.00 元")
        try checkEqual(A11yText.speak("¥ —"), "未知")
        try checkEqual(A11yText.speak("—"), "暂无数据")
        try checkEqual(A11yText.speak("Flash 12万 · ¥1.00 · 3 次"), "Flash 12 万，1.00 元，3 次")
        try checkEqual(A11yText.speak("1.23亿"), "1.23 亿")
    }
    test("a11yStatsCombineIntoOneSentence") {
        try checkEqual(A11yText.stats([("今日", "¥6.27"), ("本月", "¥88.00"), ("缓存命中", "87.5%")]),
                       "今日 6.27 元，本月 88.00 元，缓存命中 87.5%")
        try checkEqual(A11yText.stats([("今日", "—"), ("缓存命中", "—")]), "今日 暂无数据，缓存命中 暂无数据")
    }
    test("a11yTrendBarSaysDateAndTokens") {
        try checkEqual(A11yText.spokenDate(iso: "2026-10-18"), "10 月 18 日")
        try checkEqual(A11yText.spokenDate(iso: "坏日期"), "坏日期")
        try checkEqual(A11yText.trendBar(iso: "2026-10-18", total: 123_456, parts: [], isToday: false),
                       "10 月 18 日，12.3 万 token")
        try checkEqual(A11yText.trendBar(iso: "2026-10-19", total: 0, parts: [], isToday: true),
                       "今天，10 月 19 日，没有用量")
        try checkEqual(A11yText.trendBar(iso: "2026-10-18", total: 130_000,
                                         parts: [("Claude · opus", 100_000), ("硅基 · Qwen", 30_000), ("空", 0)], isToday: false),
                       "10 月 18 日，13 万 token：Claude opus 10 万，硅基 Qwen 3 万")
        try checkEqual(A11yText.trendBarHint(opensDetail: true), "打开那天的明细")
        try checkEqual(A11yText.trendBarHint(opensDetail: false), "在下面列出那天各模型的用量")
    }
    test("a11yTrendChartEmpty") {
        try checkEqual(A11yText.trendChart(summary: "近 7 天 token 柱状图。今天合计 12万", allZero: false),
                       "近 7 天 token 柱状图。今天合计 12 万")
        try checkEqual(A11yText.trendChart(summary: "近 7 天 token 柱状图。今天还没有用量", allZero: true),
                       "近 7 天 token 柱状图，暂无数据")
    }
    test("a11yQuotaWindowRow") {
        let r = AppData.QuotaRow(id: "s", name: "当前会话", usedPercent: 41.6, isReset: false, reset: "2 小时 13 分后重置")
        // 与界面一致写已用（已用 = 100 - 向下取整的剩余），再补一句剩余
        try checkEqual(A11yText.quotaWindow(r), "当前会话，已用 42%，剩余 58%，2 小时 13 分后重置")
        let done = AppData.QuotaRow(id: "w", name: "本周", usedPercent: 99.8, isReset: false, reset: "10/16 08:00 重置")
        try checkEqual(A11yText.quotaWindow(done), "本周，额度已用完，10/16 08:00 重置")
        let reset = AppData.QuotaRow(id: "s", name: "当前会话", usedPercent: 0, isReset: true, reset: nil)
        try checkEqual(A11yText.quotaWindow(reset), "当前会话，已重置")
    }
    test("a11ySideRow") {
        var sf = AppData.Side(id: "siliconflow", name: "硅基流动", tank: 12, currency: "CNY", todayCost: 1.5, status: "正常")
        try checkEqual(A11yText.side(sf), "硅基流动，今日 1.50 元，余额 12.00 元")
        sf.status = "连不上"
        try checkEqual(A11yText.side(sf), "硅基流动，连不上，余额 12.00 元")
        sf.riskText = "约 5 小时后用完"
        try checkEqual(A11yText.side(sf), "硅基流动，约 5 小时后用完，余额 12.00 元")
        var codex = AppData.Side(id: "codexPlan", name: "Codex 套餐", tank: nil, currency: "PCT", todayCost: nil, status: "正常",
                                 quotaRemaining: 59.9, quotaReset: "2:13 后重置")
        try checkEqual(A11yText.side(codex), "Codex 套餐，2:13 后重置，已用 41%")
        codex.quotaExhausted = QuotaExhausted(clock: "10:13")
        codex.riskText = "低于预警线"
        try checkEqual(A11yText.side(codex), "Codex 套餐，额度已用完，下次重置 10:13")
        codex.quotaExhausted = nil; codex.riskText = nil; codex.quotaRemaining = nil
        try checkEqual(A11yText.side(codex), "Codex 套餐，2:13 后重置，暂无数据")
        codex.quotaStale = true; codex.quotaRemaining = 80
        try checkEqual(A11yText.side(codex), "Codex 套餐，2:13 后重置，已用 20%，数据不是最新")
    }
    test("a11yGaugeValueAddsRunwayChip") {
        try checkEqual(A11yText.gaugeValue(base: "DeepSeek 余额 55.95 元", chipTitle: "约 5 小时后用完", chipDetail: "按最近 1 小时 ¥4.80/时"),
                       "DeepSeek 余额 55.95 元，约 5 小时后用完，按最近 1 小时 4.80 元/时")
        // 已经说过的不重复
        try checkEqual(A11yText.gaugeValue(base: "Codex 已用 41%，约 2 小时后用完", chipTitle: "约 2 小时后用完", chipDetail: nil),
                       "Codex 已用 41%，约 2 小时后用完")
        try checkEqual(A11yText.gaugeValue(base: "DeepSeek 余额 55.95 元", chipTitle: nil, chipDetail: nil), "DeepSeek 余额 55.95 元")
    }
    test("a11yOfflineAndNoRecord") {
        try checkEqual(A11yText.offline(provider: "DeepSeek"), "现在连不上 DeepSeek，显示的是最后一次记录的余额")
        try checkEqual(A11yText.quotaNoData(provider: "Claude 套餐", note: nil), "Claude 套餐，暂无数据")
        try checkEqual(A11yText.quotaNoData(provider: "Claude 套餐", note: "读不到本机记录，打开 Claude 桌面 App 后重试"),
                       "Claude 套餐，暂无数据。读不到本机记录，打开 Claude 桌面 App 后重试")
    }
    test("a11yTodayTokensAndDetailButton") {
        try checkEqual(A11yText.todayTokens(123_456), "今日 12.3 万 token")
        try checkEqual(A11yText.todayTokens(0), "今日 0 token")
        try checkEqual(A11yText.selectedDay(iso: "2026-10-18", total: 50_000, isToday: false), "选中 10 月 18 日，5 万 token")
        try checkEqual(A11yText.selectedDay(iso: "2026-10-19", total: 0, isToday: true), "今天，没有用量")
        try checkEqual(A11yText.openDayDetail(iso: "2026-10-18"), "打开 10 月 18 日的明细")
    }
    test("a11yMenuBarValueFollowsWhatIsShown") {
        // 菜单栏按钮的 label 固定是「Token Bar」，value 是菜单栏现在显示内容的完整说法
        try checkEqual(A11yText.menuBarLabel, "Token Bar")
        let q = AppData.MenuQuota(usedPercent: 60, window: "5 小时窗口", reset: "2 小时后重置")
        try checkEqual(A11yText.menuBarQuotaValue(provider: "Claude 套餐", reading: q, low: false, dim: false),
                       "Claude 套餐 5 小时窗口已用 60%，剩余 40%，2 小时后重置")
        var done = q; done.exhausted = QuotaExhausted(clock: "10:13")
        try checkEqual(A11yText.menuBarQuotaValue(provider: "Claude 套餐", reading: done, low: true, dim: false),
                       "Claude 套餐 额度已用完，下次重置 10:13，低于预警线")
        try checkEqual(A11yText.menuBarQuotaValue(provider: "Codex 套餐", reading: nil, low: false, dim: true),
                       "Codex 套餐 额度未知，数据不是最新")
        try checkEqual(A11yText.menuBarValue(provider: "DeepSeek", needsSetup: false, balanceCny: 123.45, runwayDays: nil,
                                             todayCny: nil, showsTodayCost: false, low: false, spike: false, dim: false),
                       "DeepSeek 余额 123.45 元")
        try checkEqual(A11yText.menuBarValue(provider: "DeepSeek", needsSetup: true, balanceCny: nil, runwayDays: nil,
                                             todayCny: nil, showsTodayCost: false, low: false, spike: false, dim: false),
                       "还没有添加平台")
    }
}
