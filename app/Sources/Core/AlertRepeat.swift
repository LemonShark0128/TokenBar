import Foundation

/// 余额 / 额度低于预警线、一直没恢复时，隔多久再提醒一次（用户可选，默认 6 小时；0 = 只提醒一次）
enum AlertRepeat {
    static let key = "alertRepeatHours"
    static let defaultHours = 6
    static var options: [SettingsLayout.Option] { [1, 3, 6, 12, 24, 0].map { ("\($0)", label($0)) } }

    static func label(_ hours: Int) -> String {
        switch hours {
        case 0: return L("repeat.once")
        case 24: return L("repeat.daily")
        default: return L("repeat.everyHours", hours)
        }
    }

    /// 存着的间隔；没存过或不在选项里时用默认
    static func hours(_ d: UserDefaults) -> Int {
        guard d.object(forKey: key) != nil else { return defaultHours }
        let h = d.integer(forKey: key)
        return options.contains { $0.key == "\(h)" } ? h : defaultHours
    }

    /// 余额在预警线下时要不要提醒：刚跌破（之前在线上）或从没提醒过就提醒；一直在线下时到了间隔才再提醒
    static func shouldFire(wasAbove: Bool, lastAt: Date?, now: Date, hours: Int) -> Bool {
        if wasAbove { return true }
        guard let lastAt else { return true }
        guard hours > 0 else { return false }
        return now.timeIntervalSince(lastAt) >= TimeInterval(hours) * 3600
    }
}
