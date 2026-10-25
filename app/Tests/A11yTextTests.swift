import Foundation

@MainActor
func registerA11yTextTests() {
    test("a11yGaugeLabel") {
        try checkEqual(A11yText.gauge(provider: "DeepSeek", balanceCny: 55.95, runwayDays: 4.9),
                       "DeepSeek 余额 55.95 元，约可用 5 天")
        try checkEqual(A11yText.gauge(provider: "DeepSeek", balanceCny: 55.95, runwayDays: nil), "DeepSeek 余额 55.95 元")
        try checkEqual(A11yText.gauge(provider: "DeepSeek", balanceCny: nil, runwayDays: 3), "DeepSeek 余额未知")
    }
    test("a11yRunwayMatchesCaption") {
        try checkEqual(A11yText.runway(0.5), "约可用 12 小时")
        try checkEqual(A11yText.runway(4.9), "约可用 5 天")
        try checkEqual(A11yText.runway(120), "可用很久")
    }
    test("a11yMenuBarLabel") {
        try checkEqual(A11yText.menuBarValue(provider: "DeepSeek", needsSetup: true, balanceCny: nil, runwayDays: nil,
                                        todayCny: nil, showsTodayCost: false, low: false, spike: false, dim: true),
                       "还没有添加平台")
        try checkEqual(A11yText.menuBarValue(provider: "DeepSeek", needsSetup: false, balanceCny: nil, runwayDays: nil,
                                        todayCny: nil, showsTodayCost: false, low: false, spike: false, dim: true),
                       "正在连接 DeepSeek")
        try checkEqual(A11yText.menuBarValue(provider: "DeepSeek", needsSetup: false, balanceCny: 55.95, runwayDays: 4.9,
                                        todayCny: 6.27, showsTodayCost: false, low: false, spike: false, dim: false),
                       "DeepSeek 余额 55.95 元，约可用 5 天")
        try checkEqual(A11yText.menuBarValue(provider: "DeepSeek", needsSetup: false, balanceCny: 4, runwayDays: 0.5,
                                        todayCny: 6.27, showsTodayCost: true, low: true, spike: true, dim: true),
                       "DeepSeek 余额 4.00 元，约可用 12 小时，今日花费 6.27 元，低于预警线，用量异常增加，数据不是最新")
    }
    test("userVisibleNameIsTokenBarWithSpace") {
        // 用户第三批反馈：用户看得到的名字统一叫「Token Bar」
        try checkEqual(AppName.display, "Token Bar")
    }
}
