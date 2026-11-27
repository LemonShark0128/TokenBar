import AppKit
import SwiftUI

struct RunningDot: View {
    let activity: RunningActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = false

    var body: some View {
        Circle().fill(Accent.green).frame(width: 6, height: 6)
            .overlay {
                if onScreen && !reduceMotion && !kRendering {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        let diameter = 6 + 7 * phase
                        Circle().strokeBorder(Accent.green.opacity(0.36 * (1 - phase)), lineWidth: 1)
                            .frame(width: diameter, height: diameter)
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .background {
                if !reduceMotion && !kRendering {
                    DotVisibility(onChange: { onScreen = $0 }).allowsHitTesting(false)
                        .onDisappear { onScreen = false }
                }
            }
            .help(activity.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("today.runningLabel"))
    }
}

/// 弹窗会复用宿主视图，关闭时 SwiftUI 的 onDisappear 不一定触发。
private struct DotVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView { VisibilityView() }
    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
        view.checkVisibility()
    }

    final class VisibilityView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var wasVisible = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            if let window {
                center.addObserver(self, selector: #selector(visibilityChanged(_:)),
                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
                if let clip = enclosingScrollView?.contentView {
                    clip.postsBoundsChangedNotifications = true
                    center.addObserver(self, selector: #selector(visibilityChanged(_:)),
                                       name: NSView.boundsDidChangeNotification, object: clip)
                }
            }
            checkVisibility()
        }

        override func layout() {
            super.layout()
            checkVisibility()
        }

        @objc private func visibilityChanged(_ note: Notification) { checkVisibility() }

        func checkVisibility() {
            let visible = window?.isVisible == true && window?.occlusionState.contains(.visible) == true && !visibleRect.isEmpty
            guard visible != wasVisible else { return }
            wasVisible = visible
            // AppKit 可能正在布局，等它结束再更新 SwiftUI 的状态。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wasVisible == visible else { return }
                self.onChange(visible)
            }
        }
    }
}

struct AlertLine<Content: View>: View {
    let glyph: AlertGlyph
    var iconSize: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        if glyph == .none {
            content()
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: glyph == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: iconSize)).fixedSize().accessibilityHidden(true)
                content()
            }
        }
    }
}

extension View {
    @ViewBuilder func helpIfPresent(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}
