import Foundation

extension UsageModel {
    /// Same source and ordering as SettingsView.ctx / SettingsLayout.added.
    /// Offline and credential-expired accounts remain in the saved layout.
    var todayPlatformIDs: [String] {
        if let store = usageStore {
            let states = Dictionary(uniqueKeysWithValues: store.platforms.map { ($0.id, Self.accountState(for: $0)) })
            // 隐藏的平台也留在布局里（暂时隐藏，显示回来还在原位、原尺寸）；没卡片的位置摆放时自动跳过
            return SettingsLayout.added(states).map(\.rawValue)
        }
        guard let d = todayData else { return [] }
        let present = Set(d.sides.map(\.id) + [d.mainProvider.rawValue])
        return ProviderRegistry.all.map(\.rawValue).filter { present.contains($0) }
    }
    var resolvedTodayLayout: [TodayLayoutItem] {
        let ids = todayPlatformIDs
        return TodayLayout.reconcile(saved: todayLayout.isEmpty ? nil : todayLayout, platformIDs: ids, defaultOrder: ids)
    }
    func setTodayLayout(_ layout: [TodayLayoutItem]) {
        guard layout != todayLayout else { return }
        todayLayout = layout
        if savesTodayLayout { UserDefaults.standard.set(TodayLayout.encode(layout), forKey: "todayLayout") }
        onRefit?()
    }
    func reconcileTodayLayout() { setTodayLayout(resolvedTodayLayout) }
}
