import Foundation

/// 几个平台同时在用时固定显示的「常用平台」（用户 2026-11-06 选 proposal-preferred-platform 乙）：
/// 近 7 天本机活跃分钟数（Claude Code / Codex 日志里有记录的分钟，同一分钟多条只算 1）最多的那个，不再每 10 秒轮流。
/// 防止来回跳：另一个平台要超过当前常用平台 20% 以上才换；每小时最多重算一次（UsageStore 管）
enum PreferredPlatform {
    static let margin = 1.2
    static let recheck: TimeInterval = 3600

    /// 按活跃分钟数选常用平台。没有任何分钟数时保留 current（可能是 nil）
    static func pick(minutes: [ProviderID: Int], current: ProviderID?) -> ProviderID? {
        // 分钟数相同按注册顺序后面的（Claude 套餐在 Codex 套餐后面）优先，结果固定
        let order = ProviderRegistry.all
        let best = minutes.filter { $0.value > 0 }.max { a, b in
            a.value != b.value ? a.value < b.value
                : (order.firstIndex(of: a.key) ?? 0) < (order.firstIndex(of: b.key) ?? 0)
        }
        guard let best else { return current }
        guard let current, current != best.key, let cur = minutes[current], cur > 0 else { return best.key }
        return Double(best.value) > Double(cur) * margin ? best.key : current
    }

    /// 同时在用的平台里显示哪个：常用平台在里面就是它；否则正在显示的还在就留着；
    /// 都不是时先套餐平台（看得到任务）再按量付费平台，各自按注册顺序
    static func choose(running: [ProviderID], preferred: ProviderID?, current: ProviderID) -> ProviderID {
        if let preferred, running.contains(preferred) { return preferred }
        if running.contains(current) { return current }
        let quota = running.filter { ProviderRegistry.meter($0) == .quota }
        return quota.first ?? running.first ?? current
    }
}
