import Foundation

/// 主面板的间距与入口文字（界面代码用；放在 Core 里便于测试）
enum PanelLayout {
    /// 面板各分区之间的间距（面板 VStack 的 spacing）
    static let sectionGap: CGFloat = 16
    /// 「其他平台」下面的入口：选平台页可以勾选新平台，也可以取消勾选移除
    static var addRemoveTitle: String { L("panel.addRemove") }

    /// 「今天合计」一行：上分隔线和文字之间、图例和上分隔线之间都留 sectionGap，
    /// 与文字到下分隔线（面板间距）一致。stripSpacing 是包住图例两部分（模型行、今天合计）的 VStack 的间距
    static func todaySummaryGaps(stripSpacing: CGFloat) -> (lineAbove: CGFloat, lineToText: CGFloat) {
        (max(sectionGap - stripSpacing, 0), sectionGap)
    }
}

/// 自绘滑块：鼠标横坐标 → 0…1（滑块中心对准鼠标，两端夹住）
enum SliderMath {
    static func value(x: CGFloat, width: CGFloat, knob: CGFloat) -> Double {
        Double(max(0, min(1, (x - knob / 2) / max(1, width - knob))))
    }
}
