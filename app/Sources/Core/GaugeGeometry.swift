import Foundation

/// 面板大油表的尺寸：指针只在外圈一段圆环里转，中间的余额数字限宽，两者永远不重叠
/// （原来指针内端离圆心只有 0.48r，余额在 85% 左右时指针会从数字中间穿过）
struct GaugeGeometry {
    /// 输入仍是剩余比例；套餐弧线和指针共用已用比例，颜色另按剩余计算。
    static func arcFraction(level: Double, quota: Bool) -> Double {
        let remaining = max(0, min(1, level))
        return quota ? 1 - remaining : remaining
    }

    let diameter: Double
    /// 余额数字的字号
    let big: Double

    var radius: Double { diameter / 2 }
    var lineWidth: Double { diameter * 0.052 }
    /// 余额数字最宽多少（更长的数字按 minimumScaleFactor 缩小）
    var textMaxWidth: Double { diameter * 0.52 }
    /// 数字字形的半高（不含行距）
    var textHalfHeight: Double { big * 0.4 }
    /// 数字中心在圆心下方多少：指针横着时在数字上方，不会和「已用 88%」连成「已用 88% —」（用户 10-19）
    var textOffsetY: Double { big * 0.5 }
    /// 指针外端到圆心的距离：停在色弧内侧
    var needleOuter: Double { radius - lineWidth * 1.4 }
    /// 指针内端到圆心的距离：数字外框的角再往外留 4pt，并且横着时离数字至少 0.4 倍字号
    /// （用户 10-19：已用 85–90% 时指针横在「已用 88%」右边，只隔几 pt，看着像个「—」）
    var needleInner: Double {
        let w = textMaxWidth / 2, h = textOffsetY + textHalfHeight   // 数字框离圆心最远的角
        return max((w * w + h * h).squareRoot() + 4, w + big * 0.4)
    }
}
