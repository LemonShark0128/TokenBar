import Foundation

/// 通用到点判断和按量付费平台的既有放慢规则。
enum PollCadence {
    /// 5 小时窗口重置后多久补刷（等对方把新窗口记上）
    static let resetSlack: TimeInterval = 60
    /// 连续这么多次余额没变才开始放慢
    static let steadyAfter = 3
    /// 用户 2026-11-13 反馈「刷新慢」：仅把余额不变的上限缩到 4 分钟，及时发现扣费；失败退避不变。
    static let steadyCap: TimeInterval = 240
    /// 计时器每拍允许的误差：比到点早一点点也算到点
    static let dueSlack: TimeInterval = 1

    /// 按量付费平台：unchanged = 连续几次取到的余额和上一次一样。满 3 次翻倍，之后每次再翻倍，最多 4 分钟
    /// （基础间隔本身更长时以基础间隔为准）
    static func steadyInterval(base: TimeInterval, unchanged: Int) -> TimeInterval {
        guard unchanged >= steadyAfter else { return base }
        let doubled = base * pow(2, Double(min(unchanged - steadyAfter + 1, 16)))
        return max(base, min(doubled, steadyCap))
    }

    /// 下次到点：一般是 anchor + interval；知道 5 小时窗口的重置时间、且它早于下次到点时，重置后补刷一次
    static func nextDue(anchor: Date, interval: TimeInterval, resetAt: Date?, now: Date) -> Date {
        let due = anchor.addingTimeInterval(interval)
        guard let r = resetAt, r > now else { return due }
        return min(due, r.addingTimeInterval(resetSlack))
    }

    /// 到点了吗。下次到点比「现在 + 一整个间隔」还远，说明时钟往回拨过（或间隔变短了）：马上补一次
    static func isDue(nextDue: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let d = nextDue else { return true }
        if d <= now.addingTimeInterval(dueSlack) { return true }
        return d.timeIntervalSince(now) > interval + dueSlack
    }

    /// 日志里的间隔：「30 分钟」「90 秒」
    static func label(_ s: TimeInterval) -> String {
        let n = Int(s.rounded())
        return n < 60 || n % 60 != 0 ? "\(n) 秒" : "\(n / 60) 分钟"
    }
}

/// 活跃任务追读；离屏且无任务只由文件事件和兜底扫描唤醒。
enum RunningScanCadence {
    static let fast: TimeInterval = 2
    static let recent: TimeInterval = 1800
    static let fallback: TimeInterval = 300
    static func interval(visible: Bool, lastTask: Date?, now: Date) -> TimeInterval? {
        if let t = lastTask, abs(now.timeIntervalSince(t)) < recent { return fast }
        return visible ? 10 : nil
    }
}

enum FailureKind: Equatable {
    case transient, needsUser
    static func from(_ status: PlatformStatus) -> FailureKind? {
        switch status {
        case .credentialInvalid, .keychainUnreadable, .consoleLoginNeeded: return .needsUser
        case .stale, .schemaChanged, .rateLimited, .offline: return .transient
        case .ok, .loading, .notAdded, .hidden: return nil
        }
    }
}

enum QuotaCadence {
    static let visible: TimeInterval = 60
    static let background: TimeInterval = 300
    static let renewed: TimeInterval = 60
    static let retryBase: TimeInterval = 300
    static let settled: TimeInterval = 1800
    static func interval(visible: Bool, renewedPending: Bool, failure: FailureKind?, failuresInARow: Int) -> TimeInterval {
        switch failure {
        case .needsUser: return settled
        case .transient: return min(settled, retryBase * pow(2, Double(min(3, max(0, failuresInARow - 1)))))
        case nil: return renewedPending ? renewed : (visible ? Self.visible : background)
        }
    }
}

struct RefreshPauseState {
    private(set) var paused = false
    @discardableResult mutating func setPaused(_ value: Bool) -> Bool {
        guard value != paused else { return false }
        paused = value
        return true
    }
}
