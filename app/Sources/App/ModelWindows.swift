import AppKit
import Combine
import SwiftUI
import UserNotifications

// ---------------------------------------------------------------- 状态：浮动窗口（面板之外：设置 / 小组件 / 详情）

extension UsageModel {
    var screen: NSRect {
        NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1470, height: 900)
    }

    func openSettings() {
        refreshClaudeHookState()
        // 已经开着：拿到最前面，不关掉（自查 Bug F）
        if Hud.isOpen("settings"), let w = Hud.windows["settings"] {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        Hud.toggle(key: "settings", title: L("win.settings"),
                   size: CGSize(width: kSettingsWidth, height: 520), minimizable: true,
                   themed: (self, { p in AnyView(SettingsView(model: self, p: p)) }),
                   origin: { size in
                       NSPoint(x: self.screen.minX + 40, y: self.screen.midY - size.height / 2)
                   })
    }

    @discardableResult
    func toggleWidget() -> Bool {
        // 用红色关闭键关掉小组件时，设置里「常驻小组件」开关要跟着关（之前不会）
        Hud.onClose["widget"] = { [weak self] in
            guard let self = self, self.widgetVisible else { return }
            self.widgetVisible = false
            UserDefaults.standard.set(false, forKey: "widgetVisible")
            logLine("小组件被关闭键关掉，开关已同步为关")
        }
        defer { UserDefaults.standard.set(widgetVisible, forKey: "widgetVisible") }   // 记住开关，重启后恢复（自查第 5 条）
        widgetVisible = Hud.toggle(key: "widget", title: L("win.widget"),
                                   size: CGSize(width: 270, height: 300),
                                   themed: (self, { _ in AnyView(WidgetView(model: self)) }),
                                   origin: { size in
                                       NSPoint(x: self.screen.maxX - size.width - 24,
                                               y: self.screen.maxY - size.height - 24)
                                   })
        return widgetVisible
    }

    /// 点趋势柱 -> 打开独立的“详情”窗口
    func openDetail(_ day: AppData.Day) {
        openedDay = day
        // 窗口标题直接写日期（「10 月 15 日」），内容里不再重复
        let parts = day.iso.split(separator: "-").compactMap { Int($0) }
        let title = parts.count == 3 ? (L10n.isZh ? L("win.dayTitle", parts[1], parts[2]) : A11yText.spokenDate(iso: day.iso)) : day.iso
        let labels = Dictionary(uniqueKeysWithValues: (data?.models ?? []).map { ($0.key, $0.label) })
        Hud.windows["detail"]?.orderOut(nil)       // 点另一天：直接换内容，不要先关后开两下
        Hud.toggle(key: "detail", title: title,
                   size: CGSize(width: 320, height: 270),
                   themed: (self, { p in AnyView(DayDetail(day: day, modelKey: self.trendModelKey,
                                                           labels: labels, p: p)) }),
                   origin: { size in
                       NSPoint(x: self.screen.maxX - size.width - 24,
                               y: self.screen.maxY - 540 - size.height)
                   })
    }
}
