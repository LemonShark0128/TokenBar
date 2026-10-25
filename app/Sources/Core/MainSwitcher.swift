import Foundation

/// 主平台自动切换的状态（存 UserDefaults 的 mainSwitch，JSON）
struct MainSwitchState: Equatable, Codable {
    var main: ProviderID
    /// 是否自动切换（设置里可关）
    var auto: Bool
    /// 手动设主平台后，到这个时间前不自动切
    var pinnedUntil: Date?
    /// 上次自动切换的时间（冷却从这里算）
    var lastSwitchAt: Date?
    /// 旧版（按花费 1.5 倍切换）正在计时的平台；2026-10-18 起不再使用，只为读旧存档保留
    var leader: ProviderID?
    var leaderSince: Date?
}

extension MainSwitchState {
    /// 手写解码：存的平台已被删除（老用户的 claude / openai）时不整份作废——
    /// 主平台先记成 DeepSeek（UsageStore 随后回落到第一个已添加的平台），候选平台清掉，自动切换开关等保留
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        main = ProviderID(rawValue: try c.decode(String.self, forKey: .main)) ?? .deepseek
        auto = try c.decode(Bool.self, forKey: .auto)
        pinnedUntil = try c.decodeIfPresent(Date.self, forKey: .pinnedUntil)
        lastSwitchAt = try c.decodeIfPresent(Date.self, forKey: .lastSwitchAt)
        leader = try c.decodeIfPresent(String.self, forKey: .leader).flatMap(ProviderID.init(rawValue:))
        leaderSince = leader == nil ? nil : try c.decodeIfPresent(Date.self, forKey: .leaderSince)
    }
}

/// 平台近 1 小时的活跃度：按量付费看每小时花费（人民币），套餐平台看额度涨幅（百分点）
enum Activity: Equatable {
    case money(perHourCny: Decimal)
    case quota(risePP: Double)

    /// 近 1 小时算「在用」（主平台切换、菜单栏跟随主面板共用门槛）
    var inUse: Bool {
        switch self {
        case .money(let r): return r >= MainSwitcher.floorPerHourCny
        case .quota(let x): return x >= MainSwitcher.quotaFloorPP
        }
    }
    /// 相对「在用」下限的倍数，跨类型挑最活跃的平台时用（「其他平台」排序也用它，见 SideOrder）
    var multiple: Double {
        switch self {
        case .money(let r): return AppDataMapping.double(r / MainSwitcher.floorPerHourCny)
        case .quota(let x): return x / MainSwitcher.quotaFloorPP
        }
    }
}

/// 主平台自动切换（用户 2026-10-18 定）：10 分钟内有任务在跑的平台；几个都在跑按平台顺序每 10 秒轮流，
/// 只剩一个时保留 1 分钟切换冷却；都没在跑保持上一次。手动设主平台后暂停 7200 秒。
/// 活跃度门槛（Activity.inUse）仍用在菜单栏「跟随主面板」和「其他平台」排序
enum MainSwitcher {
    static let floorPerHourCny: Decimal = 0.5
    /// 套餐平台「在用」的下限：近 1 小时额度涨幅（百分点）
    static let quotaFloorPP: Double = 5
    /// 任务最后活动在这么久以内算「在跑」（与菜单栏 MenuBarRotation 相同）
    static let runningWindow: TimeInterval = 600
    /// 两次自动切换之间至少隔这么久
    static let minInterval: TimeInterval = 60
    static let rotateInterval: TimeInterval = 10
    static let pinFor: TimeInterval = 7200

    /// lastActivity：各平台最近一次本机任务活动；added：已添加的平台
    static func step(_ s: MainSwitchState, lastActivity: [ProviderID: Date], added: Set<ProviderID>,
                     now: Date) -> MainSwitchState {
        var s = clearLeader(s)
        if !s.auto || (s.pinnedUntil.map { now < $0 } ?? false) { return s }
        let running = rotation(s, lastActivity: lastActivity, added: added, now: now)
        if running.count > 1 {
            s.main = MenuBarRotation.keep(running, current: s.main)
            return s
        }
        guard let target = running.first, target != s.main else { return s }
        if let last = s.lastSwitchAt, now.timeIntervalSince(last) < minInterval { return s }
        s.main = target
        s.lastSwitchAt = now
        return s
    }

    /// 手动设主平台：立即生效，暂停自动切换 7200 秒（不算自动切换，不触发冷却）
    static func pin(_ s: MainSwitchState, to id: ProviderID, now: Date) -> MainSwitchState {
        var s = clearLeader(s)
        s.main = id
        s.pinnedUntil = now.addingTimeInterval(pinFor)
        return s
    }

    private static func clearLeader(_ s: MainSwitchState) -> MainSwitchState {
        var s = s
        s.leader = nil
        s.leaderSince = nil
        return s
    }

    /// 自动且未暂停时，在跑的已添加平台，始终按注册顺序排列。
    static func rotation(_ s: MainSwitchState, lastActivity: [ProviderID: Date],
                         added: Set<ProviderID>, now: Date) -> [ProviderID] {
        guard s.auto, !(s.pinnedUntil.map { now < $0 } ?? false) else { return [] }
        return ProviderRegistry.all.filter { id in
            added.contains(id) && lastActivity[id].map { now.timeIntervalSince($0) <= runningWindow } == true
        }
    }

}

/// 主平台切换动画的参数；界面按它选 matchedGeometryEffect 还是淡入淡出
enum SwitchMotion {
    enum Style: Equatable { case matchedGeometry, fade }
    static let springResponse: Double = 0.5
    static let springDamping: Double = 0.8
    /// 切换提示显示多久后淡出（秒）
    static let noticeSeconds: Double = 3

    static func style(reduceMotion: Bool) -> Style { reduceMotion ? .fade : .matchedGeometry }
}
