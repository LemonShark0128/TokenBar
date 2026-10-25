import Foundation

/// 油表指针不能压到中间的余额数字：指针内端在任何角度都落在数字外框（最宽时）以外
@MainActor
func registerGaugeGeometryTests() {
    test("quotaArcUsesConsumptionAndRetainsRemainingSeverity") {
        for (remaining, used, severity): (Double, Double, RunwaySeverity) in [(1, 0, .ok), (0.52, 0.48, .ok), (0.2, 0.8, .warn), (0.05, 0.95, .danger), (0, 1, .danger)] {
            try check(abs(GaugeGeometry.arcFraction(level: remaining, quota: true) - used) < 0.000001)
            try checkEqual(GaugeGeometry.arcFraction(level: remaining, quota: false), remaining)
            try checkEqual(QuotaLevel.severity(remainingFraction: remaining), severity)
        }
    }
    test("gaugeNeedleClearsBalanceText") {
        // 面板 230/38、小组件和多平台面板的较小尺寸
        for (d, big) in [(230.0, 38.0), (172.0, 27.0), (200.0, 33.0), (160.0, 26.4)] {
            let g = GaugeGeometry(diameter: d, big: big)
            let halfW = g.textMaxWidth / 2, halfH = g.textHalfHeight
            // 指针从左下 150° 经顶部转到右下 30°（共 240°）
            for step in 0...48 {
                let a = (150.0 + 5.0 * Double(step)) * .pi / 180
                // 屏幕坐标 y 向下为正：数字框中心在圆心下方 textOffsetY
                let x = cos(a) * g.needleInner, y = sin(a) * g.needleInner
                try check(abs(x) > halfW + 2 || abs(y - g.textOffsetY) > halfH + 2,
                          "d=\(d) 角度 \(150 + 5 * step)°：指针内端 (\(x), \(y)) 落进数字外框")
            }
            // 用户 10-19：指针横着（已用 85–90%）时紧贴「已用 88%」像一个「—」：水平方向至少隔 0.4 倍字号
            try check(g.needleInner - halfW >= big * 0.4 - 0.001, "d=\(d)：指针横着时离数字只有 \(g.needleInner - halfW)pt")
            // 数字整体在圆心下方：横着的指针（y = 0）高于数字顶边，不会和数字连成一行
            try check(g.textOffsetY - halfH >= big * 0.1 - 0.001, "d=\(d)：数字顶边离水平线只有 \(g.textOffsetY - halfH)pt")
            try check(g.needleOuter < d / 2 - d * 0.052 / 2, "指针不能伸进色弧")
            try check(g.needleOuter - g.needleInner >= d * 0.1, "指针不能短得看不见")
        }
    }
}
