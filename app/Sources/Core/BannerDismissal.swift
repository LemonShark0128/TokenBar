import Foundation

/// 每个平台只记最近关闭的提醒；风险解除后重新允许提醒。
struct BannerDismissal: Equatable {
    var dismissed: [String: String] = [:]

    func hides(_ b: AppData.RiskBanner) -> Bool { dismissed[b.id] == b.key }

    mutating func dismiss(_ b: AppData.RiskBanner) { dismissed[b.id] = b.key }

    /// 风险解除（或平台已移除）的关掉记录删掉，下次再出现时照常显示。
    /// pending：已添加但还没有读数的平台（启动时正在连接），它们的记录保留，否则每次重启关掉的横幅都会回来
    mutating func prune(risks: [PlatformRisk], pending: Set<ProviderID> = []) {
        // 取数失败（noData）不能证明风险解除：保留记录，免得断网一下、恢复后同一横幅又弹
        let keep = Set(risks.filter { $0.atRisk || $0.kind == .noData }.map { $0.id.rawValue }).union(pending.map(\.rawValue))
        dismissed = dismissed.filter { keep.contains($0.key) }
    }

    static func load(_ d: UserDefaults) -> BannerDismissal {
        BannerDismissal(dismissed: d.dictionary(forKey: "riskBanner.dismissed") as? [String: String] ?? [:])
    }

    func save(_ d: UserDefaults) { d.set(dismissed, forKey: "riskBanner.dismissed") }
}
