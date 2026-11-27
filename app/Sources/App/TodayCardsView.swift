import SwiftUI

/// 固定格子：小 = 正方形，中 = 两格宽一格高，大 = 2×2；卡片大小不随内容变（内容按格子取舍）。
private struct TodayBoardLayout: Layout {
    let placements: [TodayLayout.Placement]
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 432
        return .init(width: width, height: TodayLayout.boardHeight(placements, total: Double(width)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            let f = TodayLayout.frame(placements[index], total: Double(bounds.width))
            subview.place(at: .init(x: bounds.minX + f.x, y: bounds.minY + f.y), anchor: .topLeading,
                          proposal: .init(width: f.width, height: f.height))
        }
    }
}

struct TodayGrid: View {
    @ObservedObject var model: UsageModel
    let d: AppData
    let p: Palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging: String?
    @State private var dragOffset: CGSize = .zero
    @State private var boardWidth: CGFloat = 0
    @State private var resizing: String?
    @State private var showAllRunning = false
    /// 近 7 天卡（中号）「另 N 个模型」点开的全部模型
    @State private var showAllModels = false
    @State private var escapeMonitor: Any?

    /// 换位 / 拉伸 / 重排共用的动画：减弱动态效果时只淡入淡出
    private var boardAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.32, dampingFraction: 0.86)
    }

    var body: some View {
        let now = model.fixedNow ?? Date()
        let cards = TodayCards.build(d, running: model.runningTasks, now: now,
                                     recentAgents: model.fixedNow == nil ? model.recentRunningAgents : nil,
                                     paygActive: model.menuBarPaygActive)
        let placements = TodayLayout.place(model.resolvedTodayLayout, present: Set(cards.map(\.id)))
        ZStack {
        TodayBoardLayout(placements: placements) {
            ForEach(placements, id: \.id) { placement in
                if let card = cards.first(where: { $0.id == placement.id }) {
                    editableCell(card, size: placement.size, reserveRisk: TodayCards.needsRiskRow(id: card.id, cards: cards, placements: placements), placements: placements)
                }
            }
        }
        .coordinateSpace(name: "todayBoard")
        .background(GeometryReader { g in
            Color.clear.onAppear { boardWidth = g.size.width }.onChange(of: g.size.width) { boardWidth = g.size.width }
        })
        .id(reduceMotion ? placements.map { "\($0.id):\($0.size.rawValue):\($0.row):\($0.column)" }.joined(separator: ",") : "board")
        .transition(.opacity)
        }
        .animation(boardAnimation, value: placements)
        .onAppear {
            model.reconcileTodayLayout()
            if escapeMonitor == nil {
                escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.keyCode == 53 && model.todayEditing {
                        model.todayEditing = false
                        return nil
                    }
                    return event
                }
            }
        }
        .onDisappear {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil; model.todayEditing = false; dragging = nil; dragOffset = .zero
        }
        .onChange(of: model.todayEditing) { dragging = nil; dragOffset = .zero }
        .onChange(of: model.todayPlatformIDs) { model.reconcileTodayLayout() }
    }

    @ViewBuilder private func editableCell(_ card: TodayCard, size: TodayCardSize, reserveRisk: Bool,
                                           placements: [TodayLayout.Placement]) -> some View {
        if kRendering {
            decoratedCell(card, size: size, reserveRisk: reserveRisk)
                .zIndex(model.todayResizePreview == card.id ? 10 : 0)
        } else {
            decoratedCell(card, size: size, reserveRisk: reserveRisk, placements: placements)
                .offset(dragging == card.id ? dragOffset : .zero)
                // 层级放在最外层才对网格生效：拖动中的卡最上，正在拉伸的卡其次（虚线框不被邻卡挡住）
                .zIndex(dragging == card.id ? 30 : resizing == card.id ? 10 : 0)
                .contextMenu { cardMenu(card, size: size) }
        }
    }

    /// start：按下点在卡片里的位置；delta：拖动位移。换算成网格坐标后看落在哪张卡上
    private func finishDrag(_ id: String, start: CGPoint, delta: CGSize, placements: [TodayLayout.Placement]) {
        let animation = boardAnimation
        var target: String?
        if let placement = placements.first(where: { $0.id == id }) {
            let origin = TodayLayout.frame(placement, total: Double(boardWidth))
            target = TodayLayout.cardAt(placements, x: origin.x + Double(start.x + delta.width),
                                        y: origin.y + Double(start.y + delta.height), total: Double(boardWidth))
        }
        logLine("今天卡片：拖动 \(id) 松手，落在 \(target ?? "空白")，位移 \(Int(delta.width)),\(Int(delta.height))，格宽 \(Int(boardWidth))")
        withAnimation(animation) {
            if let target, target != id, let index = model.resolvedTodayLayout.firstIndex(where: { $0.id == target }) {
                model.setTodayLayout(TodayLayout.move(model.resolvedTodayLayout, id: id, to: index))
            }
            dragging = nil; dragOffset = .zero
        }
    }

    private func decoratedCell(_ card: TodayCard, size: TodayCardSize, reserveRisk: Bool,
                               placements: [TodayLayout.Placement] = []) -> some View {
        cell(card, size: size, reserveRisk: reserveRisk)
            // 格子大小固定：内容放不下的部分裁掉（各卡已按大小取舍内容）
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                // 编辑模式：整张卡盖一层 AppKit 视图接鼠标，按住拖到别的卡上就换位置。
                // 真机上用 SwiftUI 的 DragGesture 拖不动（用户反馈），所以和拉伸把手一样用 NSView 接鼠标。
                if model.todayEditing && !kRendering {
                    TodayMouseGrab(cursor: .openHand, dragCursor: .closedHand,
                                   onChanged: { _, delta in
                                       if dragging != card.id { dragging = card.id; logLine("今天卡片：开始拖动 \(card.id)") }
                                       dragOffset = delta
                                   },
                                   onEnded: { start, delta in
                                       guard model.todayEditing else { dragging = nil; dragOffset = .zero; return }
                                       finishDrag(card.id, start: start, delta: delta, placements: placements)
                                   })
                }
            }
            .modifier(TodayResizeHandle(size: size, allowed: card.kind == .trend ? [.medium, .large] : Set(TodayCardSize.allCases), editing: model.todayEditing, preview: kRendering && model.todayResizePreview == card.id, p: p, onResize: { resize(card.id, $0) },
                                        onActive: { active in resizing = active ? card.id : (resizing == card.id ? nil : resizing) }))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                if model.todayEditing {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(p.sub.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .modifier(TodayWobble(active: model.todayEditing && !reduceMotion && !kRendering))
            .accessibilityActions {
                ForEach(TodayCardSize.allCases, id: \.rawValue) { value in
                    Button(L("today.size") + " " + value.title) { resize(card.id, value) }
                        .disabled(card.kind == .trend && value == .small)
                }
                Button(L("today.front")) { model.setTodayLayout(TodayLayout.moveToFront(model.resolvedTodayLayout, id: card.id)) }
                Button(L("today.end")) { model.setTodayLayout(TodayLayout.moveToEnd(model.resolvedTodayLayout, id: card.id)) }
                Button(L("today.resetLayout")) { reset() }
                if card.kind == .platform, let id = card.provider {
                    Button(L("today.hide", ProviderRegistry.displayName(id))) { model.setPlatformHidden(id, true) }
                }
            }
    }

    @ViewBuilder private func cardMenu(_ card: TodayCard, size: TodayCardSize) -> some View {
        Menu(L("today.size")) {
            ForEach(TodayCardSize.allCases, id: \.rawValue) { value in
                Button { resize(card.id, value) } label: {
                    if size == value { Label(value.title, systemImage: "checkmark") }
                    else { Text(value.title) }
                }.disabled(card.kind == .trend && value == .small)
            }
        }
        Divider()
        Button(L("today.resetLayout")) { reset() }
        if card.kind == .platform, let id = card.provider {
            Divider()
            // 暂时隐藏（用户 11/6）：登录保留、不再刷新；今天页底部和「添加 / 移除平台」里可以再显示
            Button(L("today.hide", ProviderRegistry.displayName(id))) { model.setPlatformHidden(id, true) }
        }
    }
    private func resize(_ id: String, _ size: TodayCardSize) {
        guard id != "trend" || size != .small else { return }
        withAnimation(boardAnimation) {
            model.setTodayLayout(TodayLayout.resize(model.resolvedTodayLayout, id: id, to: size))
        }
    }
    private func reset() { model.setTodayLayout(TodayLayout.reset(platformIDs: model.todayPlatformIDs)) }

    @ViewBuilder private func cell(_ card: TodayCard, size: TodayCardSize, reserveRisk: Bool) -> some View {
        switch card.kind {
        case .platform: platform(card, size: size, reserveRisk: reserveRisk)
        case .spend: spendCard(card, size: size)
        case .running: runningCard(card)
        case .trend: trendCard(card, size: size)
        }
    }

    private func runningCard(_ running: TodayCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(running.title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if let activity = running.activity { RunningDot(activity: activity) }
                if let badge = running.badge {
                    Text(badge).font(.num(10, .semibold)).foregroundColor(p.text)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Accent.green.opacity(0.2)))
                }
            }
            let all = model.runningTasks
            if all.isEmpty {
                // 空状态：一句说明 + 底部小字（和平台卡的状态行 / 底注同字号）
                VStack(alignment: .leading, spacing: 0) {
                    Text(running.status ?? L("today.runningEmpty")).font(.system(size: 11)).foregroundColor(p.sub).lineLimit(2)
                    Spacer(minLength: 0)
                    runningFootnote(running)
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                // 格子多大放几条（从全部往下试），放不下就在左下角给「显示全部」
                ViewThatFits(in: .vertical) {
                    ForEach(Array((0...all.count).reversed()), id: \.self) { shown in
                        smallRunning(running, tasks: all, shown: shown)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading).todaySurface(p)
        .accessibilityElement(children: .contain)
        // 挂在整张卡上（不挂在会随任务数重建的按钮上），任务数变化时弹窗不会自己关掉
        .modifier(RunningAllPopover(show: $showAllRunning, model: model, p: p))
        // 没任务时卡片还在（空状态）：任务全结束就收起「显示全部」，不留一个空列表
        .onChange(of: model.runningTasks.isEmpty) { _, empty in if empty { showAllRunning = false } }
    }

    private func runningFootnote(_ running: TodayCard) -> some View {
        Text(running.footnote ?? "").font(.system(size: 10)).foregroundColor(p.sub).lineLimit(1).minimumScaleFactor(0.7)
    }

    private func smallRunning(_ running: TodayCard, tasks: [RunningTask], shown: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RunningTasksSection(tasks: tasks, fixedNow: model.fixedNow, p: p, compact: true,
                                showHeader: false, limit: shown, showMore: false, detailLines: 1, shortClock: true)
            Spacer(minLength: 0)
            if shown < tasks.count {
                showAllButton(count: tasks.count)
            } else {
                runningFootnote(running)
            }
        }
    }

    @ViewBuilder private func showAllButton(count: Int) -> some View {
        let label = Text(L("today.showAll", count)).font(.system(size: 11, weight: .medium)).foregroundColor(Accent.blue)
        if kRendering {
            label
        } else {
            Button { if !model.todayEditing { showAllRunning = true } } label: { label }
                .buttonStyle(.plain)
        }
    }

    private func trendCard(_ trend: TodayCard, size: TodayCardSize) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let chart = detail(trend, size: size).chart {
                // 放得下就带模型图例（大号再加选中那天的明细），放不下就只留柱子
                ViewThatFits(in: .vertical) {
                    if size == .large {
                        VStack(alignment: .leading, spacing: 8) {
                            trendStrip(chart, legend: true)
                            detailRows(TodayCards.dayDetail(d, iso: model.trendPick))
                        }
                    }
                    // 中号（用户 2026-11-06 选丁）：不写「今天合计」，模型尽量多列，列不完最后一行写「另 N 个模型」
                    ForEach(size == .medium ? [Int.max, 4, 3, 2, 1, 0] : [Int.max, 3, 2, 1, 0], id: \.self) { rows in
                        trendStrip(chart, legend: true, rows: rows, compact: size == .medium)
                    }
                    trendStrip(chart, legend: false)
                }
            } else if !BalanceEstimatePresentation.showsTokenTrend(d) {
                Text(L("common.noData")).font(.system(size: 12)).foregroundColor(p.sub)
            }
        }
            .frame(maxHeight: .infinity, alignment: .topLeading).todaySurface(p)
            .accessibilityElement(children: .contain)
            // 挂在整张卡上：ViewThatFits 里几种行数的图各自重建，挂在行上弹窗会跟着消失
            .modifier(TrendAllModelsPopover(show: $showAllModels, chart: detail(trend, size: size).chart,
                                            picked: model.trendPick, p: p))
            .onChange(of: model.todayEditing) { _, editing in if editing { showAllModels = false } }
            .accessibilityActions {
                if !model.todayEditing && BalanceEstimatePresentation.showsTokenTrend(d) {
                    ForEach(d.tokenChart(main: d.mainProvider).bars, id: \.iso) { bar in
                        Button(A11yText.openDayDetail(iso: bar.iso)) {
                            model.pickTrendDay(bar.iso)
                            if let day = d.trend7.first(where: { $0.iso == bar.iso }) { model.openDetail(day) }
                        }
                    }
                }
            }
    }

    private func trendStrip(_ chart: TokenChart, legend: Bool, rows: Int = .max, compact: Bool = false) -> some View {
        TrendStrip(chart: chart, days: d.trend7,
                   onPick: { if !model.todayEditing { model.openDetail($0) } },
                   p: p, incomplete: d.trendIncomplete, picked: model.trendPick,
                   onSelect: { if !model.todayEditing { model.pickTrendDay($0) } }, showLegend: legend, legendRows: rows,
                   compact: compact,
                   onShowAllModels: compact ? { if !model.todayEditing { showAllModels = true } } : nil)
            .allowsHitTesting(!model.todayEditing)
    }

    private func platform(_ card: TodayCard, size: TodayCardSize, reserveRisk: Bool) -> some View {
        let summary = Button { if !model.todayEditing, let id = card.provider { model.showPanelDetail(id) } } label: {
            TodayPlatformCard(card: card, p: p, compact: false,
                              reserveRiskLine: reserveRisk, includesSurface: false, now: model.fixedNow ?? Date())
        }.buttonStyle(.plain)
            .accessibilityLabel(card.a11y)
        return Group {
            switch size {
            case .small:
                summary
            case .medium:
                // 两格宽：左边是小号的内容，右边放明细
                HStack(alignment: .top, spacing: 14) {
                    summary.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    fitDetail(detail(card, size: size)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            case .large:
                VStack(alignment: .leading, spacing: 12) {
                    summary.fixedSize(horizontal: false, vertical: true)
                    fitDetail(detail(card, size: size)).frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .todaySurface(p)
        .helpIfPresent(card.dimmed ? StaleTime.help(card.lastUpdated, now: model.fixedNow ?? Date()) : nil)
        .accessibilityElement(children: .combine)
    }

    private func spendCard(_ card: TodayCard, size: TodayCardSize) -> some View {
        let summary = VStack(alignment: .leading, spacing: 9) {
            Text(card.title).font(.system(size: 12, weight: .semibold))
            if card.spendEmpty {
                Text(L("common.noData")).font(.system(size: 12)).foregroundColor(p.sub)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    spendColumn(L("today.paid"), card.spendCash)
                    spendColumn(L("today.apiLabel"), card.spendAPI)
                }
                if let change = card.spendChange { spendChangeLine(change) }
                ForEach(Array(card.lines.dropFirst().enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11)).foregroundColor(p.sub).lineLimit(1).minimumScaleFactor(0.7)
                }
                if let note = card.spendNote {
                    Text(note).font(.system(size: 11)).foregroundColor(p.sub).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        return VStack(alignment: .leading, spacing: 9) {
            switch size {
            case .small:
                summary
            case .medium:
                HStack(alignment: .top, spacing: 14) {
                    summary.frame(maxWidth: .infinity, alignment: .topLeading)
                    fitDetail(detail(card, size: size)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            case .large:
                summary
                fitDetail(detail(card, size: size)).frame(maxHeight: .infinity, alignment: .topLeading)
            }
            Spacer(minLength: 0)
            if !card.spendEmpty && !card.segments.isEmpty {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(card.segments) { segment in
                            Color(nsColor: PlatformColor.color(segment.id)).frame(width: geometry.size.width * segment.fraction)
                        }
                    }.clipShape(Capsule())
                }.frame(height: 7).accessibilityHidden(true)
            }
        }.frame(maxHeight: .infinity, alignment: .topLeading).todaySurface(p)
        .accessibilityElement(children: .combine)
    }

    private func spendChangeLine(_ change: SpendComparison.Change) -> some View {
        let symbol: String?
        let tint: Color
        switch change {
        case .increase, .increaseAmount: (symbol, tint) = ("arrow.up.right", p.warnText)
        case .decrease, .decreaseAmount: (symbol, tint) = ("arrow.down.right", Accent.green)
        case .steady: (symbol, tint) = ("minus", p.sub)
        case .zeroYesterday: (symbol, tint) = (nil, p.sub)
        }
        return HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).fixedSize().accessibilityHidden(true) }
            Text(change.text).lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityLabel(change.a11y)
        }
        .font(.system(size: 11)).foregroundColor(tint)
    }

    /// 明细按格子剩下的高度取舍：全部 → 去掉图 → 只留数字行 → 只留前几行
    private func fitDetail(_ full: TodayCardDetail) -> some View {
        var noCharts = full
        noCharts.sparkline = []; noCharts.bars = []
        var rowsOnly = noCharts
        rowsOnly.models = []; rowsOnly.more = nil; rowsOnly.tasks = []
        let all = rowsOnly.rows
        // 放不下全部时先保住图：依次去掉任务行、模型行，再去掉图
        var noTasks = full
        noTasks.tasks = []
        var chartAndRows = noTasks
        chartAndRows.models = []; chartAndRows.more = nil
        var lineOnly = noTasks
        if !lineOnly.sparkline.isEmpty { lineOnly.bars = [] }   // 折线和柱子是同一组数，只留矮的折线
        return ViewThatFits(in: .vertical) {
            detailContent(full)
            detailContent(noTasks)
            detailContent(lineOnly)
            detailContent(chartAndRows)
            detailContent(noCharts)
            ForEach(Array((0...all.count).reversed()), id: \.self) { n in
                detailRows(Array(all.prefix(n)))
            }
        }
    }

    private func detail(_ card: TodayCard, size: TodayCardSize) -> TodayCardDetail {
        TodayCards.detail(card, size: size, data: d, running: model.runningTasks, now: model.fixedNow ?? Date())
    }
    private func detailRows(_ rows: [TodayCardDetail.Row]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(spacing: 5) {
                    if let provider = row.provider {
                        Circle().fill(Color(nsColor: PlatformColor.color(provider))).frame(width: 5, height: 5).accessibilityHidden(true)
                    }
                    Text(row.label).font(.system(size: 11)).foregroundColor(p.sub)
                    Spacer(minLength: 4)
                    Text(row.value).font(.num(11, .regular)).foregroundColor(p.text).layoutPriority(1)
                }.lineLimit(1).truncationMode(.tail)
                    // Keep 11pt: a parent VStack must not trade these rows' height for a Spacer.
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }
        }
    }
    private func detailContent(_ detail: TodayCardDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            detailRows(detail.rows)
            if !detail.sparkline.isEmpty {
                TodayDetailChart(bars: detail.sparkline, title: detail.chartTitle, line: true, p: p)
            }
            if !detail.bars.isEmpty {
                TodayDetailChart(bars: detail.bars, title: detail.chartTitle, line: false, p: p)
            }
            detailRows(detail.models)
            if let more = detail.more { Text(more).font(.system(size: 11)).foregroundColor(p.sub) }
            detailRows(detail.tasks)
        }
    }
    private func spendColumn(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 10)).foregroundColor(p.sub).lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(.num(16, .semibold)).foregroundColor(p.text).lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TodayPlatformCard: View {
    let card: TodayCard
    let p: Palette
    let compact: Bool
    var reserveRiskLine = true
    var includesSurface = true
    var now = Date()
    private var tint: Color { card.provider.map { Color(nsColor: PlatformColor.color($0)) } ?? p.sub }
    private var updateHelp: String? { card.dimmed ? StaleTime.help(card.lastUpdated, now: now) : nil }

    var body: some View {
        Group {
            if includesSurface {
                content.todaySurface(p, padding: compact ? 10 : 12)
            } else {
                content.foregroundColor(p.text)
            }
        }
        .opacity(card.dimmed && card.loginHint == nil ? 0.55 : 1)
        .helpIfPresent(includesSurface ? updateHelp : nil)
    }

    private var reminderTint: Color {
        riskTint(card.riskSeverity, ok: (card.footnoteWarn || card.runwayWarn || card.stateWarn) ? p.warnText : p.sub, p: p)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(spacing: 4) {
                if let id = card.provider {
                    Image(nsImage: PlatformGlyph.image(id, size: compact ? 12 : 14, tint: nil))
                        .renderingMode(.template).foregroundColor(!compact && (card.footnoteWarn || card.runwayWarn || card.stateWarn || card.hintWarn) ? reminderTint : tint)
                }
                Text(card.title).font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: false)
                Spacer(minLength: 0)
                if let activity = card.activity { RunningDot(activity: activity) }
                if !compact {
                    if let badge = card.badge {
                        Text(badge).font(.system(size: 10, weight: .medium)).foregroundColor(tint)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 5).padding(.vertical, 2).background(Capsule().fill(tint.opacity(0.2)))
                    }
                }
            }
            // Reserve the same header height with or without a badge/runway chip.
            .frame(height: compact ? 14 : 20)
            if !compact && reserveRiskLine && card.loginHint == nil {
                AlertLine(glyph: card.stateGlyph, iconSize: 11) {
                    Text(card.status ?? card.stateLine ?? card.runwayChip ?? " ")
                        .lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 11)).foregroundColor(reminderTint)
                .frame(height: 12, alignment: .leading).helpIfPresent(updateHelp)
            }
            if let hint = card.loginHint {
                // 登录失效：先写旧读数（不带倒计时，最多两行），再写橙色的登录指引；整卡不灰显，免得指引读不清。
                if let old = card.loginOldQuota {
                    Text(old).font(.system(size: 11)).foregroundColor(p.sub)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                let size: CGFloat = compact ? 10 : 11
                AlertLine(glyph: card.stateGlyph, iconSize: size) {
                    Text(hint).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: size)).foregroundColor(p.warnText)
                Spacer(minLength: 0)
            } else if compact {
                Text(card.compactValue).font(.num(17, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                if let remaining = card.compactRemaining {
                    PaceBar(remaining: remaining, pace: card.compactPace, tint: tint, track: p.track, height: 4)
                } else {
                    Text(card.compactDetail).font(.system(size: 10)).foregroundColor(p.sub).lineLimit(1)
                }
            } else {
                if !card.value.isEmpty {
                    Text(card.value).font(.num(28, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                }
                ForEach(card.windows) { window in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 3) {
                            Text(window.title).font(.system(size: 10)).foregroundColor(p.sub)
                            Spacer(minLength: 0)
                            Text(window.value).font(.num(10, .medium)).foregroundColor(p.text)
                        }.lineLimit(1).minimumScaleFactor(0.7)
                        PaceBar(remaining: window.remaining, pace: window.pace,
                                tint: card.dimmed ? p.sub.opacity(0.5) : quotaTint(window.severity), track: p.track, height: 7)
                    }.layoutPriority(1)   // 读数先排，底注不跟它抢高度
                }
                if !card.stats.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(card.stats.enumerated()), id: \.offset) { _, stat in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(stat.label).font(.system(size: 10)).foregroundColor(p.sub)
                                Text(stat.value).font(.num(13, .semibold)).foregroundColor(p.text)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                // 套餐卡（两个窗口）加底注后约 138pt，小卡内容区约 131pt：Spacer 两侧的行距共 20pt，
                // 底注往上收 14pt（与进度条至少留 4pt），窗口文字才不会被缩小
                Spacer(minLength: 0)
                if let note = TodayCards.bottomNote(card) {
                    AlertLine(glyph: card.footnoteGlyph, iconSize: 10) {
                        Text(note).lineLimit(card.footnoteMultiline ? 4 : 1).truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 10)).foregroundColor(card.footnoteWarn ? reminderTint : p.sub)
                    .helpIfPresent(updateHelp).padding(.top, card.windows.isEmpty ? 0 : -14)
                } else if let hint = card.hint {
                    // 本周预测：用完提示用提醒橙（不跟着会话「已用完」的红）。
                    AlertLine(glyph: AlertGlyph.level(warn: card.hintWarn), iconSize: 10) {
                        Text(hint).lineLimit(1).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 10)).foregroundColor(card.hintWarn ? p.warnText : p.sub)
                    .padding(.top, -14)
                }
            }
        }
        .frame(minHeight: compact ? 70 : 114, alignment: .topLeading)
        .frame(maxHeight: compact ? nil : .infinity, alignment: .topLeading)
    }
}

/// Widget-only presentation; the existing compact cards keep their original layout.
private struct WidgetPlatformCard: View {
    let card: TodayCard
    let p: Palette
    let now: Date
    private var tint: Color { card.provider.map { Color(nsColor: PlatformColor.color($0)) } ?? p.sub }
    private var updateHelp: String? { card.dimmed ? StaleTime.help(card.lastUpdated, now: now) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if let id = card.provider {
                    Image(nsImage: PlatformGlyph.image(id, size: 12, tint: nil))
                        .renderingMode(.template).foregroundColor(tint)
                }
                Text(card.title).font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }.frame(height: 14)
            if !card.windows.isEmpty {
                ForEach(card.windows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 2) {
                            Text(window.shortTitle.isEmpty ? window.title : window.shortTitle).foregroundColor(p.sub)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                            Text(window.isReset ? L("quota.windowResetShort") : quotaRemainingPercent(window.remaining))
                                .foregroundColor(window.severity == .ok ? p.text : quotaTint(window.severity)).fixedSize()
                        }.font(.num(10))
                        PaceBar(remaining: window.remaining, pace: window.pace,
                                tint: quotaTint(window.severity), track: p.track, height: 4)
                    }
                }
            } else {
                Text(card.compactValue).font(.num(18, .semibold)).lineLimit(1).truncationMode(.tail)
                AlertLine(glyph: card.compactDetail.isEmpty ? card.footnoteGlyph : .none, iconSize: 10) {
                    Text(card.compactDetail.isEmpty ? (card.footnote ?? "") : card.compactDetail)
                        .lineLimit(1).truncationMode(.tail)
                }
                .font(.num(10)).foregroundColor(p.sub).helpIfPresent(updateHelp)
                if let runway = card.runwayChip {
                    let glyph = AlertGlyph.level(riskSeverity: card.runwayWarn ? card.riskSeverity : nil, warn: card.runwayWarn)
                    AlertLine(glyph: glyph, iconSize: 10) {
                        Text(runway).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: 10))
                    .foregroundColor(card.runwayWarn ? riskTint(card.riskSeverity, ok: p.warnText, p: p) : p.sub)
                }
            }
        }
        // 108pt per card including padding: two rows + gap = 224pt, within 244pt.
        .frame(height: 90, alignment: .topLeading)
        .todaySurface(p, padding: 9)
        .opacity(card.dimmed ? 0.55 : 1)
        .helpIfPresent(updateHelp)
    }
}

struct WidgetOverview: View {
    @ObservedObject var model: UsageModel
    let d: AppData
    let p: Palette
    var body: some View {
        let now = model.fixedNow ?? Date()
        let cards = TodayCards.build(d, running: [], now: now).filter { $0.kind == .platform }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(cards) { card in
                Button {
                    if let id = card.provider { model.showWidgetDetail(id) }
                } label: { WidgetPlatformCard(card: card, p: p, now: now) }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore).accessibilityLabel(card.a11y)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    func todaySurface(_ p: Palette, padding: CGFloat = 12) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading).foregroundColor(p.text)
            .background(RoundedRectangle(cornerRadius: 12).fill(p.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.border, lineWidth: 1))
    }
}

/// Same rounded narrow-bar drawing as TrendStrip; values and normalization come from Core.
private struct TodayDetailChart: View {
    let bars: [TodayCardDetail.Bar]
    let title: String
    let line: Bool
    let p: Palette
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundColor(p.sub)
            if line {
                GeometryReader { g in
                    Path { path in
                        for (index, bar) in bars.enumerated() {
                            let point = CGPoint(x: g.size.width * CGFloat(index) / CGFloat(max(1, bars.count - 1)), y: g.size.height * (1 - bar.fraction))
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                            if bars.count == 1 { path.addLine(to: CGPoint(x: point.x + 3, y: point.y)) }
                        }
                    }.stroke(p.text, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }.frame(height: 28)
            } else {
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(bars) { bar in
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(p.sub.opacity(0.45))
                                .frame(width: 14, height: max(2, 40 * bar.fraction))
                                .frame(height: 40, alignment: .bottom)
                            Text(bar.label).font(.num(11, .regular)).foregroundColor(p.sub)
                        }.frame(maxWidth: .infinity).help(bar.id + " " + bar.text)
                    }
                }
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(([title] + bars.map { $0.id + " " + $0.text }).joined(separator: L("a11y.sep")))
    }
}

private struct TodayResizeHandle: ViewModifier {
    let size: TodayCardSize
    let allowed: Set<TodayCardSize>
    let editing: Bool
    let preview: Bool
    let p: Palette
    let onResize: (TodayCardSize) -> Void
    var onActive: (Bool) -> Void = { _ in }
    @State private var translation: CGSize? = nil
    private static let cursor = NSCursor(image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)!, hotSpot: NSPoint(x: 8, y: 8))

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if editing {
                GeometryReader { g in
                    let cellWidth = size == .small ? g.size.width : CGFloat(TodayLayout.cellSide(total: Double(g.size.width)))
                    let cellHeight = size == .large ? (g.size.height - 8) / 2 : g.size.height
                    let delta = translation ?? (preview ? CGSize(width: cellWidth * 0.7, height: 0) : .zero)
                    let target = TodayLayout.snap(start: size, dx: delta.width, dy: delta.height, cellWidth: cellWidth, cellHeight: cellHeight, allowed: allowed)
                    ZStack(alignment: .topLeading) {
                        if translation != nil || preview {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(p.text.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                                .frame(width: max(40, g.size.width + delta.width), height: max(40, g.size.height + delta.height))
                                .overlay(alignment: .topTrailing) {
                                    Text(target.title).font(.system(size: 11)).foregroundColor(p.text)
                                        .padding(.horizontal, 6).padding(.vertical, 4)
                                        .background(p.card.opacity(0.85)).cornerRadius(4).padding(4)
                                }
                                .allowsHitTesting(false)
                        }
                        Group {
                            if kRendering {
                                handle
                            } else {
                                // 卡片的拖动换位（TodayMouseGrab）是 AppKit 视图，会先拿走鼠标按下；
                                // 把手用自己的 NSView 盖在最上面接鼠标，才拉得动。
                                handle.overlay(
                                    TodayResizeGrab(cursor: Self.cursor,
                                                    onChanged: { if translation == nil { onActive(true) }; translation = $0 },
                                                    onEnded: { delta in
                                                        // 拖到一半按 Esc 退出了编辑：不再改大小
                                                        guard editing else { translation = nil; onActive(false); return }
                                                        let target = TodayLayout.snap(start: size, dx: delta.width, dy: delta.height, cellWidth: cellWidth, cellHeight: cellHeight, allowed: allowed)
                                                        translation = nil; onActive(false); onResize(target)
                                                    })
                                        .frame(width: 22, height: 22))
                            }
                        }.position(x: g.size.width - 10, y: g.size.height - 10)
                    }
                }.accessibilityHidden(true)
            }
        }
        .onChange(of: editing) { if !editing && translation != nil { translation = nil; onActive(false) } }
    }
    private var handle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .semibold)).foregroundColor(p.sub)
            .frame(width: 14, height: 14).background(RoundedRectangle(cornerRadius: 4).fill(p.track))
            .contentShape(Rectangle())
    }
}

/// 右下角拉伸把手的鼠标接收层：按下后跟踪拖动，报告相对按下点的位移（SwiftUI 坐标，向下为正）。
private struct TodayResizeGrab: NSViewRepresentable {
    let cursor: NSCursor
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize) -> Void

    func makeNSView(context: Context) -> GrabView { GrabView() }
    func updateNSView(_ view: GrabView, context: Context) {
        view.cursor = cursor; view.onChanged = onChanged; view.onEnded = onEnded
        view.window?.invalidateCursorRects(for: view)
    }

    final class GrabView: NSView {
        var cursor: NSCursor = .arrow
        var onChanged: (CGSize) -> Void = { _ in }
        var onEnded: (CGSize) -> Void = { _ in }
        private var start: NSPoint?
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
        private func delta(_ event: NSEvent) -> CGSize {
            guard let start else { return .zero }
            let p = event.locationInWindow
            return CGSize(width: p.x - start.x, height: start.y - p.y)
        }
        override func mouseDown(with event: NSEvent) { start = event.locationInWindow }
        override func mouseDragged(with event: NSEvent) {
            guard start != nil else { return }
            onChanged(delta(event))
        }
        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            let d = delta(event); start = nil
            // 只是点一下（没拖）不改大小
            if abs(d.width) < 2 && abs(d.height) < 2 { onChanged(.zero); onEnded(.zero) } else { onEnded(d) }
        }
    }
}

/// 近 7 天卡「另 N 个模型」弹出的全部模型（选中的那天）；离屏渲染时不挂
private struct TrendAllModelsPopover: ViewModifier {
    @Binding var show: Bool
    let chart: TokenChart?
    let picked: String?
    let p: Palette
    @ViewBuilder func body(content: Content) -> some View {
        if kRendering {
            content
        } else {
            content.popover(isPresented: $show, arrowEdge: .bottom) {
                if let chart {
                    ScrollView {
                        TrendAllModelsList(chart: chart, bar: chart.bars.firstIndex { $0.iso == picked } ?? max(chart.bars.count - 1, 0), p: p)
                            .padding(12)
                    }
                    .frame(width: 300).frame(maxHeight: 420)
                }
            }
        }
    }
}

/// 「显示全部」弹出的完整任务列表；离屏渲染时不挂
private struct RunningAllPopover: ViewModifier {
    @Binding var show: Bool
    @ObservedObject var model: UsageModel
    let p: Palette
    @ViewBuilder func body(content: Content) -> some View {
        if kRendering {
            content
        } else {
            content.popover(isPresented: $show, arrowEdge: .bottom) {
                ScrollView {
                    RunningTasksSection(tasks: model.runningTasks, fixedNow: model.fixedNow, p: p, compact: true,
                                        showHeader: true, limit: Int.max, showMore: false)
                        .padding(12)
                }
                .frame(width: 300).frame(maxHeight: 420)
            }
        }
    }
}

/// 编辑模式里整张卡的鼠标接收层：报告按下点（卡片内、向下为正）和拖动位移；只是点一下不报告结束以外的东西。
private struct TodayMouseGrab: NSViewRepresentable {
    let cursor: NSCursor
    let dragCursor: NSCursor
    let onChanged: (CGPoint, CGSize) -> Void
    let onEnded: (CGPoint, CGSize) -> Void

    func makeNSView(context: Context) -> GrabView { GrabView() }
    func updateNSView(_ view: GrabView, context: Context) {
        view.cursor = cursor; view.dragCursor = dragCursor; view.onChanged = onChanged; view.onEnded = onEnded
        view.window?.invalidateCursorRects(for: view)
    }

    final class GrabView: NSView {
        var cursor: NSCursor = .arrow
        var dragCursor: NSCursor = .arrow
        var onChanged: (CGPoint, CGSize) -> Void = { _, _ in }
        var onEnded: (CGPoint, CGSize) -> Void = { _, _ in }
        private var startWindow: NSPoint?
        private var startLocal: CGPoint = .zero
        private var moved = false
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
        private func delta(_ event: NSEvent) -> CGSize {
            guard let startWindow else { return .zero }
            let p = event.locationInWindow
            return CGSize(width: p.x - startWindow.x, height: startWindow.y - p.y)
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // 拖到一半退出编辑（Esc / 关面板）：这层被移除时把抓手光标还回去
            if newWindow == nil { resetDrag() }
        }
        deinit { if moved { NSCursor.pop() } }
        private func resetDrag() {
            if moved { NSCursor.pop() }
            moved = false; startWindow = nil
        }
        override func mouseDown(with event: NSEvent) {
            // Ctrl + 点击 = 右键菜单，交给上层
            if event.modifierFlags.contains(.control) { super.mouseDown(with: event); return }
            startWindow = event.locationInWindow
            startLocal = convert(event.locationInWindow, from: nil)
            moved = false
        }
        override func mouseDragged(with event: NSEvent) {
            guard startWindow != nil else { return }
            let d = delta(event)
            if !moved && abs(d.width) < 3 && abs(d.height) < 3 { return }
            if !moved { moved = true; dragCursor.push() }
            onChanged(startLocal, d)
        }
        override func mouseUp(with event: NSEvent) {
            guard startWindow != nil else { return }
            let d = delta(event); startWindow = nil
            if moved { NSCursor.pop(); moved = false; onEnded(startLocal, d) }
        }
    }
}

/// 编辑模式的轻微摇摆：按当前时间算角度（±0.35°，约 0.32 秒一个来回），不用会残留的 repeatForever 动画
private struct TodayWobble: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            content.rotationEffect(.degrees(active ? 0.35 * sin(t * 2 * .pi / 0.32) : 0))
        }
    }
}
