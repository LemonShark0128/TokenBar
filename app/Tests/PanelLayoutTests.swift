import Foundation

/// 第四批第 1 条：「今天合计」一行上下两条分隔线到文字的留白相同（都等于面板分区间距）；入口写「添加/移除平台」
@MainActor
func registerPanelLayoutTests() {
    test("panelTodaySummaryGapsSymmetric") {
        let g = PanelLayout.todaySummaryGaps(stripSpacing: 4)
        try checkEqual(g.lineAbove + 4, PanelLayout.sectionGap)      // 图例 → 上分隔线
        try checkEqual(g.lineToText, PanelLayout.sectionGap)         // 上分隔线 → 文字
        // 文字 → 下分隔线：由面板 VStack 的间距决定，也是 sectionGap
    }
    test("panelAddRemoveTitle") {
        try checkEqual(PanelLayout.addRemoveTitle, "添加/移除平台")
    }
}

/// 第五批第 4 条：自绘透明度滑块按鼠标位置换算数值（滑块中心对准鼠标，两端夹住）
@MainActor
func registerSliderMathTests() {
    test("sliderValueFromLocation") {
        try checkEqual(SliderMath.value(x: 8, width: 130, knob: 16), 0)
        try checkEqual(SliderMath.value(x: 122, width: 130, knob: 16), 1)
        try checkEqual(SliderMath.value(x: 65, width: 130, knob: 16), 0.5)
        try checkEqual(SliderMath.value(x: -40, width: 130, knob: 16), 0)
        try checkEqual(SliderMath.value(x: 400, width: 130, knob: 16), 1)
    }
}
