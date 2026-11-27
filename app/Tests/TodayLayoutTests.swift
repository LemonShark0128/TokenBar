import Foundation

@MainActor
func registerTodayLayoutTests() {
    for n in [2, 3, 4] {
        test("layoutDefault\(n)") {
            let ids = (0..<n).map { "p\($0)" }
            let layout = TodayLayout.defaultLayout(platformIDs: ids)
            try checkEqual(layout.map(\.id), ids + ["spend", "running", "trend"])
            try checkEqual(layout.map(\.size), Array(repeating: .small, count: n + 2) + [.medium])
            let placed = TodayLayout.place(layout, present: Set(layout.map(\.id)))
            let spend = placed.first { $0.id == "spend" }!
            try checkEqual(spend.row, n / 2); try checkEqual(spend.column, n % 2)
        }
    }
    test("layoutSmallFillsEarlierHole") {
        let items: [TodayLayoutItem] = [.init(id: "a", size: .small), .init(id: "b", size: .medium), .init(id: "c", size: .small)]
        let p = TodayLayout.place(items, present: ["a", "b", "c"])
        try checkEqual(p.map(\.row), [0, 1, 0]); try checkEqual(p.map(\.column), [0, 0, 1])
    }
    test("layoutLargeOccupiesTwoRows") {
        let p = TodayLayout.place([.init(id: "a", size: .large), .init(id: "b", size: .small)], present: ["a", "b"])
        try checkEqual(p.map(\.row), [0, 2])
    }
    test("layoutAbsentRunningDoesNotOccupySpace") {
        let p = TodayLayout.place(TodayLayout.defaultLayout(platformIDs: []), present: ["spend", "trend"])
        try checkEqual(p.map(\.id), ["spend", "trend"]); try checkEqual(p.map(\.row), [0, 1])
    }
    test("layoutSpendStretchesWithoutRunning") {
        let items = TodayLayout.defaultLayout(platformIDs: ["p1", "p2"])
        let p = TodayLayout.place(items, present: ["p1", "p2", "spend", "trend"])
        let spend = p.first { $0.id == "spend" }!
        try checkEqual(spend.row, 1); try checkEqual(spend.column, 0)
        try checkEqual(spend.stretched, true)
        try checkEqual(spend.size, .small)
        try checkEqual(items.first { $0.id == "spend" }?.size, .small)
    }
    test("layoutRunningBeforeTrendStretchesAtDisplayWidth") {
        let items: [TodayLayoutItem] = [.init(id: "a", size: .medium), .init(id: "b", size: .medium),
                                       .init(id: "running", size: .small), .init(id: "trend", size: .medium)]
        let p = TodayLayout.place(items, present: Set(items.map(\.id)))
        let running = p.first { $0.id == "running" }!
        try checkEqual(running.row, 2)
        try checkEqual(running.stretched, true)
        try checkEqual(running.size, .small)
    }
    test("layoutPairedSmallCardsDoNotStretch") {
        let items = TodayLayout.defaultLayout(platformIDs: ["p1", "p2", "p3"])
        let p = TodayLayout.place(items, present: ["p1", "p2", "p3", "spend"])
        try checkEqual(p.map(\.row), [0, 0, 1, 1])
        try checkEqual(p.map(\.stretched), [false, false, false, false])
    }
    test("layoutBackfillPreventsStretch") {
        let p = TodayLayout.place([.init(id: "a", size: .small), .init(id: "b", size: .medium),
                                   .init(id: "c", size: .small)], present: ["a", "b", "c"])
        try checkEqual(p.map(\.row), [0, 1, 0])
        try checkEqual(p.map(\.column), [0, 0, 1])
        try checkEqual(p.map(\.stretched), [false, false, false])
    }
    test("layoutLoneLastSmallStretches") {
        let p = TodayLayout.place([.init(id: "a", size: .medium), .init(id: "b", size: .small)], present: ["a", "b"])
        try checkEqual(p.map(\.stretched), [false, true])
        let lone = TodayLayout.place([.init(id: "b", size: .small)], present: ["b"])
        try checkEqual(lone.first?.stretched, true)
    }
    let base = TodayLayout.defaultLayout(platformIDs: ["a", "b"])
    test("layoutReconcileAddsPlatformAfterLastPlatform") {
        let p = TodayLayout.reconcile(saved: base, platformIDs: ["a", "b", "c"], defaultOrder: ["a", "b", "c"])
        try checkEqual(p.map(\.id), ["a", "b", "c", "spend", "running", "trend"])
    }
    test("layoutReconcileRemovesPlatformAndDuplicates") {
        let p = TodayLayout.reconcile(saved: base + base, platformIDs: ["b"], defaultOrder: ["b"])
        try checkEqual(p.map(\.id), ["b", "spend", "running", "trend"])
    }
    test("layoutReconcileMissingSpend") {
        let p = TodayLayout.reconcile(saved: base.filter { $0.id != "spend" }, platformIDs: ["a", "b"], defaultOrder: ["a", "b"])
        try checkEqual(p, base)
    }
    test("layoutReconcileNoPlatformsInSaved") {
        let p = TodayLayout.reconcile(saved: [.init(id: "trend", size: .large)], platformIDs: ["a"], defaultOrder: ["a"])
        try checkEqual(p.first?.id, "a"); try checkEqual(p.last?.size, .large)
    }
    test("layoutCodec") { try checkEqual(TodayLayout.decode(TodayLayout.encode(base)), base) }
    test("layoutBadCodec") {
        try checkEqual(TodayLayout.decode(nil), nil)
        try checkEqual(TodayLayout.decode(Data("oops".utf8)), nil)
        try checkEqual(TodayLayout.decode(Data("[{\"id\":\"a\",\"size\":\"huge\"}]".utf8)), nil)
    }
    test("layoutMoves") {
        try checkEqual(TodayLayout.move(base, id: "a", to: 2).map(\.id), ["b", "spend", "a", "running", "trend"])
        try checkEqual(TodayLayout.moveToFront(base, id: "trend").first?.id, "trend")
        try checkEqual(TodayLayout.moveToEnd(base, id: "a").last?.id, "a")
        try checkEqual(TodayLayout.move(base, id: "missing", to: 0), base)
    }
    test("layoutResizeReset") {
        try checkEqual(TodayLayout.resize(base, id: "a", to: .large).first?.size, .large)
        try checkEqual(TodayLayout.reset(platformIDs: ["a", "b"]), base)
    }
    test("layoutMainSwitchDoesNotMoveCards") {
        let now = Date(timeIntervalSince1970: 0)
        var d = AppData(nowLocal: "2026-11-03", balance: .init(cny: 1, source: "", status: "", ageS: 0), today: .init(costCny: 1, tokens: 0, source: ""), month: .init(costCny: 1, tokens: 0, source: ""), models: [], trend7: [], burn: nil)
        d.sides = [.init(id: "codexPlan", name: "Codex", tank: nil, currency: "PCT", todayCost: nil, status: "")]
        let layout = TodayLayout.defaultLayout(platformIDs: ["deepseek", "codexPlan"])
        let before = TodayLayout.place(layout, present: Set(TodayCards.build(d, running: [], now: now).map(\.id)))
        d.mainProvider = .codexPlan; d.sides[0].id = "deepseek"
        let after = TodayLayout.place(layout, present: Set(TodayCards.build(d, running: [], now: now).map(\.id)))
        try checkEqual(before, after)
    }
    test("layoutFixedSquareFrames") {
        let items: [TodayLayoutItem] = [.init(id: "a", size: .small), .init(id: "b", size: .small),
                                        .init(id: "t", size: .medium), .init(id: "l", size: .large)]
        let placed = TodayLayout.place(items, present: Set(items.map(\.id)))
        let f = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, TodayLayout.frame($0, total: 328)) })
        try checkEqual(f["a"], TodayLayout.Frame(x: 0, y: 0, width: 160, height: 160))
        try checkEqual(f["b"], TodayLayout.Frame(x: 168, y: 0, width: 160, height: 160))
        try checkEqual(f["t"], TodayLayout.Frame(x: 0, y: 168, width: 328, height: 160))
        try checkEqual(f["l"], TodayLayout.Frame(x: 0, y: 336, width: 328, height: 328))
        try checkEqual(TodayLayout.boardHeight(placed, total: 328), 664)
        try checkEqual(TodayLayout.boardHeight([], total: 328), 0)
    }
    test("layoutLoneSmallStaysSquare") {
        let items: [TodayLayoutItem] = [.init(id: "a", size: .small), .init(id: "t", size: .medium)]
        let placed = TodayLayout.place(items, present: ["a", "t"])
        try checkEqual(TodayLayout.frame(placed[0], total: 328).width, 160)
    }
    test("layoutCardAtPoint") {
        let items: [TodayLayoutItem] = [.init(id: "a", size: .small), .init(id: "b", size: .small), .init(id: "t", size: .medium)]
        let placed = TodayLayout.place(items, present: Set(items.map(\.id)))
        try checkEqual(TodayLayout.cardAt(placed, x: 10, y: 10, total: 328), "a")
        try checkEqual(TodayLayout.cardAt(placed, x: 200, y: 150, total: 328), "b")
        try checkEqual(TodayLayout.cardAt(placed, x: 163, y: 80, total: 328), "a")   // 缝的左半边算左边那张
        try checkEqual(TodayLayout.cardAt(placed, x: 300, y: 200, total: 328), "t")
        try checkEqual(TodayLayout.cardAt(placed, x: 100, y: 900, total: 328), nil)
    }
}
