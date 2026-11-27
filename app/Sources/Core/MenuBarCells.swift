import Foundation

struct MenuBarCell: Equatable {
    var id: ProviderID
    enum Kind: Equatable {
        case quota(session: Double?, weekly: Double?, pace: Double?)
        case payg(runwayFraction: Double?, todayFraction: Double?, balanceText: String?)
    }
    var kind: Kind
    var severity: QuotaLevel.Severity?
    var stale: Bool
    var exhausted: Bool
    var name: String = ""
    var sessionReset: Date? = nil
    var weeklyReset: Date? = nil
    var sessionCountdown: String? = nil
    var weeklyCountdown: String? = nil
    var runwayDays: Double? = nil
    /// 5 小时或每周窗口用完（整个平台用不了；单模型窗口不算）：数字写 0%，不写另一个窗口的余量
    var blocked: Bool = false
    /// 金额是 API Key 的剩余花费上限（OpenRouter）：悬停写「Key 剩余额度」
    var keyLimit: Bool = false

    var loginHint: String? = nil

    var primaryText: String {
        if loginHint != nil { return L("menu.needsLogin") }
        switch kind {
        case .quota(let session, let weekly, _): return quotaRemainingPercent(blocked ? 0 : session ?? weekly)
        case .payg(_, _, let balance): return balance ?? "—"
        }
    }
}

enum MenuBarCells {
    /// Claude / Gemini 套餐（外部 CLI / 网页登录）凭据失效时的提示文案；其余平台或正常状态返回 nil。
    static func quotaLoginHint(for s: AppData.Side) -> String? {
        guard AppDataMapping.isCredentialProblem(s.status),
              let id = ProviderID(rawValue: s.id),
              id == .claudePlan || id == .geminiPlan else { return nil }
        return s.quotaNote ?? L(id == .geminiPlan ? "gemini.cli.needsLogin" : "cli.needsLogin")
    }

    static func isStale(_ st: PlatformState, now: Date) -> Bool {
        switch st.status {
        case .offline, .credentialInvalid, .keychainUnreadable, .schemaChanged, .rateLimited, .loading, .notAdded, .hidden: return true
        case .stale: return true
        default: break
        }
        if ProviderRegistry.meter(st.id) == .quota { return st.quotaTooOld(now: now) }
        return st.snapshotFromDisk || (st.snapshot.map { now.timeIntervalSince($0.fetchedAt) > 600 } ?? true)
    }

    static func cells(_ d: AppData, main: ProviderID?, lowAlerts: [ProviderID: Double] = [:],
                      staleIDs: Set<ProviderID> = [], now: Date = Date()) -> [MenuBarCell] {
        var sides = d.sides
        if let main {
            var s = AppData.Side(id: main.rawValue, name: ProviderRegistry.displayName(main), tank: d.balance.cny,
                                 currency: d.balance.currency ?? "CNY", todayCost: d.today.known ? d.today.costCny : nil,
                                 status: L("side.ok"), quotaStale: d.quota?.stale ?? false, quotaRows: d.quota?.rows ?? [],
                                 runwayDays: d.burn?.runwayDays, avgCnyPerDayWeek: d.burn?.avgCnyPerDayWeek,
                                 dataStale: d.balance.status != "可用" || (d.balance.ageS ?? 0) > 600)
            if ProviderRegistry.meter(main) == .quota { s.dataStale = d.balance.status != "可用" }
            // 主格按原逻辑构造；Claude / Gemini 套餐登录失效时，从主卡片补上状态和登录提示（菜单栏写「需登录」）
            if (main == .claudePlan || main == .geminiPlan), let m = d.mainCardSide, AppDataMapping.isCredentialProblem(m.status) {
                s.status = m.status
                s.quotaNote = m.quotaNote
            }
            s.tankIsKeyLimit = d.mainCardSide?.tankIsKeyLimit ?? false
            sides.removeAll { $0.id == main.rawValue }
            sides.insert(s, at: 0)
        }
        return sides.compactMap { s in
            guard let id = ProviderID(rawValue: s.id), s.status != L("side.notAdded") else { return nil }
            let stale = s.dataStale || s.quotaStale || staleIDs.contains(id)
            if ProviderRegistry.meter(id) == .quota {
                func key(_ r: AppData.QuotaRow) -> String {
                    // windowKind 为 nil 时按本地化名反推：仅兼容旧缓存
                    r.windowKind ?? (r.id == L("quota.window.session") ? "session" : r.id == L("quota.window.weekly") ? "weekly" : r.id)
                }
                func remaining(_ row: AppData.QuotaRow?) -> Double? { row?.remaining(at: now) }
                let session = s.quotaRows.first { key($0) == "session" }
                let weekly = s.quotaRows.filter { key($0) == "weekly" || key($0).hasPrefix("weeklyModel:") }
                    .min { (remaining($0) ?? 100) < (remaining($1) ?? 100) }
                let left = s.quotaRows.compactMap { remaining($0) }.min()
                let exhausted = QuotaText.isExhausted(remaining: left)
                let blocked = s.quotaRows.contains { ["session", "weekly"].contains(key($0)) && QuotaText.isExhausted(remaining: remaining($0)) }
                let severity = left.map { QuotaLevel.severity(usedPercent: 100 - $0) }
                return MenuBarCell(id: id, kind: .quota(session: remaining(session), weekly: remaining(weekly),
                                                       pace: session?.paceRemainingPercent),
                                   severity: severity == .ok ? nil : severity, stale: stale, exhausted: exhausted, name: s.name,
                                   sessionReset: session?.resetsAt, weeklyReset: weekly?.resetsAt,
                                   sessionCountdown: session?.isReset == true ? nil : session?.countdown,
                                   weeklyCountdown: weekly?.isReset == true ? nil : weekly?.countdown, blocked: blocked,
                                   loginHint: quotaLoginHint(for: s))
            }
            func fraction(_ value: Double?) -> Double? {
                guard let value, value.isFinite else { return nil }
                return max(0, min(1, value))
            }
            let today = s.todayCost.flatMap { cost in s.avgCnyPerDayWeek.flatMap { $0 > 0 ? fraction(cost / $0) : nil } }
            // 新样式按需求将现有 12 小时风险线标红；不改变经典 Runway 的 2 小时分级。
            let danger = s.tank == 0 || s.runwayDays.map { $0 * 24 < Runway.warnHours } == true
            let low = s.tank.map { $0 < (lowAlerts[id] ?? 0) } ?? false
            return MenuBarCell(id: id, kind: .payg(runwayFraction: fraction(s.runwayDays.map { $0 / 7 }), todayFraction: today,
                                                  balanceText: s.tank.map { fmtMoney($0, s.currency) }),
                               severity: danger ? .danger : low ? .warn : nil, stale: stale, exhausted: s.tank == 0,
                               name: s.name, runwayDays: s.runwayDays, keyLimit: s.tankIsKeyLimit)
        }
    }

    static func tooltip(_ cells: [MenuBarCell], now: Date) -> String {
        cells.map { c in
            let name = c.name.isEmpty ? ProviderRegistry.displayName(c.id) : c.name
            if let hint = c.loginHint { return name + " " + hint }
            var text: String
            switch c.kind {
            case .quota(let session, let weekly, _):
                func reset(_ date: Date?, _ fallback: String?) -> String {
                    let value = date.map { QuotaText.countdown(to: $0, now: now) } ?? fallback
                    return value.map { L("mb.tip.reset", $0) } ?? ""
                }
                var parts: [String] = []
                if let session { parts.append(L("mb.tip.session", quotaRemainingPercent(session), reset(c.sessionReset, c.sessionCountdown))) }
                if let weekly { parts.append(L("mb.tip.weekly", quotaRemainingPercent(weekly), reset(c.weeklyReset, c.weeklyCountdown))) }
                text = parts.isEmpty ? L("menuText.quotaUnknown", name) : name + " " + parts.joined(separator: L("mb.tip.join"))
            case .payg(_, _, let balance):
                text = L(c.keyLimit ? "mb.tip.keyLimit" : "mb.tip.balance", name, balance ?? "—")
                if let days = c.runwayDays, days.isFinite { text += Runway.paygDays(days, days: "mb.tip.runway", hours: "mb.tip.runwayHours", underHour: "mb.tip.runwayUnderHour") }
            }
            return text + (c.stale ? L("mb.tip.stale") : "")
        }.joined(separator: " · ")
    }
}

struct MenuBarSlots: Equatable {
    /// 用户 2026-11-13：main 是左组（单组时唯一一组），secondary 是右组，与面板主平台无关。
    var main: MenuBarCell?
    var secondary: MenuBarCell?
    var mainRunning: Bool
    var secondaryRunning: Bool
}

enum MenuBarTaskDot: Equatable { case none, running, stale }

enum MenuBarSecondary {
    /// 任务收轮（从正在跑列表消失）后，再停留这么久再淡出（用户 2026-11-13 沿用）。
    static let idleAfter: TimeInterval = 60
    static let rotate: TimeInterval = 5
    /// 本机 Agent 日志能识别任务的套餐平台；按量平台另用 UsageStore 的活动集合。
    /// 须与 RunningTasks 生成 RunningTask 的 provider 保持一致
    static func canRun(_ id: ProviderID) -> Bool { id == .claudePlan || id == .codexPlan || id == .geminiPlan }

    static func shouldAnimate(from previous: [ProviderID], to current: [ProviderID]) -> Bool {
        previous != current
    }

    static func nextRotation(after now: Date) -> Date {
        Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / rotate) + 1) * rotate)
    }

    static func dot(for id: ProviderID, tasks: [RunningTask], now: Date) -> MenuBarTaskDot {
        let matching = tasks.filter { $0.provider == id }
        guard !matching.isEmpty else { return .none }
        return matching.contains { !RunningTaskText.isStale($0, now: now) } ? .running : .stale
    }
}


enum MenuBarSlotMode: String { case single, double }

/// 用户 2026-11-13：面板顺序决定锚点、活跃平台优先级和左右位置；菜单栏不再使用常用平台或轮流。
struct MenuBarSelection {
    var slots: MenuBarSlots
    var lastActivity: [ProviderID: Date]
    var shouldRotate: Bool
    var expiresAt: Date?

    static func select(cells: [MenuBarCell], order: [ProviderID], paygActive: Set<ProviderID>,
                       tasks: [RunningTask], showRunning: Bool, mode: MenuBarSlotMode,
                       lastActivity: [ProviderID: Date], now: Date) -> MenuBarSelection {
        let added = Set(cells.map(\.id))
        var seen = Set<ProviderID>()
        let ordered = order.filter { added.contains($0) && seen.insert($0).inserted }
        var history = lastActivity.filter { added.contains($0.key) && MenuBarSecondary.canRun($0.key) }
        // 用户 2026-11-27：只有还在写日志的任务才算在跑；超过 5 分钟没动静（面板写「已停」）的不算，
        // 否则停下的会话会在列表里再挂 30 分钟，一直占着菜单栏一格
        let live = Set(tasks.filter { !RunningTaskText.isStale($0, now: now) }.map(\.provider))
            .filter { added.contains($0) && MenuBarSecondary.canRun($0) }
        // 有任务就在本轮续期；StoreBridge / 菜单栏在任务消失时记录收轮时间，沿用 60 秒停留。
        for id in live { history[id] = max(history[id] ?? now, now) }
        let retained = Set(history.filter { now < $0.value.addingTimeInterval(MenuBarSecondary.idleAfter) }.map(\.key))
        let active = ordered.filter { id in
            MenuBarSecondary.canRun(id) ? live.contains(id) || retained.contains(id)
                : ProviderRegistry.meter(id) != .quota && paygActive.contains(id)
        }
        // 用户 2026-11-27：谁在跑显示谁；并排模式两个以上在跑才显示两个（左右按面板顺序），
        // 只有一个在跑就只显示它，不再陪着面板第一个平台；都没在跑时显示面板第一个
        var displayed = Array(ordered.prefix(1))
        if showRunning, !active.isEmpty {
            displayed = Array(active.prefix(mode == .double ? 2 : 1))
        }
        let selected = displayed.compactMap { id in cells.first { $0.id == id } }
        func running(_ cell: MenuBarCell?) -> Bool {
            cell.map { MenuBarSecondary.dot(for: $0.id, tasks: tasks, now: now) == .running } ?? false
        }
        let left = selected.first
        let right = selected.count > 1 ? selected[1] : nil
        // 即使还有其他任务在跑，也要按时重新选择已收轮的平台；未显示候选到期也可安全重算。
        let expiry = showRunning ? ordered.filter { retained.contains($0) && !live.contains($0) }
            .compactMap { history[$0]?.addingTimeInterval(MenuBarSecondary.idleAfter) }.min() : nil
        return Self(slots: MenuBarSlots(main: left, secondary: right,
                                      mainRunning: running(left), secondaryRunning: running(right)),
                    lastActivity: history, shouldRotate: false, expiresAt: expiry)
    }
}
