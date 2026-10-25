import Foundation

/// 按活动决定刷新频率（省电）。纯函数，时间由调用方给。
/// - 套餐平台：本机最近 15 分钟有活动（在跑的任务、会话日志有更新、桌面 App 记到额度变化）按设置的间隔；
///   空闲时放慢（Claude 30 分钟兜底：额度跨设备共享，网页版、手机上用了本机看不到；Codex 10 分钟）。
/// - 按量付费平台：连续 3 次余额没变就把间隔翻倍，最多 10 分钟；变了、手动刷新就回到设置的间隔。
enum PollCadence {
    /// 「有活动」的时间窗
    static let activeWindow: TimeInterval = 15 * 60
    /// 5 小时窗口重置后多久补刷（等对方把新窗口记上）
    static let resetSlack: TimeInterval = 60
    /// 连续这么多次余额没变才开始放慢
    static let steadyAfter = 3
    /// 余额没变时最多放慢到
    static let steadyCap: TimeInterval = 600
    /// 计时器每拍允许的误差：比到点早一点点也算到点
    static let dueSlack: TimeInterval = 1

    /// 空闲时的间隔；nil = 这个平台不按活动放慢
    static func idleInterval(_ id: ProviderID) -> TimeInterval? {
        switch id {
        case .claudePlan: return 1800
        case .codexPlan: return 600
        case .deepseek, .siliconflow: return nil
        }
    }

    /// 最近一次活动在 15 分钟内。略在未来（文件时间和本机时钟差一点）也算；
    /// 远在未来（时钟往回拨过）不算，免得一直当成有活动
    static func isActive(lastActivity: Date?, now: Date) -> Bool {
        guard let t = lastActivity else { return false }
        return abs(now.timeIntervalSince(t)) < activeWindow
    }

    /// 套餐平台的间隔：有活动按设置的间隔，空闲取两者较长的
    static func quotaInterval(base: TimeInterval, idle: TimeInterval?, active: Bool) -> TimeInterval {
        guard !active, let idle else { return base }
        return max(base, idle)
    }

    /// 按量付费平台：unchanged = 连续几次取到的余额和上一次一样。满 3 次翻倍，之后每次再翻倍，最多 10 分钟
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

/// 本机「在跑任务」扫描的频率：面板或小组件开着、或最近 5 分钟有在跑的任务时 10 秒，否则 30 秒
enum RunningScanCadence {
    static let fast: TimeInterval = 10
    static let slow: TimeInterval = 30
    static let recent: TimeInterval = 300

    static func interval(visible: Bool, lastTask: Date?, now: Date) -> TimeInterval {
        if visible { return fast }
        if let t = lastTask, now.timeIntervalSince(t) < recent { return fast }
        return slow
    }
}

enum PlanActivity {
    /// 桌面 App 开着时每 15 分钟记一条额度读数，不管用没用。只有读数和上一条不一样才算活动：返回最近一次变化的时间
    static func desktopChangedAt(_ samples: [ClaudeAppUsageSource.Sample]) -> Date? {
        var last: Date?
        for (a, b) in zip(samples, samples.dropFirst()) where a.fh != b.fh || a.sd != b.sd || a.so != b.so || a.sn != b.sn {
            last = b.t
        }
        return last
    }
}

/// 桌面 App 的额度记录（plan-usage-history.json）最近一次变化的时间。文件没变（修改时间、大小一样）就不再解析。
/// 由 UsageModel 持有，在后台线程调用，内部加锁
/// @unchecked Sendable：所有可变状态只在 lock 里读写
final class DesktopActivityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var key: (mtime: Date, size: UInt64)?
    private var cached: Date?
    private var parsed = 0

    init() {}

    /// 实际解析了几次（测试用）
    var parseCount: Int { lock.withLock { parsed } }

    func changedAt(_ url: URL, fileManager fm: FileManager = .default) -> Date? {
        lock.withLock {
            guard let a = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = a[.modificationDate] as? Date else { key = nil; cached = nil; return nil }
            let size = (a[.size] as? NSNumber)?.uint64Value ?? 0
            if let k = key, k.mtime == mtime, k.size == size { return cached }
            key = (mtime, size)
            parsed += 1
            guard size <= UInt64(ClaudeAppUsageSource.maxBytes), let data = try? Data(contentsOf: url),
                  case .samples(let s) = ClaudeAppUsageSource.parse(data) else { cached = nil; return nil }
            cached = PlanActivity.desktopChangedAt(s)
            return cached
        }
    }
}
