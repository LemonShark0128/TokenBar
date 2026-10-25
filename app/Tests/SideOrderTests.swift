import Foundation

// 「其他平台」按近 1 小时活跃度排序（与自动切换主平台同一套 Activity）
@MainActor
func registerSideOrderTests() {
    test("sideOrderRanksByActivity") {
        // 硅基流动 ¥1/时 = 下限 2 倍；Codex 涨 15 个百分点 = 下限 3 倍；Claude 没读数按 0
        let act: [ProviderID: Activity] = [.siliconflow: .money(perHourCny: 1), .codexPlan: .quota(risePP: 15)]
        try checkEqual(SideOrder.ranked([.siliconflow, .codexPlan, .claudePlan], activity: act),
                       [.codexPlan, .siliconflow, .claudePlan])
        // 都没读数：按平台顺序（与原来一致）
        try checkEqual(SideOrder.ranked([.claudePlan, .siliconflow, .codexPlan], activity: [:]),
                       [.siliconflow, .codexPlan, .claudePlan])
        // 同分按平台顺序
        let tie: [ProviderID: Activity] = [.claudePlan: .quota(risePP: 5), .siliconflow: .money(perHourCny: Decimal(string: "0.5")!)]
        try checkEqual(SideOrder.ranked([.claudePlan, .siliconflow], activity: tie), [.siliconflow, .claudePlan])
        try checkEqual(SideOrder.score(nil), 0)
        try checkEqual(SideOrder.score(.quota(risePP: 10)), 2)
    }
    test("sideOrderReconcileKeepsFrozenOrder") {
        // 面板开着（或还没重新打开）：名次不变，只处理增减
        try checkEqual(SideOrder.reconcile([.codexPlan, .siliconflow], with: [.siliconflow, .codexPlan]),
                       [.codexPlan, .siliconflow])
        // 换了主平台：新主平台让出的位置给原主平台（行原地互换，配对动画不乱跑）
        try checkEqual(SideOrder.reconcile([.codexPlan, .siliconflow, .claudePlan], with: [.deepseek, .codexPlan, .claudePlan]),
                       [.codexPlan, .deepseek, .claudePlan])
        // 新添加的平台：按传入顺序接在后面
        try checkEqual(SideOrder.reconcile([.siliconflow], with: [.codexPlan, .siliconflow, .claudePlan]),
                       [.siliconflow, .codexPlan, .claudePlan])
        // 第一次（没有旧顺序）：直接用传入顺序
        try checkEqual(SideOrder.reconcile([], with: [.codexPlan, .siliconflow]), [.codexPlan, .siliconflow])
        try checkEqual(SideOrder.reconcile([.codexPlan], with: []), [])
    }
    test("sideOrderAppliesToSides") {
        func side(_ id: ProviderID) -> AppData.Side {
            AppData.Side(id: id.rawValue, name: ProviderRegistry.displayName(id), tank: nil, currency: "CNY", todayCost: nil, status: "正常")
        }
        let sides = [side(.siliconflow), side(.codexPlan), side(.claudePlan)]
        try checkEqual(SideOrder.apply([.claudePlan, .siliconflow, .codexPlan], to: sides).map(\.id),
                       ["claudePlan", "siliconflow", "codexPlan"])
        // 顺序表里没有的行放最后，保持原顺序
        try checkEqual(SideOrder.apply([.codexPlan], to: sides).map(\.id), ["codexPlan", "siliconflow", "claudePlan"])
    }
}
