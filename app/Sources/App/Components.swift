import AppKit
import Combine
import SwiftUI
import UserNotifications

// ---------------------------------------------------------------- A：油量表（面板主角）

/// 油量弧：开口朝下 240°，与菜单栏 logo 同一几何（150° 起，顺时针扫到 30°）
struct GaugeArc: Shape {
    var fraction: Double
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: min(r.width, r.height) / 2,
                    startAngle: .degrees(150),
                    endAngle: .degrees(150 + 240 * max(0, min(1, fraction))), clockwise: false)
        return path
    }
}

func levelTint(_ v: Double) -> Color { Color(nsColor: GaugeIcon.levelColor(v)) }

/// 套餐统一使用已用比例阈值，沿用现有绿、橙、红色。
func quotaTint(_ severity: RunwaySeverity) -> Color {
    switch severity {
    case .ok: return levelTint(1)
    case .warn: return Color(nsColor: NSColor(red: 0.98, green: 0.62, blue: 0.22, alpha: 1))
    case .danger: return Color(nsColor: NSColor(red: 0.92, green: 0.26, blue: 0.21, alpha: 1))
    }
}

/// 主角油量表：弧 = 余额 ÷ 满盘；指针只画在外圈，不压住中间的余额数字
/// 主平台切换时名称 / 数字 / 油量表的配对动画：主区与辅助行共用 namespace，
/// 同一平台的同名元素从一处飞到另一处。减弱动态效果时不配对（淡入淡出由面板整块重建负责）
struct SwitchMatch {
    let provider: ProviderID
    let ns: Namespace.ID
    let style: SwitchMotion.Style
}

extension View {
    /// part：name / value / gauge；match 为 nil 时原样返回（离屏预览、其它用到这些组件的地方）
    @ViewBuilder
    func switchGeometry(_ match: SwitchMatch?, _ part: String) -> some View {
        if let m = match, m.style == .matchedGeometry {
            self.matchedGeometryEffect(id: "\(m.provider.rawValue)-\(part)", in: m.ns)
        } else {
            self
        }
    }
}

struct FuelGauge: View {
    let level: Double
    let balance: String
    let caption: String
    var captionColor: Color? = nil
    var chip: AppData.RunwayChip? = nil
    var diameter: CGFloat = 230
    var big: CGFloat = 38
    let p: Palette
    /// VoiceOver 朗读，如「DeepSeek 余额 55.95 元，约可用 5 天」
    var a11yLabel: String? = nil
    var match: SwitchMatch? = nil
    var dimmed: Bool = false
    var quota: Bool = false
    /// 读数上面的一行小字（套餐用完时的「下次重置」）
    var overline: String? = nil

    var body: some View {
        let v = GaugeGeometry.arcFraction(level: level, quota: quota)
        let g = GaugeGeometry(diameter: Double(diameter), big: Double(big))
        let lw = CGFloat(g.lineWidth)
        let r = diameter / 2
        let needleLen = CGFloat(g.needleOuter - g.needleInner)
        VStack(spacing: 4) {
            ZStack {
                GaugeArc(fraction: 1).stroke(p.track, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                GaugeArc(fraction: v).stroke(dimmed ? p.sub.opacity(0.5) : (quota ? quotaTint(QuotaLevel.severity(remainingFraction: level)) : levelTint(v)), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                ForEach(0..<5, id: \.self) { i in
                    Capsule().fill(p.sub.opacity(0.55))
                        .frame(width: 1.5, height: diameter * 0.04)
                        .offset(y: -(r - lw * 1.7))
                        .rotationEffect(.degrees(150 + 240 * Double(i) / 4 + 90))
                }
                Capsule().fill(p.text)
                    .frame(width: 3, height: needleLen)
                    .offset(y: -CGFloat(g.needleOuter + g.needleInner) / 2)
                    .rotationEffect(.degrees(150 + 240 * v + 90))
                VStack(spacing: 2) {
                    if let overline {
                        Text(overline).font(.system(size: big * 0.4, weight: .medium)).foregroundColor(p.sub).lineLimit(1)
                    }
                    Text(balance)
                        .font(.num(big, .semibold)).foregroundColor(dimmed ? p.sub : p.text)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .frame(width: CGFloat(g.textMaxWidth))
                        .switchGeometry(match, "value")
                }
                .offset(y: CGFloat(g.textOffsetY))
                if chip == nil {
                    Text(caption)
                        .font(.system(size: diameter > 200 ? 12 : 11))
                        .foregroundColor(captionColor ?? p.sub)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: diameter * 0.9)
                        .offset(y: r * 0.62)
                }
            }
            .frame(width: diameter, height: diameter)
            .frame(height: diameter * 0.86, alignment: .top)
            .switchGeometry(match, "gauge")
            if let chip { RunwayChipView(chip: chip, p: p) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(quota ? L("gauge.quota") : L("gauge.balance"))
        .accessibilityValue(A11yText.gaugeValue(base: a11yLabel ?? A11yText.speak(L("gauge.a11yBase", balance, caption)),
                                                chipTitle: chip?.title, chipDetail: chip?.detail))
    }
}

/// 标题栏那颗数据健康点：绿=正常；橙=退回估算或超过 10 分钟没更新；红=连不上平台或需要重新登录
struct FreshDot: View {
    @ObservedObject var model: UsageModel
    let p: Palette
    /// 给了标题（小组件多平台时的平台名）就写标题，新鲜度放进悬停提示和读屏
    var title: String? = nil
    var body: some View {
        let (state, text) = model.freshness
        // 套餐平台用短写（「12 分钟前」）；还没有额度数据时灰点「暂无数据」，不重复正文的说明
        let quota = model.quotaFreshShort
        let c: Color = quota?.hasData == false ? p.sub
            : (state == .ok ? Accent.green : (state == .offline ? Accent.red : Accent.orange))
        let fresh = quota?.text ?? text
        if !model.needsSetup {
            if let title {
                HStack(spacing: 5) {
                    Circle().fill(c).frame(width: 6, height: 6)
                    Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(state == .ok ? p.text : c)
                        .lineLimit(1).fixedSize()
                    // 不正常时（离线、过时、要重新登录）不能只靠一个小色点：标题变色并加一个提示图标（形状也看得出），
                    // 具体说法在悬停提示和读屏里；270pt 宽放不下整句状态
                    if state != .ok && quota?.hasData != false {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundColor(c)
                    }
                }
                .help(fresh).accessibilityElement(children: .ignore).accessibilityLabel("\(title)，\(fresh)")
            } else {
                HStack(spacing: 4) {
                    Circle().fill(c).frame(width: 6, height: 6)
                    Text(fresh).font(.num(11, .regular)).foregroundColor(state == .ok ? p.sub : c)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("gauge.dataStatus"))
                .accessibilityValue(fresh)
            }
        }
    }
}

/// 油量表下面那句话：还能用几天 + 花得多快（1 小时窗口不可信时退回 24 小时平均）
/// compact：窄处（右键菜单信息卡）用短写法「¥0.00/时」「均 ¥1.37/时」
func burnCaption(_ d: AppData, fuelFull: Double, compact: Bool = false) -> (String, Bool) {
    var parts: [String] = []
    let b = d.burn
    let sym = currencySymbol(d.balance.currency)
    if let days = b?.runwayDays { parts.append(A11yText.runway(days)) }
    if let h = b?.cnyPerHourRate {
        parts.append(L(compact ? "burn.compactHour" : "burn.lastHour", sym, String(format: "%.2f", h)))
    } else if let h = b?.cnyPerDayRate {
        parts.append(L(compact ? "burn.compactAvg" : "burn.dayAvg", sym, String(format: "%.2f", h)))
    }
    return (parts.isEmpty ? L("burn.fullGauge", sym, String(format: "%.0f", fuelFull)) : parts.joined(separator: " · "), b?.spike == true)
}

/// 风险文字共用颜色；普通行的正常状态仍使用次要文字色。
/// p 不为 nil 时是文字颜色：浅色模式用深一档的橙 / 红（对比度）；菜单这类系统材质上不传 p
func riskTint(_ severity: Int?, ok: Color, p: Palette? = nil) -> Color {
    switch severity {
    case RunwaySeverity.danger.rawValue: return p?.dangerText ?? Accent.red
    case RunwaySeverity.warn.rawValue: return p?.warnText ?? Accent.orange
    default: return ok
    }
}

struct RunwayChipView: View {
    let chip: AppData.RunwayChip
    let p: Palette
    var body: some View {
        let color = chip.muted ? p.sub : riskTint(chip.severity, ok: p.okText, p: p)
        VStack(spacing: 4) {
            Text(chip.title).font(.system(size: 15, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundColor(color)
                .background(Capsule().fill(color.opacity(chip.muted ? 0.12 : (chip.severity == RunwaySeverity.ok.rawValue ? 0.14 : 0.16))))
            if let detail = chip.detail {
                Text(detail).font(.system(size: 11.5)).foregroundColor(p.sub)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11yText.speak([chip.title, chip.detail].compactMap { $0 }.joined(separator: "，")))
    }
}
