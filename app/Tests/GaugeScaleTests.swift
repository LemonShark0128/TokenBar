import Foundation

// 表盘满格金额按「刻度币种」算（2026-11-06 审查后续 2）：已添加的按量平台都是一种币就用它，混着就按 ¥；
// 不是刻度币种的余额先按汇率换算再比，$18 不能当 ¥18 画
@MainActor
func registerGaugeScaleTests() {
    test("gaugeScaleCurrencyFromAddedPayg") {
        try checkEqual(SettingsLayout.gaugeScaleCurrency(added: [.deepseek, .openrouter, .claudePlan]), nil)
        try checkEqual(SettingsLayout.gaugeScaleCurrency(added: [.openrouter, .codexPlan]), "USD")
        try checkEqual(SettingsLayout.gaugeScaleCurrency(added: [.deepseek, .kimi]), "CNY")
        try checkEqual(SettingsLayout.gaugeScaleCurrency(added: []), nil)
        // 平台实际余额的币种优先（DeepSeek 只有美元余额的账户：原来刻度按快照是 $，不能悄悄变成 ¥）
        try checkEqual(SettingsLayout.gaugeScaleCurrency(added: [.deepseek], actual: [.deepseek: "USD"]), "USD")
        try checkEqual(SettingsLayout.gaugeScaleCurrency(added: [.deepseek, .openrouter], actual: [.deepseek: "USD"]), "USD")
        // 隐藏的平台也算已添加：面板和小组件用同一个刻度
        try checkEqual(SettingsLayout.gaugeScaleCurrency(added: [.deepseek, .openrouter], actual: [.openrouter: "USD"]), nil)
    }
    test("gaugeFractionConvertsToScaleCurrency") {
        func f(_ v: Double, _ c: String?, _ scale: String?) -> Double {
            SettingsLayout.gaugeFraction(v, currency: c, full: 50, scale: scale, usdToCny: 7)
        }
        try checkEqual(f(27, "CNY", nil), 0.54)          // 原来的样子不变
        try checkEqual(f(27, "CNY", "CNY"), 0.54)
        try checkEqual(f(18, "USD", "USD"), 0.36)        // 只有美元平台：满格 $50
        try checkEqual(f(5, "USD", nil), 0.7)            // 混着：刻度 ¥50，$5 = ¥35
        try checkEqual(f(18, "USD", nil), 1)             // $18 = ¥126，超过满格
        try checkEqual(f(70, "CNY", "USD"), 0.2)         // ¥70 = $10
        try checkEqual(f(-3, "CNY", nil), 0)
    }
    test("alertBarFractionUsesScaleCurrency") {
        try checkEqual(SettingsLayout.alertBarFraction(.money(5, currency: "USD"), fuelFull: 50, scale: nil, usdToCny: 7), 0.7)
        try checkEqual(SettingsLayout.alertBarFraction(.money(25, currency: "CNY"), fuelFull: 50, scale: nil, usdToCny: 7), 0.5)
        try checkEqual(SettingsLayout.alertBarFraction(.session(40), fuelFull: 50, scale: nil, usdToCny: 7), 0.4)
    }
}
