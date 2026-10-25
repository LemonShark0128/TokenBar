import AppKit
import Combine
import SwiftUI
import UserNotifications

// ---------------------------------------------------------------- 主题

/// 原生 macOS 风：底是系统毛玻璃，区块只用一层半透明填充、不加描边；
/// card/cardAlt/border 都是半透明色，叠在毛玻璃上才自然。bgTop/bgBottom 只在 --render 兜底时用。
struct Palette {
    var dark: Bool
    var bgTop: Color, bgBottom: Color, card: Color, cardAlt: Color
    var border: Color, text: Color, sub: Color
    /// 分段控件选中块
    var segOn: Color
    /// 油量弧/刻度的底轨、设置分组底色
    var track: Color, group: Color

    static func of(_ dark: Bool) -> Palette {
        dark
            ? Palette(dark: true,
                      bgTop: Color(red: 0.13, green: 0.13, blue: 0.14),
                      bgBottom: Color(red: 0.11, green: 0.11, blue: 0.12),
                      card: Color.white.opacity(0.06),
                      cardAlt: Color.white.opacity(0.05),
                      border: Color.white.opacity(0.09),
                      text: Color.white.opacity(0.92),
                      sub: Color.white.opacity(0.60),
                      segOn: Color.white.opacity(0.16),
                      track: Color.white.opacity(0.14), group: Color.white.opacity(0.06))
            : Palette(dark: false,
                      bgTop: Color(red: 0.95, green: 0.95, blue: 0.96),
                      bgBottom: Color(red: 0.93, green: 0.93, blue: 0.95),
                      card: Color.black.opacity(0.04),
                      cardAlt: Color.black.opacity(0.045),
                      border: Color.black.opacity(0.09),
                      text: Color.black.opacity(0.88),
                      sub: Color.black.opacity(0.62),      // 浅色模式次要文字对比度 ≥ 4.5:1（卡片底上也够）
                      segOn: Color.white,
                      track: Color.black.opacity(0.10), group: Color.white.opacity(0.55))
    }
}

extension Palette {
    /// 橙 / 红色**文字**：浅色模式下系统橙、系统红对比度不到 4.5:1，换深一档；深色模式照用系统色（图标、色点不受影响）
    var warnText: Color { dark ? Accent.orange : Color(red: 0.64, green: 0.32, blue: 0) }
    var dangerText: Color { dark ? Accent.red : Color(red: 0.78, green: 0.13, blue: 0.10) }
    var okText: Color { dark ? Accent.green : Color(red: 0.10, green: 0.47, blue: 0.20) }
}

/// 只有一个强调色（系统蓝）；绿/橙只表示状态（可用·账单 / 预警·估算），不再给数字上色
enum Accent {
    static let blue = Color(nsColor: .systemBlue)
    static let orange = Color(nsColor: .systemOrange)
    static let green = Color(nsColor: .systemGreen)
    static let red = Color(nsColor: .systemRed)
}

extension Font {
    /// 数字一律等宽，刷新时不左右跳
    static func num(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

/// 系统毛玻璃；外观锁定到 App 自己的主题（不跟系统，否则白主题+深色系统会变暗底深字）
struct VisualEffect: NSViewRepresentable {
    let dark: Bool
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}

/// 背景透明度（设置里的滑块），所有窗口共用、拖动即时生效
@MainActor
final class Glass: ObservableObject {
    static let shared = Glass()
    /// 0 = 不透明，1 = 最透
    @Published var transparency: Double {
        didSet { UserDefaults.standard.set(transparency, forKey: "glassTransparency") }
    }
    private init() {
        transparency = (UserDefaults.standard.object(forKey: "glassTransparency") as? Double) ?? 0.55
    }
}

/// 面板/窗口背景 = 系统模糊层 + 一层纯色底，两层的浓淡都由「透明度」决定。
/// 只靠系统材质时，普通壁纸上看起来就是一块灰（用户实测「看不出毛玻璃」），
/// 所以透明度高时把纯色底撤掉、模糊层也淡下去，让桌面真的透出来。
/// 模糊层留 0.45 的下限：整块全透明的像素会让点击穿透到后面的窗口（关闭键点不动那次就是这个原因）。
struct Backdrop: View {
    let p: Palette
    var material: NSVisualEffectView.Material? = nil
    @ObservedObject private var glass = Glass.shared
    var body: some View {
        let t = max(0, min(1, glass.transparency))
        Group {
            if kRendering {
                LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)
            } else {
                ZStack {
                    VisualEffect(dark: p.dark, material: material ?? (p.dark ? .hudWindow : .popover))
                        .opacity(1 - max(0, t - 0.5) * 1.1)
                    p.bgTop.opacity((1 - t) * 0.96)
                }
            }
        }
        // .background(View) 默认不进安全区：不加这句，透明标题栏那一条什么都没画 → 全透明 → 点击直接穿透到后面的窗口
        .ignoresSafeArea()
    }
}

/// 区块小标题
struct SectionTitle: View {
    let text: String
    let p: Palette
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundColor(p.sub)
    }
}

/// 细分隔线（横/竖）
struct Hairline: View {
    let p: Palette
    var vertical = false
    var body: some View {
        Rectangle().fill(p.border)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// 窗口/面板按内容定高：量出给定宽度下的自然高度，超过屏幕可用高度才滚动
enum Fit {
    static var maxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 40 }

    /// 只做排版不画图：以前用 ImageRenderer 把整个面板画成一张图来量，面板开着时每次刷新都画一遍，费内存和 CPU。
    /// 2026-10-19 实测面板 5 种、设置 4 页、小组件、引导页，sizeThatFits 与 ImageRenderer 量出的高度逐个相同
    /// （NSHostingView.fittingSize 在带标题栏的窗口里会多报约 32pt，不用它）
    @MainActor
    static func height<V: View>(_ v: V, width: CGFloat) -> CGFloat {
        let hc = NSHostingController(rootView: v.frame(width: width).fixedSize(horizontal: false, vertical: true))
        let h = hc.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return h.isFinite && h > 0 ? ceil(h) : 600
    }
}

/// 类似系统分段控件的模型切换
struct SegmentPicker: View {
    let items: [(key: String, label: String)]
    let selected: String?
    let p: Palette
    let onPick: (String) -> Void

    // 标签一律单行：放得下就并排，放不下就横向滚动（不折行挤成好几行）
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
    }

    private var row: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.key) { it in
                let on = it.key == selected
                Button { onPick(it.key) } label: {
                    Text(it.label)
                        .lineLimit(1).fixedSize()
                        .font(.system(size: 10.5, weight: on ? .semibold : .regular))
                        .foregroundColor(on ? p.text : p.sub)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(on ? p.segOn : Color.clear)
                            .shadow(color: .black.opacity(on && !p.dark ? 0.12 : 0), radius: 1, y: 0.5))
                }.buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.cardAlt))
    }
}

/// 2×2 数值格，中间用细线分隔，不再套小卡片
struct StatGrid: View {
    let items: [(label: String, value: String)]
    let p: Palette

    private func cell(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(items[i].label).font(.system(size: 10.5)).foregroundColor(p.sub)
            Text(items[i].value).font(.num(15)).foregroundColor(p.text)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) { cell(0); Hairline(p: p, vertical: true).frame(height: 30); cell(1) }
            Hairline(p: p)
            HStack(spacing: 12) { cell(2); Hairline(p: p, vertical: true).frame(height: 30); cell(3) }
        }
    }
}
