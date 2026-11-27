import Foundation

extension UsageModel {
    /// A missing main snapshot must not hide other added platforms in the overview.
    var todayData: AppData? {
        if let data { return data }
        guard let store = usageStore,
              let main = store.platforms.first(where: { $0.id == store.mainProvider && $0.status.isShown }) else { return nil }
        return composedData(main: main, store: store, now: fixedNow ?? Date())
    }

    /// 某平台为主的 AppData：映射 + 辅助行按用户排序 + 风险（概览与详情页共用，保持一致）
    private func composedData(main: PlatformState, store: UsageStore, now: Date) -> AppData {
        let zone = TimeZone.autoupdatingCurrent
        var d = AppDataMapping.appData(main: main, others: store.platforms.filter { $0.id != main.id },
                                      now: now, timeZone: zone,
                                      usdToCny: ProviderSettings.load(.standard).usdToCny,
                                      localUsage: localUsage, localBreakdowns: localBreakdowns,
                                      spendHistory: store.spendHistory(now: now, timeZone: zone))
        d.sides = SideOrder.apply(sideOrder, to: d.sides)
        AppDataMapping.applyRisks(&d, main: main.id, risks: store.risks(), now: now,
                                  timeZone: .autoupdatingCurrent, currency: d.balance.currency)
        return d
    }

    /// The display model has no timers or attached store subscriptions. Navigation never pins a provider.
    func showPanelDetail(_ id: ProviderID) {
        detailPlatform = id
        if panelDetailModel == nil { panelDetailModel = UsageModel(passive: true) }
        refreshPanelDetail()
        onRefit?()
    }

    func showTodayHome() {
        detailPlatform = nil
        panelDetailModel = nil
        onRefit?()
    }

    func refreshPanelDetail() {
        guard let id = detailPlatform, let detail = panelDetailModel else { return }
        let now = fixedNow ?? Date()
        if let store = usageStore {
            guard let state = store.platforms.first(where: { $0.id == id && $0.status.isShown }) else {
                showTodayHome()
                return
            }
            detail.mainState = state
            detail.data = composedData(main: state, store: store, now: now)
        } else if id == mainID {
            detail.mainState = mainState
            detail.data = data
        }
        detail.usageStore = usageStore
        detail.runningTasks = runningTasks
        detail.fixedNow = fixedNow
        detail.fuelFullCny = fuelFullCny
        detail.claudeHookState = claudeHookState
        detail.claudeSource = claudeSource
        detail.onRefit = onRefit
    }

    func showWidgetDetail(_ id: ProviderID) {
        widgetDetailPlatform = id
        widgetDetailModel = UsageModel(passive: true)
        refreshWidgetDetail()
    }

    func showWidgetOverview() {
        widgetDetailPlatform = nil
        widgetDetailModel = nil
    }

    /// A separate passive display model: never pins or changes panel navigation.
    func refreshWidgetDetail() {
        guard let id = widgetDetailPlatform, let detail = widgetDetailModel else { return }
        if let store = usageStore {
            guard let state = store.platforms.first(where: { $0.id == id && $0.status.isShown }) else {
                showWidgetOverview()
                return
            }
            detail.mainState = state
            detail.data = composedData(main: state, store: store, now: fixedNow ?? Date())
        } else if id == mainID {
            detail.mainState = mainState
            detail.data = data
        }
        detail.fixedNow = fixedNow
        detail.fixedTimeZone = fixedTimeZone
        detail.fuelFullCny = fuelFullCny
        detail.gaugeScaleFrom = { [weak self] in self?.gaugeScale }
        detail.claudeHookState = claudeHookState
        detail.claudeSource = claudeSource
    }
}
