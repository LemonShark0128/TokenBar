import AppKit
import SwiftUI

// ---------------------------------------------------------------- 数据

/// 状态栏统一字体（测量与显示必须用同一个，否则等宽对齐会算错）
/// 菜单栏统一规格：字号跟系统菜单栏（本机 13pt，与时钟同号）、常规字重、等宽数字；图标 16pt（与 Wi‑Fi/电池同大）
@MainActor let kStatusFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
let kMenuIconPt: CGFloat = 16

/// 系统当前外观
enum StatusTheme {
    /// 系统是不是深色。
    /// 注意：不能用 NSApp.effectiveAppearance —— 我们自己改过 NSApp.appearance 之后，
    /// 它反映的是"我们的主题"，会把判断污染（实测导致白主题下菜单栏文字变黑、看不清）。
    /// 所以直接读系统外观偏好的全局键：深色时存在且为 "Dark"，浅色时通常不存在。
    static func systemIsDark() -> Bool {
        let raw = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
            ?? UserDefaults(suiteName: "NSGlobalDomain")?.string(forKey: "AppleInterfaceStyle")
        return (raw ?? "").lowercased().contains("dark")
    }
}

