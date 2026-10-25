import AppKit
import Combine
import SwiftUI
import UserNotifications

// ---------------------------------------------------------------- 小组件窗口

@MainActor
final class WidgetController {
    static let shared = WidgetController()

    func toggle(_ model: UsageModel) {
        model.toggleWidget()
    }
}

// ---------------------------------------------------------------- 浮动窗口（面板/设置/详情/状态条）

/// 浮动窗内容宿主：订阅 model，切主题时用新调色板重画「内容 + 背景」。
/// 之前调色板只在开窗那一刻取一次 → 设置窗切主题没反应、小组件变成浅底白字（实测）。
/// 浮动窗内容高度：内容变高变矮时（如设置换页）由 Hud.refit 改它，不重建内容、不丢界面状态
@MainActor
final class HudHeight: ObservableObject {
    @Published var value: CGFloat
    init(_ v: CGFloat) { value = v }
}

struct ThemedHost: View {
    @ObservedObject var model: UsageModel
    let width: CGFloat
    @ObservedObject var height: HudHeight
    let build: (Palette) -> AnyView
    var body: some View {
        let p = Palette.of(model.dark)
        ScrollView { build(p) }       // 安全区已经让开了标题栏，不再额外加 top（原先是双倍留白）
            .scrollIndicators(.never)
            .frame(width: width, height: height.value)
            // 往下滚时内容不再钻到透明标题栏底下（之前会和关闭键的底衬叠在一起）
            .clipped()
            .background(Backdrop(p: p))
    }
}

@MainActor
final class Hud {
    static var windows: [String: NSWindow] = [:]
    /// 窗口被红色关闭键关掉时的回调（用来同步设置里的开关）
    static var onClose: [String: () -> Void] = [:]

    /// 按内容定高的窗口：量高度用的内容和当前高度（Hud.refit 用）
    private static var themes: [String: (model: UsageModel, build: (Palette) -> AnyView, width: CGFloat, height: HudHeight)] = [:]

    static func isOpen(_ key: String) -> Bool { windows[key]?.isVisible ?? false }

    /// 收起窗口，并在下一轮把内容放掉（见 discard）
    static func hide(_ key: String) {
        guard let w = windows[key] else { return }
        w.orderOut(nil)
        discardLater(key, w)
    }

    /// 收起 / 关掉之后再放掉：不在按钮回调里当场拆自己的界面；这一轮里又被打开了就不放
    private static func discardLater(_ key: String, _ w: NSWindow) {
        DispatchQueue.main.async {
            guard windows[key] === w, !w.isVisible, !w.isMiniaturized else { return }
            discard(key)
        }
    }

    /// 收起的窗口连内容一起放掉：只 orderOut 的话整棵界面一直留在内存里，网页登录窗的 WKWebView
    /// 还会让 WebKit 的网页进程和网络进程（各几十 MB）一直到 App 退出才走。下次打开时重新建窗口（位置照旧记得）
    static func discard(_ key: String) {
        guard let w = windows[key] else { return }
        windows[key] = nil
        themes[key] = nil
        onClose[key] = nil
        w.orderOut(nil)
        w.contentView = nil
    }

    /// 内容高度变了（设置换页、展开「高级」等）：重新量高度，窗口顶边不动、只改下沿
    static func refit(_ key: String) {
        guard !kRendering, let w = windows[key], w.isVisible, let t = themes[key] else { return }
        let top = max(0, w.frame.height - w.contentLayoutRect.height)
        let h = min(Fit.height(t.build(Palette.of(t.model.dark)), width: t.width), Fit.maxHeight - top)
        guard abs(h - t.height.value) > 0.5 else { return }
        let topY = w.frame.maxY
        t.height.value = h
        w.setContentSize(CGSize(width: t.width, height: h))
        w.setFrameOrigin(NSPoint(x: w.frame.minX, y: topY - w.frame.height))
    }

    @discardableResult
    static func toggle(key: String, title: String, size: CGSize, titled: Bool = true, minimizable: Bool = false, plain: Bool = false,
                       themed: (model: UsageModel, build: (Palette) -> AnyView)? = nil,
                       origin: @escaping (CGSize) -> NSPoint, content: AnyView = AnyView(EmptyView())) -> Bool {
        if let w = windows[key], w.isVisible {
            hide(key)
            return false
        }
        var size = size
        var root = content
        let w = windows[key] ?? make(key: key, title: title, size: size, titled: titled, minimizable: minimizable, plain: plain,
                                     origin: origin(size))
        // 缩小到程序坞的窗口 isVisible 为 false：再点一次是把它放回来
        if w.isMiniaturized { w.deminiaturize(nil) }
        // themed != nil：宽度用 size.width，高度按内容自适应（不再写死高度 → 不留大片空白、也不溢出），
        // 超过屏幕可用高度时才滚动；背景统一由这里铺毛玻璃。
        // 实测：NSHostingView 把根视图高度当作「标题栏以下」的高度，窗口会自己再加上标题栏（本机 32pt），
        // 所以这里只给内容高度；再加标题栏就会在底部多出一条空白。
        if let t = themed {
            let top = titled ? max(0, w.frame.height - w.contentLayoutRect.height) : 0
            let measured = Fit.height(t.build(Palette.of(t.model.dark)), width: size.width)
            size.height = min(measured, Fit.maxHeight - top)
            let box = HudHeight(size.height)
            themes[key] = (t.model, t.build, size.width, box)
            root = AnyView(ThemedHost(model: t.model, width: size.width, height: box, build: t.build))
        }
        w.title = title
        w.contentView = NSHostingView(rootView: root)
        w.setContentSize(size)
        if savedOrigin(key) == nil { w.setFrameOrigin(origin(size)) }   // 用户挪过就沿用他的位置
        // 沿用的旧位置可能已放不下（例如设置窗从 380 加宽到 600）：整窗收回到所在屏幕的可见范围里
        else if let vis = (w.screen ?? NSScreen.main)?.visibleFrame {
            var f = w.frame
            f.origin.x = min(max(f.origin.x, vis.minX), vis.maxX - f.width)
            f.origin.y = min(max(f.origin.y, vis.minY), vis.maxY - f.height)
            if f.origin != w.frame.origin { w.setFrameOrigin(f.origin) }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        return true
    }

    /// 记住每个浮动窗的位置（拖过一次以后就一直沿用）
    private static func savedOrigin(_ key: String) -> NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: "hudOrigin.\(key)") else { return nil }
        let parts = s.split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? NSPoint(x: parts[0], y: parts[1]) : nil
    }

    private static func rememberOrigin(_ key: String, _ w: NSWindow) {
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: w, queue: .main) { [weak w] _ in
            // 回调在主队列上，但闭包被声明成 @Sendable：用 Task { @MainActor } 让编译器检查
            Task { @MainActor in
                guard let win = w else { return }
                UserDefaults.standard.set("\(win.frame.origin.x),\(win.frame.origin.y)",
                                          forKey: "hudOrigin.\(key)")
            }
        }
    }

    private static func make(key: String, title: String, size: CGSize, titled: Bool, minimizable: Bool, plain: Bool = false,
                             origin: NSPoint) -> NSWindow {
        var mask: NSWindow.StyleMask = [.closable, .fullSizeContentView]
        if plain {
            mask = [.titled, .closable]
        } else {
            mask.insert(titled ? .titled : .borderless)
            if titled && minimizable { mask.insert(.miniaturizable) }
        }
        let start = savedOrigin(key) ?? origin
        let w = NSWindow(contentRect: NSRect(origin: start, size: size), styleMask: mask,
                         backing: .buffered, defer: false)
        rememberOrigin(key, w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: w, queue: .main) { _ in
            Task { @MainActor in
                // 晚一拍执行：这期间同一个 key 已经开了新窗口，就不能调新窗口的关闭回调
                if windows[key] === w { onClose[key]?() }
                discardLater(key, w)
            }
        }
        if titled || plain {
            w.title = title
            w.titlebarAppearsTransparent = !plain
            w.isMovableByWindowBackground = !plain
        }
        w.level = .floating
        // 窗口本身透明，背景完全交给 Backdrop（它连标题栏一起铺满、且始终留有不透明度下限），
        // 这样「透明度」滑块才能真的透到桌面；不透明窗里滑块只能透到窗口自己的灰底。
        w.isOpaque = plain
        w.backgroundColor = plain ? .windowBackgroundColor : .clear
        w.hasShadow = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        windows[key] = w
        return w
    }
}
