import Foundation

/// 余额估算没有 token 读数；有其他来源时继续显示全平台图。
enum BalanceEstimatePresentation {
    static func menuTitle(_ title: String, mode: String, source: String?, hasAmount: Bool) -> String {
        mode == "cost" && source == "余额估算" && hasAmount ? "≈" + title : title
    }

    static func usageTooltip(source: String?, tokens: Int, freshness: String) -> String {
        source == "余额估算" ? "\n" + freshness : L("menu.tip.usage", cnCount(tokens), freshness)
    }

    static func showsTokenTrend(_ d: AppData) -> Bool {
        mainHasTokenDetail(d) || !d.sides.isEmpty || !d.tokenSources.isEmpty
    }

    /// 主平台有 token 读数（缓存命中率、token 柱图）：余额估算没有；OpenRouter 只给花费金额，也没有
    static func mainHasTokenDetail(_ d: AppData) -> Bool {
        d.today.source != "余额估算" && ProviderRegistry.capabilities(d.mainProvider).hasTokenDetail
    }
}
