import Foundation

/// 面板「其他平台」的顺序：按近 1 小时活跃度（与自动切换主平台同一套 Activity），最活跃的在最上面。
/// 面板开着时不重排；名次只在用户下一次打开面板时更新（界面播放挪位置的动画）
enum SideOrder {
    /// 活跃度相对「在用」下限的倍数；没有读数按 0
    static func score(_ a: Activity?) -> Double { a?.multiple ?? 0 }

    /// 按活跃度从高到低；同分按平台顺序（都没读数时与原来的顺序一致）
    static func ranked(_ ids: [ProviderID], activity: [ProviderID: Activity]) -> [ProviderID] {
        ids.sorted {
            let a = score(activity[$0]), b = score(activity[$1])
            return a != b ? a > b : order($0) < order($1)
        }
    }

    /// 保持旧顺序，只处理增减：消失的平台让出位置，新出现的平台（按 current 的顺序）先填这些空位，再接在后面
    static func reconcile(_ frozen: [ProviderID], with current: [ProviderID]) -> [ProviderID] {
        let now = Set(current)
        var newcomers = current.filter { !frozen.contains($0) }
        var out: [ProviderID] = []
        for id in frozen {
            if now.contains(id) { out.append(id) }
            else if !newcomers.isEmpty { out.append(newcomers.removeFirst()) }
        }
        return out + newcomers
    }

    /// 按顺序表排列辅助行；表里没有的行放最后，保持原顺序
    static func apply(_ order: [ProviderID], to sides: [AppData.Side]) -> [AppData.Side] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element.rawValue, $0.offset) })
        return sides.enumerated().sorted {
            let a = rank[$0.element.id] ?? order.count + $0.offset, b = rank[$1.element.id] ?? order.count + $1.offset
            return a < b
        }.map(\.element)
    }

    private static func order(_ id: ProviderID) -> Int { ProviderID.allCases.firstIndex(of: id) ?? 0 }
}
