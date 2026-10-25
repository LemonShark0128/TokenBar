import AppKit
import Combine
import SwiftUI
import UserNotifications

// ---------------------------------------------------------------- 状态：主题（白 / 黑 / 跟随系统）。themeMode、systemIsDark 是存储属性，留在 Model.swift

extension UsageModel {
    /// 主题：白 / 黑 / 跟随系统
    enum ThemeMode: String { case light, dark, system }
}

extension UsageModel {
    /// 界面实际用的深浅 —— 视图里到处在用 model.dark，这里统一换算
    var dark: Bool {
        switch themeMode {
        case .light: return false
        case .dark: return true
        case .system: return systemIsDark
        }
    }

    var themeLabel: String {
        switch themeMode { case .light: return "白"; case .dark: return "黑"; case .system: return "跟随系统" }
    }
    var themeIcon: String {
        switch themeMode {
        case .light: return "sun.max"
        case .dark: return "moon"
        case .system: return "circle.lefthalf.filled"
        }
    }
    func cycleTheme() {
        switch themeMode {
        case .light: themeMode = .dark
        case .dark: themeMode = .system
        case .system: themeMode = .light
        }
        logLine("主题切换为：\(themeLabel)")
    }

    /// 让「白/黑」作用于整个 App（弹层背景材质、滚动条等系统绘制部分也一起变）
    func applyAppAppearance() {
        // ⚠️ 离屏自检（--render）里没有 NSApplication 实例，NSApp 是 nil（它是隐式解包可选）；
        // 直接写 NSApp.appearance 会以「Unexpectedly found nil」崩掉 —— 实测 --render 退出码 133。
        guard let app = NSApp else { return }
        switch themeMode {
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        case .system: app.appearance = nil
        }
    }
}
