import Foundation

@MainActor
func registerMenuBarSecondaryTests() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let cells = [ProviderID.claudePlan, .codexPlan, .deepseek].map {
        MenuBarCell(id: $0, kind: .quota(session: 47, weekly: 79, pace: nil),
                    severity: nil, stale: false, exhausted: false)
    }
    func task(_ id: ProviderID, age: TimeInterval = 0) -> RunningTask {
        RunningTask(provider: id, sessionKey: id.rawValue, project: "test", model: nil,
                    startedAt: now.addingTimeInterval(-600), lastActivity: now.addingTimeInterval(-age), tokens: 0)
    }
    test("menuDotRunningStaleNone") {
        let tasks = [task(.claudePlan, age: 300), task(.codexPlan, age: 301)]
        try checkEqual(MenuBarSecondary.dot(for: .codexPlan, tasks: [], now: now), .none)
        try checkEqual(MenuBarSecondary.dot(for: .claudePlan, tasks: tasks, now: now), .stale)
        try checkEqual(MenuBarSecondary.dot(for: .codexPlan, tasks: tasks + [task(.codexPlan, age: 299)], now: now), .running)
    }
    test("menuSlotsRotationClockUsesNextFiveSecondBoundary") {
        try checkEqual(MenuBarSecondary.nextRotation(after: now), now.addingTimeInterval(5))
        try checkEqual(MenuBarSecondary.nextRotation(after: now.addingTimeInterval(4.9)), now.addingTimeInterval(5))
        try checkEqual(MenuBarSecondary.nextRotation(after: now.addingTimeInterval(5)), now.addingTimeInterval(10))
    }
    test("menuSlotsAnimateOnlyWhenCombinationChanges") {
        // 用户 2026-11-13：左右任一组变化或换位都切换；读数和圆点更新不改变组合。
        let initial = MenuBarSlots(main: cells[0], secondary: cells[1], mainRunning: false, secondaryRunning: true)
        var updated = initial
        updated.main?.kind = .quota(session: 12, weekly: 79, pace: nil)
        updated.secondaryRunning = false
        func ids(_ slots: MenuBarSlots) -> [ProviderID] { [slots.main, slots.secondary].compactMap { $0?.id } }
        try check(!MenuBarSecondary.shouldAnimate(from: ids(initial), to: ids(updated)))
        try check(MenuBarSecondary.shouldAnimate(from: [.claudePlan, .codexPlan], to: [.deepseek, .codexPlan]))
        try check(MenuBarSecondary.shouldAnimate(from: [.claudePlan, .codexPlan], to: [.codexPlan, .claudePlan]))
        try check(MenuBarSecondary.shouldAnimate(from: [.claudePlan], to: [.claudePlan, .deepseek]))
        try check(MenuBarSecondary.shouldAnimate(from: [.claudePlan, .deepseek], to: [.claudePlan]))
        try check(!MenuBarSecondary.shouldAnimate(from: [], to: []))
    }

    test("slotModeParsing") {
        for raw in [nil, "", "bad", "single"] as [String?] {
            try checkEqual(SettingsLayout.menuBarSlotMode(raw), .single)
        }
        try checkEqual(SettingsLayout.menuBarSlotMode("double"), .double)
    }
    func select(_ tasks: [RunningTask], mode: MenuBarSlotMode = .single, show: Bool = true,
                history: [ProviderID: Date] = [:], offset: Double = 0,
                order: [ProviderID] = [.claudePlan, .codexPlan, .deepseek],
                payg: Set<ProviderID> = [], available: [MenuBarCell]? = nil) -> MenuBarSelection {
        MenuBarSelection.select(cells: available ?? cells, order: order, paygActive: payg,
                                tasks: tasks, showRunning: show,
                                mode: mode, lastActivity: history, now: now.addingTimeInterval(offset))
    }
    func ids(_ selection: MenuBarSelection) -> [ProviderID] {
        [selection.slots.main, selection.slots.secondary].compactMap { $0?.id }
    }
    // 用户 2026-11-27：谁在跑显示谁；两个以上在跑才并排，左右按面板顺序；都没在跑显示面板第一个。
    test("doubleSelectionFollowsPanelOrder") {
        let cases: [([ProviderID], Set<ProviderID>, [ProviderID])] = [
            ([], [], [.claudePlan]),
            ([.codexPlan], [], [.codexPlan]),
            ([], [.deepseek], [.deepseek]),
            ([.codexPlan], [.deepseek], [.codexPlan, .deepseek]),
            ([.claudePlan, .codexPlan], [.deepseek], [.claudePlan, .codexPlan]),
            ([.claudePlan], [], [.claudePlan])
        ]
        for (running, payg, expected) in cases {
            let result = select(running.map { task($0) }, mode: .double, payg: payg)
            try checkEqual(ids(result), expected)
            try check(!result.shouldRotate)
        }
    }
    test("changedOrderChangesAnchorAndSides") {
        let order: [ProviderID] = [.codexPlan, .deepseek, .claudePlan]
        try checkEqual(ids(select([], mode: .double, order: order)), [.codexPlan])
        try checkEqual(ids(select([task(.claudePlan)], mode: .double, order: order)), [.claudePlan])
        try checkEqual(ids(select([task(.claudePlan)], mode: .double, order: order, payg: [.deepseek])), [.deepseek, .claudePlan])
        try checkEqual(ids(select([task(.claudePlan), task(.codexPlan)], order: order)), [.codexPlan])
    }
    test("singleUsesFirstActiveIncludingPayg") {
        try checkEqual(ids(select([], payg: [.deepseek])), [.deepseek])
        try checkEqual(ids(select([task(.codexPlan)], payg: [.deepseek])), [.codexPlan])
    }
    test("orderFiltersHiddenAndUnaddedCells") {
        let order: [ProviderID] = [.kimi, .siliconflow, .claudePlan, .codexPlan, .deepseek]
        let result = select([task(.codexPlan)], mode: .double, history: [.codexPlan: now],
            order: order, payg: [.kimi, .siliconflow, .deepseek], available: [cells[0], cells[2]])
        try checkEqual(ids(result), [.deepseek])
        try checkEqual(result.lastActivity[.codexPlan], nil)
        try checkEqual(ids(select([], order: [], payg: [.deepseek])), [])
        try checkEqual(ids(select([], available: [])), [])
    }
    test("singleIdle") { try checkEqual(select([]).slots.main?.id, .claudePlan) }
    test("singleRunning") { try checkEqual(select([task(.codexPlan)]).slots.main?.id, .codexPlan) }
    // 用户 2026-11-13：多个活跃平台按面板顺序选择，不轮流。
    test("singleUsesPanelOrderWhenSeveralRun") {
        let tasks = [task(.claudePlan), task(.codexPlan)]
        try checkEqual(select(tasks).slots.main?.id, .claudePlan)
        try checkEqual(select(tasks, offset: 5).slots.main?.id, .claudePlan)
        try check(!select(tasks).shouldRotate)
    }
    test("singleRemembersActivityAndExpires") {
        let first = select([task(.codexPlan)])
        let held = select([], history: first.lastActivity, offset: 59)
        try checkEqual(held.slots.main?.id, .codexPlan)
        try check(!held.slots.mainRunning)
        try checkEqual(select([], history: held.lastActivity, offset: 60).slots.main?.id, .claudePlan)
    }
    test("activityRestartsIdleClock") {
        var renewed = task(.codexPlan)
        renewed.lastActivity = now.addingTimeInterval(250)
        let state = select([renewed], history: [.codexPlan: now], offset: 250)
        try checkEqual(select([], history: state.lastActivity, offset: 309).slots.main?.id, .codexPlan)
        try checkEqual(select([], history: state.lastActivity, offset: 310).slots.main?.id, .claudePlan)
    }
    test("doubleIdleAndRunning") {
        try checkEqual(select([], mode: .double).slots.secondary, nil)
        let result = select([task(.codexPlan)], mode: .double)
        try checkEqual(result.slots.main?.id, .codexPlan)
        try checkEqual(result.slots.secondary, nil)
        try check(result.slots.mainRunning)
        let both = select([task(.codexPlan), task(.claudePlan)], mode: .double)
        try checkEqual(ids(both), [.claudePlan, .codexPlan])
        try check(both.slots.mainRunning && both.slots.secondaryRunning)
    }
    test("disabledIgnoresMode") {
        for mode in [MenuBarSlotMode.single, .double] {
            let result = select([task(.codexPlan)], mode: mode, show: false, payg: [.deepseek])
            try checkEqual(result.slots.main?.id, .claudePlan)
            try checkEqual(result.slots.secondary, nil)
        }
    }
    test("menuSecondaryCanRunOnlyTaskPlatforms") {
        try check(MenuBarSecondary.canRun(.claudePlan) && MenuBarSecondary.canRun(.codexPlan) && MenuBarSecondary.canRun(.geminiPlan))
        try check(!MenuBarSecondary.canRun(.deepseek) && !MenuBarSecondary.canRun(.kimi))
    }
    test("menuBarImageUsesOnlyDisplayedWidth") {
        // 11/6 起不轮流；11/13 用户反馈左侧空太大，防止再次为候选平台预留宽度。
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App")
        let styles = try String(contentsOf: app.appendingPathComponent("MenuBarStyles.swift"), encoding: .utf8)
        let menu = try String(contentsOf: app.appendingPathComponent("MenuBar.swift"), encoding: .utf8)
        try check(!styles.contains("canvasWidth"), "MenuBarStyles 不应再为候选平台预留画布宽度")
        try check(!menu.contains("canvasWidth"), "MenuBar 不应再传入预留画布宽度")
        let image = styles.components(separatedBy: "static func image(").dropFirst().first?
            .components(separatedBy: "\nstruct MenuBarStylesPreview").first ?? ""
        try check(image.contains("group(main, x: 0, dot: mainDot)"), "第一组必须在左边")
        try check(image.contains("group(secondary, x: mainWidth + groupGap, dot: secondaryDot)"), "第二组必须在右边")
        try check(image.contains("let width = displayedWidth(slots)"), "图标宽度必须来自正在显示的 slots")
        try check(image.contains("NSImage(size: NSSize(width: width, height: 22)"), "画布必须使用内容宽度")
    }

    test("doubleLingerCountsFromCompletionNotLastLogWrite") {
        // 任务最后写日志是 200 秒前，但到现在还在列表里：从它消失时起再停 60 秒
        let first = select([task(.codexPlan, age: 200)], mode: .double)
        try checkEqual(first.lastActivity[.codexPlan], now)
        let held = select([], mode: .double, history: first.lastActivity, offset: 59)
        try checkEqual(ids(held), [.codexPlan])
        try check(!held.slots.mainRunning)
        try checkEqual(held.expiresAt, now.addingTimeInterval(60))
        try checkEqual(ids(select([], mode: .double, history: first.lastActivity, offset: 60)), [.claudePlan])
    }
    // 用户 2026-11-27：任务还在列表里但 5 分钟没动静（面板写「已停」）就不算在跑，不再占菜单栏一格
    test("staleListedTaskDoesNotCountAsRunning") {
        let stale = task(.codexPlan, age: 300)
        try checkEqual(ids(select([stale], mode: .double)), [.claudePlan])
        try checkEqual(ids(select([stale, task(.claudePlan)], mode: .double)), [.claudePlan])
        try checkEqual(ids(select([stale], mode: .double, payg: [.deepseek])), [.deepseek])
        try checkEqual(select([stale], mode: .double).lastActivity[.codexPlan], nil)
        // 刚变成「已停」：沿用 60 秒停留再消失
        let held = select([stale], mode: .double, history: [.codexPlan: now], offset: 59)
        try checkEqual(ids(held), [.codexPlan])
        try checkEqual(ids(select([stale], mode: .double, history: [.codexPlan: now], offset: 60)), [.claudePlan])
    }
    test("singleRemovedAndUnknownPlatformsCannotLinger") {
        try checkEqual(select([task(.siliconflow)], history: [.siliconflow: now]).slots.main?.id, .claudePlan)
    }
    test("finishedPlatformsDoNotKeepRotating") {
        for mode in [MenuBarSlotMode.single, .double] {
            let held = select([], mode: mode, history: [.codexPlan: now, .deepseek: now], offset: 1)
            try check(!held.shouldRotate, "Finished tasks must not keep rotating")
        }
    }

    test("retainedPlatformsFollowOrderAndExpireWhileAnotherIsLive") {
        let first = select([task(.claudePlan), task(.codexPlan)], mode: .double)
        let held = select([task(.codexPlan)], mode: .double, history: first.lastActivity,
                          offset: 59, payg: [.deepseek])
        try checkEqual(ids(held), [.claudePlan, .codexPlan])
        try checkEqual(held.expiresAt, now.addingTimeInterval(60))
        let expired = select([task(.codexPlan)], mode: .double, history: held.lastActivity,
                             offset: 60, payg: [.deepseek])
        try checkEqual(ids(expired), [.codexPlan, .deepseek])
    }
    test("paygDoesNotUseQuotaLingerHistory") {
        try checkEqual(ids(select([], mode: .double, history: [.deepseek: now])), [.claudePlan])
        try checkEqual(ids(select([task(.deepseek)], mode: .double)), [.claudePlan])
    }
}
