import Combine
import Foundation

enum PlatformStatus: Equatable {
    /// 刚启动、第一次取数还没回来：不是离线，界面显示「正在连接」
    case loading
    case ok
    /// 这次没取到，显示的是 N 分钟前的数据
    case stale(minutes: Int)
    case credentialInvalid
    /// 读钥匙串出错（被拒绝 -128、锁着 -25308、授权失败等）：凭据本身可能没问题，不说「失效」
    ///（11/6 用户定 proposal-keychain-error-ui 乙）。锁着的下一轮自动再读；其余停下，等「重试」或重新登录
    case keychainUnreadable(status: Int32)
    /// API Key 正常，但控制台登录失效（只剩余额）
    case consoleLoginNeeded
    /// 接口格式变了（与登录失效分开，重新登录也没用）
    case schemaChanged
    case rateLimited(until: Date)
    /// 从没取到过数据
    case offline
    /// 还没添加这个平台（钥匙串里没有、也没添加过）
    case notAdded
    /// 用户暂时隐藏（11/6 proposal-hide-platform）：登录和「已添加」都保留，但不刷新、不提醒、不显示
    case hidden
}

extension PlatformStatus {
    /// 在今天页、菜单栏、小组件、合计、提醒里出现：已添加且没被隐藏
    var isShown: Bool { self != .notAdded && self != .hidden }
}

struct PlatformState: Equatable {
    var id: ProviderID
    var snapshot: ProviderSnapshot?
    var burn: BurnStats?
    var status: PlatformStatus
    var lastSampleAt: Date?
    /// 冷启动断网时，界面用最后一次采样的余额并标「N 分钟前」
    var lastSample: Sample?
    /// snapshot 是冷启动时从磁盘读回的旧数据（不是这次取到的）
    var snapshotFromDisk = false
    /// 套餐平台取数失败的原因（取自 ProviderError 的关联字符串）；取数成功后清空
    var errorDetail: String? = nil
}

extension PlatformState {
    func quotaAge(now: Date) -> TimeInterval? {
        guard let snapshot, snapshot.quota != nil else { return nil }
        return now.timeIntervalSince(snapshot.fetchedAt)
    }

    func quotaTooOld(now: Date) -> Bool {
        guard case .stale = status, let age = quotaAge(now: now) else { return false }
        return age > UsageStore.staleAfter
    }
}

/// 按严重程度排列（同一平台内）
enum Anomaly: Equatable {
    case offline(ProviderID), credentialInvalid(ProviderID), lowTank(ProviderID),
         spike(ProviderID), expiring(ProviderID), stale(ProviderID)
}

/// 汇总所有平台：调度刷新、出错降级、算速度、判断异常。界面只读这里。
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var platforms: [PlatformState] {
        didSet { ensureMainAdded() }
    }
    /// 主平台（面板主卡片）：由自动切换状态派生
    var mainProvider: ProviderID { switchState.main }
    /// 菜单栏显示的平台：永远等于主平台（用户 10-19 合并设置；轮流时跟着主平台一起换）
    @Published private(set) var menuBarRisk: PlatformRisk?
    @Published private(set) var menuBarProvider: ProviderID
    /// 原「正在轮流显示的平台」：2026-11-06 起不再轮流，恒为 [主平台]（面板小圆点和悬停「轮流显示」因此不出现，界面代码留作兼容）
    @Published private(set) var menuBarRotation: [ProviderID]
    /// 各平台最近一次本机任务活动时间（RunningTasks 扫出来的，只在内存里）
    private var runningLast: [ProviderID: Date] = [:]
    /// 按量付费活动供主平台切换和菜单栏读取，不写入 RunningTasks（用户 2026-11-13）。
    private var paygActive: [ProviderID: Date] = [:]
    /// 用户 2026-11-13：菜单栏复用现有活动窗口与限流判断，只读，不改变 MainSwitcher。
    func paygActiveIDs(now: Date) -> Set<ProviderID> {
        Set(paygActive.filter { now.timeIntervalSince($0.value) <= PaygActivity.window && !isRateLimited($0.key) }.map(\.key))
    }
    private var mainActivity: [ProviderID: Date] {
        runningLast.merging(paygActive, uniquingKeysWith: max)
    }
    @Published private(set) var switchState: MainSwitchState {
        didSet {
            if switchState != oldValue { saveSwitchState() }
            updateMenuBarProvider()         // 自动跟随还没跟随过时显示主平台，主平台变了要跟着变
        }
    }
    /// 最近一次自动切换（界面用来提示「已切到 X」）；手动设主平台、回落都不算
    @Published private(set) var lastAutoSwitch: (to: ProviderID, at: Date)?

    private let providers: [UsageProvider]
    private let credentials: CredentialStore
    private let samples: SampleStore
    private var spendCache = BalanceSpendCache()
    private struct SpendHistoryKey: Equatable {
        var range: DateInterval
        var complete: Bool
    }
    @Published private(set) var spendHistory: [ProviderID: [Sample]] = [:]
    private var loadedSpendHistory: SpendHistoryKey?
    private var pendingSpendHistory: SpendHistoryKey?
    private var spendHistoryGeneration = 0
    private let clock: () -> Date
    private let timeZone: () -> TimeZone
    private var baseInterval: TimeInterval
    private var interval: [ProviderID: TimeInterval] = [:]
    private var nextDue: [ProviderID: Date] = [:]
    /// 凭据失效后停止自动刷新，直到用户重新登录后手动刷新
    private var stopped: Set<ProviderID> = []
    private var timer: Timer?
    private var mainRotationTimer: Timer?
    /// 常用平台（几个同时在用时固定显示它）和上次选它的时间；近 7 天活跃分钟数由 App 读本机日志后传进来
    private(set) var preferredPlatform: ProviderID?
    private var preferredAt: Date?
    /// 这次启动后有没有写过「常用平台：…」日志（存盘的常用平台启动时就有，没变也要写一行方便排查）
    private var preferredLogged = false
    private let log: (String) -> Void
    /// 取数失败独立于界面状态；第一次失败、原因变化和恢复时各记一次。
    private var fetchFailed: [ProviderID: ProviderError] = [:]
    /// 读钥匙串失败的错误码：同一平台同一错误码只记一次日志，读到凭据时记「恢复」
    private var keychainFailed: [ProviderID: OSStatus] = [:]
    /// 正在按「重试」重读钥匙串
    private var retryingKeychain = false
    private let defaults: UserDefaults
    private let snapshotCache: SnapshotCache?
    private let settings: () -> ProviderSettings
    private var saving: [ProviderID: Task<Void, Error>] = [:]
    /// 读到的凭据缓存在内存：钥匙串只在启动后第一次（或重新登录后）读一次，不在每轮刷新时读
    private var cache: [ProviderID: Credentials] = [:]
    /// 在途的钥匙串读取，连同它开始时的移除计数（等着共用它的调用方按这个计数判断结果作不作废）
    private var reading: [ProviderID: (task: Task<CredentialRead, Never>, generation: Int)] = [:]
    /// 每移除一次平台加 1：移除前开始的钥匙串读取，读回来的旧凭据作废（不写回缓存和「已添加」）
    private var removals: [ProviderID: Int] = [:]
    /// 正在取数的平台：上一轮没回来就不再发起，避免请求叠加、旧结果覆盖新结果
    private var inFlight: Set<ProviderID> = []
    /// 面板或小组件是否可见。可见性变化经 setSurfaceVisible 处理。
    var surfaceVisible = false
    private var menuBarShown: Set<ProviderID> = []
    private var pauseState = RefreshPauseState()
    private var quotaFailures: [ProviderID: Int] = [:]
    /// 每个平台上一次取数的起点（下次到点从它算；切到空闲时据此重排）
    private var lastRunAt: [ProviderID: Date] = [:]
    /// 按量付费平台：连续几次取到的余额没变、上一次的读数、上一次写进日志的间隔
    private var unchangedRuns: [ProviderID: Int] = [:]
    private var lastReading: [ProviderID: [Decimal?]] = [:]
    private var steadyLogged: [ProviderID: TimeInterval] = [:]

    nonisolated static let staleAfter: TimeInterval = 600
    static let maxBackoff: TimeInterval = 900
    static let keepSamples: TimeInterval = 45 * 86400
    /// 跟随系统时区变化（.current 会在进程内缓存旧时区）
    nonisolated static let defaultTimeZone: @Sendable () -> TimeZone = { .autoupdatingCurrent }

    /// 「已添加」标记的 defaults 键（CredentialStore 迁移时也读它）
    nonisolated static func addedKey(_ id: ProviderID) -> String { "accountAdded.\(id.rawValue)" }
    private func addedKey(_ id: ProviderID) -> String { Self.addedKey(id) }
    /// 用户添加过这个平台（以「已添加」标记为准；启动时状态还是 .loading，不能看状态）
    func isAdded(_ id: ProviderID) -> Bool { defaults.bool(forKey: addedKey(id)) }
    /// 免凭据平台（Claude 套餐）存过登录信息的标记：移除时才知道要不要去钥匙串删
    nonisolated static func credentialsSavedKey(_ id: ProviderID) -> String { "credentialsSaved.\(id.rawValue)" }
    /// 「暂时隐藏」标记的 defaults 键
    nonisolated static func hiddenKey(_ id: ProviderID) -> String { "platformHidden.\(id.rawValue)" }
    /// 用户把这个已添加的平台暂时隐藏了
    func isHidden(_ id: ProviderID) -> Bool { isAdded(id) && defaults.bool(forKey: Self.hiddenKey(id)) }
    /// 隐藏着的已添加平台，按界面顺序（今天页底部「已隐藏：…」）
    var hiddenPlatforms: [ProviderID] { ProviderRegistry.all.filter { id in platforms.contains { $0.id == id && $0.status == .hidden } } }
    /// 添加过平台、但全都隐藏了（面板不显示「添加平台」，而是「都隐藏了 · 显示」）
    var allHidden: Bool { !hiddenPlatforms.isEmpty && !platforms.contains { $0.status.isShown } }

    /// 隐藏 / 显示平台。隐藏：停刷新、清掉内存里的读数（不留旧数被当成现在的）、固定显示它时改回自动；
    /// Key、「已添加」、历史采样都不动。显示：马上取一次数
    func setHidden(_ id: ProviderID, _ hidden: Bool) async {
        guard isAdded(id) else { return }
        if hidden {
            // 标记和状态都已是隐藏才算办完（状态被别处覆盖过时再隐藏一次能自己纠正）
            guard !isHidden(id) || platforms.first(where: { $0.id == id })?.status != .hidden else { return }
            defaults.set(true, forKey: Self.hiddenKey(id))
            paygActive.removeValue(forKey: id)
            runningLast.removeValue(forKey: id)
            unchangedRuns.removeValue(forKey: id)
            lastReading.removeValue(forKey: id)
            steadyLogged.removeValue(forKey: id)
            nextDue.removeValue(forKey: id)
            if id == switchState.main && isMainPinned {
                setAutoMain(true)
                log("已隐藏固定的主平台 \(ProviderRegistry.logName(id))，改回自动切换")
            }
            update(id) { $0 = PlatformState(id: id, snapshot: nil, burn: nil, status: .hidden) }
            log("已隐藏 \(ProviderRegistry.logName(id))（登录保留，不再刷新）")
            stepMainSwitch()
        } else {
            guard defaults.bool(forKey: Self.hiddenKey(id)) else { return }
            defaults.removeObject(forKey: Self.hiddenKey(id))
            // 隐藏前因 Key 失效等停了自动刷新的：显示回来 = 要用它，再试一次（还失效会照常停下并提示）
            stopped.remove(id)
            update(id) { $0 = PlatformState(id: id, snapshot: nil, burn: nil, status: .loading) }
            log("已显示 \(ProviderRegistry.logName(id))，重新开始刷新")
            await refresh(id)
        }
    }
    static let mainSwitchKey = "mainSwitch"
    /// 常用平台存盘的键：只存平台 id，不存算出来的时间（重启后照常重算一次，带着 20% 防抖；11/6 用户定乙）
    static let preferredPlatformKey = "preferredPlatform"
    /// 旧版「菜单栏平台」设置的键（10-19 起不再读，启动时删掉）
    static let legacyMenuBarKeys = ["menuBarProvider", "menuBarProvider.autoMigrated", "menuBarProvider.followMainMigrated"]

    private static func loadSwitchState(_ d: UserDefaults) -> MainSwitchState {
        if let data = d.data(forKey: mainSwitchKey),
           let s = try? JSONDecoder().decode(MainSwitchState.self, from: data) { return s }
        return MainSwitchState(main: .deepseek, auto: true)
    }

    private func saveSwitchState() {
        if let data = try? JSONEncoder().encode(switchState) { defaults.set(data, forKey: Self.mainSwitchKey) }
    }

    /// 按 ProviderRegistry.all 的顺序，第一个已添加的平台；都没添加时用 DeepSeek
    private static func firstAdded(_ platforms: [PlatformState]) -> ProviderID {
        ProviderRegistry.all.first { id in platforms.contains { $0.id == id && $0.status.isShown } }
            ?? ProviderRegistry.all.first { id in platforms.contains { $0.id == id && $0.status != .notAdded } } ?? .deepseek
    }

    /// 主平台必须是已添加的平台：当前主平台未添加（或不在列表里）时回落到第一个已添加的。回落不算切换
    private func ensureMainAdded() {
        let ok = platforms.contains { $0.id == switchState.main && $0.status.isShown }
            || (!platforms.contains { $0.status.isShown } && platforms.contains { $0.id == switchState.main && $0.status != .notAdded })
        if !ok {
            let fallback = Self.firstAdded(platforms)
            if fallback != switchState.main { switchState.main = fallback }
        }
        updateMenuBarProvider()
    }

    /// 菜单栏跟着主平台：显示的平台、轮流列表和风险读数；没变就不写（免得 @Published 白白通知）
    private func updateMenuBarProvider() {
        let main = switchState.main
        if main != menuBarProvider { menuBarProvider = main }
        // 2026-11-06 起几个同时在用也不轮流（固定显示常用平台）：轮流列表只剩主平台，面板小圆点和悬停「轮流显示」不再出现
        let list = [main]
        if list != menuBarRotation { menuBarRotation = list }
        let risk = risks().first { $0.id == main && $0.atRisk }
        if risk != menuBarRisk { menuBarRisk = risk }
    }

    /// 本机任务扫描结果：各平台最近一次活动时间（没有任务的平台不在里面）。
    /// 每次扫描（10 秒）都重算：结果没变时，任务也可能刚好过了 10 分钟窗口
    func setRunningTasks(_ last: [ProviderID: Date]) {
        runningLast = last
        stepMainSwitch()            // 里面会 ensureMainAdded → updateMenuBarProvider
    }

    /// 手动设主平台：立即生效，暂停自动切换 2 小时
    func pinMain(_ id: ProviderID) {
        switchState = MainSwitcher.pin(switchState, to: id, now: clock())
        lastAutoSwitch = nil        // 手动设了主平台，之前的「已自动切换」提示作废
    }

    /// 主平台是否处于「固定」：自动切换关着，或手动设主平台后的暂停期内
    var isMainPinned: Bool {
        !switchState.auto || (switchState.pinnedUntil.map { $0 > clock() } ?? false)
    }

    /// 面板里待显示的切换提示；主平台已不是自动切到的那个时不显示
    var pendingSwitchNotice: String? {
        // 切到套餐平台不提示（用户 2026-11-06 选乙：套餐类提示不占面板顶部）；按量付费「余额在减少」照旧
        guard let s = lastAutoSwitch, s.to == mainProvider, ProviderRegistry.meter(s.to) != .quota else { return nil }
        return L(Self.switchNoticeKey(platforms.first { $0.id == s.to }?.snapshot), ProviderRegistry.displayName(s.to))
    }

    /// 切换提示用哪句：没有余额（按花费上涨判的）或金额是 Key 剩余上限（OpenRouter）时说「有新的花费」，
    /// 不说「余额在减少」；没有快照时照旧
    static func switchNoticeKey(_ snapshot: ProviderSnapshot?) -> String {
        guard let snapshot else { return "switch.noticePayg" }
        return snapshot.balance == nil || snapshot.balanceIsKeyLimit == true ? "switch.noticePaygSpend" : "switch.noticePayg"
    }

    /// 提示显示过（或面板开着时已播过动画）后清空
    func consumeAutoSwitch() { lastAutoSwitch = nil }

    /// 调试用：主平台换成第一个辅助平台（与面板辅助区同序），按一次自动切换处理，不暂停自动切换
    func demoSwitch() {
        guard let to = platforms.first(where: { $0.id != mainProvider && $0.status.isShown })?.id else { return }
        let now = clock()
        var s = switchState
        s.main = to
        s.lastSwitchAt = now
        s.leader = nil
        s.leaderSince = nil
        switchState = s
        lastAutoSwitch = (to: to, at: now)
    }

    func setAutoMain(_ on: Bool) {
        var s = switchState
        s.auto = on
        if on { s.pinnedUntil = nil }       // 重新开自动：同时结束手动暂停期（裁决 R25）
        s.leader = nil
        s.leaderSince = nil
        switchState = s
    }

    /// 各平台近 1 小时时速换成人民币；没有「近 1 小时」时速的平台不在其中。
    /// 只算这一轮取数成功的平台（.ok / .consoleLoginNeeded）：失败后 burn 是冻结的旧值，不能拿来比较
    func ratesCny() -> [ProviderID: Decimal] {
        let rate = settings().usdToCny
        var out: [ProviderID: Decimal] = [:]
        for st in platforms where st.status == .ok || st.status == .consoleLoginNeeded {
            guard let r = st.burn?.perHourRecent,
                  let cur = providers.first(where: { $0.id == st.id })?.capabilities.currency else { continue }
            out[st.id] = Money(amount: r, currency: cur).converted(to: .cny, usdToCny: rate).amount
        }
        return out
    }

    /// 自动切换用的活跃度：按量付费平台取 ratesCny，取数成功的套餐平台取近 1 小时额度涨幅（没有涨幅按 0）
    func activities() -> [ProviderID: Activity] {
        var out = ratesCny().mapValues { Activity.money(perHourCny: $0) }
        for st in platforms where st.status == .ok && isQuota(st.id) {
            out[st.id] = .quota(risePP: quotaRise(st.id) ?? 0)
        }
        return out
    }

    /// 每轮刷新、每次任务扫描后协调主平台；主平台变了就记切换提示（几个同时在用时选常用平台，见 PreferredPlatform）
    private func stepMainSwitch() {
        let now = clock()
        expirePaygActivity(now: now)
        let before = switchState.main
        let added = Set(platforms.filter { $0.status.isShown }.map(\.id))
        let next = MainSwitcher.step(switchState, lastActivity: mainActivity, added: added, now: now,
                                     preferred: preferredPlatform)
        if next != switchState { switchState = next }
        if switchState.main != before { lastAutoSwitch = (to: switchState.main, at: now) }
        ensureMainAdded()
    }

    /// 每 10 秒协调一次主平台（按量付费「正在用」到期等）；2026-11-06 起不再轮流
    func advanceMainRotation() {
        stepMainSwitch()
    }

    /// App 读完本机日志后传入近 7 天活跃分钟数：每小时最多重算一次常用平台（另一个要多 20% 以上才换）
    func setActiveMinutes(_ minutes: [ProviderID: Int]) {
        let now = clock()
        if let at = preferredAt, now.timeIntervalSince(at) < PreferredPlatform.recheck,
           preferredPlatform.map({ isAdded($0) && !isHidden($0) }) == true { return }
        let added = minutes.filter { isAdded($0.key) && !isHidden($0.key) }
        guard let pick = PreferredPlatform.pick(minutes: added, current: preferredPlatform.flatMap { isAdded($0) && !isHidden($0) ? $0 : nil })
        else { return }
        preferredAt = now
        if pick != preferredPlatform || (!preferredLogged && (added[pick] ?? 0) > 0) {
            preferredLogged = true
            log("常用平台：\(ProviderRegistry.logName(pick))（近 7 天本机活跃 \(added[pick] ?? 0) 分钟）")
        }
        if pick != preferredPlatform {
            preferredPlatform = pick
            defaults.set(pick.rawValue, forKey: Self.preferredPlatformKey)
            // 因常用平台变了而换主平台不弹「有任务在跑，已切换显示」：不是新任务引起的，提示会让人莫名其妙
            let before = switchState.main
            stepMainSwitch()
            if switchState.main != before { lastAutoSwitch = nil }
        }
    }

    /// 面板「重试」：读钥匙串出错停下的平台，清掉这次启动记住的失败（钥匙串是一整条、所有平台共用）后各读一次；
    /// 系统会再弹一次授权框。没有这样的平台时什么也不做
    func retryKeychain() async {
        // 连点「重试」只重读一次：第二次会清掉刚记住的拒绝、再弹一次授权框（审核建议）
        guard !retryingKeychain else { return }
        retryingKeychain = true
        defer { retryingKeychain = false }
        let ids = platforms.compactMap { st -> ProviderID? in
            if case .keychainUnreadable = st.status { return st.id }
            return nil
        }
        guard !ids.isEmpty else { return }
        log("重试读钥匙串：\(ids.map { ProviderRegistry.logName($0) }.joined(separator: "、"))")
        let cs = credentials
        await Task.detached { cs.clearFailure() }.value
        for id in ids { stopped.remove(id) }
        for id in ids { await refresh(id) }
    }

    /// 下次自动刷新的时间（各平台独立）
    func nextDueAt(_ id: ProviderID) -> Date? { nextDue[id] }

    /// 读凭据：先用内存缓存；要读钥匙串时放到后台线程（系统授权框弹出时不卡住菜单栏），同一平台同时只读一次
    func readCredentials(_ id: ProviderID) async -> CredentialRead {
        if let c = cache[id] { return .found(c) }
        if let entry = reading[id] {
            // 按那次读取开始时的计数判断：移除后才来等的（如移除后马上重新登录）也不能拿到旧凭据
            let r = await entry.task.value
            return removals[id, default: 0] == entry.generation ? r : .notFound
        }
        let generation = removals[id, default: 0]
        let cs = credentials
        let t = Task.detached { cs.read(id) }
        reading[id] = (t, generation)
        let r = await t.value
        reading[id] = nil
        // 读的途中平台被移除了：钥匙串已删，这次读到的是旧凭据，按「没有」处理
        guard removals[id, default: 0] == generation else { return .notFound }
        if case .found(let c) = r {
            cache[id] = c
            defaults.set(true, forKey: addedKey(id))
        }
        return r
    }

    /// 保存（合并到已有凭据上，如只更新 webToken 时保留 API Key），然后立刻按新凭据取一次
    func saveCredentials(_ values: [String: String], for id: ProviderID,
                         attempt: ClaudeLoginAttempts.Ticket? = nil,
                         onPersisted: (() -> Void)? = nil,
                         refresh: Bool = true) async throws {
        // 同平台的读、合并、写入和缓存更新必须串行；取数不占保存队列。
        while let task = saving[id] { _ = await task.result }
        let task = Task { @MainActor in
            defer { saving[id] = nil }
            var merged: [String: String] = [:]
            let cs = credentials
            if cache[id] == nil {
                // 用户主动保存：后台清掉上次拒绝，避免主线程等钥匙串锁。
                await Task.detached { cs.clearFailure() }.value
            }
            switch await readCredentials(id) {
            case .found(let c): merged = c.values
            case .notFound: break
            case .error(let status): throw KeychainError(status: status)
            }
            merged.merge(values) { $1 }
            merged = merged.filter { !$0.value.isEmpty }     // 空值 = 删掉这一项
            let creds = Credentials(values: merged)
            try await Task.detached {
                if let attempt { try attempt.commit { try cs.save(creds, for: id) } }
                else { try cs.save(creds, for: id) }
            }.value
            onPersisted?()
            cache[id] = creds
            if !needsCredentials(id) { defaults.set(true, forKey: Self.credentialsSavedKey(id)) }
            defaults.set(true, forKey: addedKey(id))
            stopped.remove(id)
            interval[id] = nil
            nextDue[id] = nil
        }
        saving[id] = task
        try await task.value
        // 重新登录 = 要用它：隐藏着的也一并显示回来
        defaults.removeObject(forKey: Self.hiddenKey(id))
        if refresh, let p = providers.first(where: { $0.id == id }), !inFlight.contains(id) { await run(p) }
    }

    /// 添加免凭据平台（套餐平台读本地文件）：只写「添加过」标记，不碰钥匙串，然后立刻取一次
    func addCredentialFree(_ id: ProviderID) async {
        defaults.set(true, forKey: addedKey(id))
        defaults.removeObject(forKey: Self.hiddenKey(id))
        stopped.remove(id)
        cache[id] = Credentials(values: [:])
        interval[id] = nil
        nextDue[id] = nil
        if let p = providers.first(where: { $0.id == id }), !inFlight.contains(id) { await run(p) }
    }

    private func needsCredentials(_ id: ProviderID) -> Bool {
        providers.first { $0.id == id }?.capabilities.needsCredentials ?? true
    }

    private func isQuota(_ id: ProviderID) -> Bool {
        providers.first { $0.id == id }?.capabilities.meter == .quota
    }

    /// 移除账号：删钥匙串、清缓存和「添加过」标记，界面回到未添加（免凭据平台不碰钥匙串）
    func removeAccount(_ id: ProviderID) async throws {
        if needsCredentials(id) {
            let cs = credentials
            try await Task.detached { try cs.delete(id) }.value
        } else if defaults.bool(forKey: Self.credentialsSavedKey(id)) {
            // 免凭据平台存过登录（Claude 套餐「登录 claude.ai」来源的 Cookie）：移除时一并删掉，删不掉不挡移除、记一行。
            // 没存过就不碰钥匙串（以前移除套餐平台从不读钥匙串，免得弹授权框）
            let cs = credentials
            do { try await Task.detached { try cs.delete(id) }.value }
            catch { log("\(ProviderRegistry.logName(id)) 的登录信息没能从钥匙串删掉：\(error)") }
            defaults.removeObject(forKey: Self.credentialsSavedKey(id))
        }
        removals[id, default: 0] += 1
        cache[id] = nil
        try? samples.remove(id)
        if !isQuota(id) {
            spendHistoryGeneration += 1
            loadedSpendHistory = nil
            pendingSpendHistory = nil
            spendHistory[id] = nil
        }
        quotaFailures.removeValue(forKey: id)
        unchangedRuns.removeValue(forKey: id)
        lastReading.removeValue(forKey: id)
        steadyLogged.removeValue(forKey: id)
        interval.removeValue(forKey: id)
        nextDue.removeValue(forKey: id)
        lastRunAt.removeValue(forKey: id)
        spendCache.remove(id)
        paygActive.removeValue(forKey: id)
        if preferredPlatform == id {
            preferredPlatform = nil
            preferredAt = nil
            defaults.removeObject(forKey: Self.preferredPlatformKey)
        }
        defaults.removeObject(forKey: addedKey(id))
        defaults.removeObject(forKey: Self.hiddenKey(id))
        try? snapshotCache?.remove(id)
        stopped.insert(id)
        fetchFailed.removeValue(forKey: id)
        keychainFailed.removeValue(forKey: id)
        // 移除固定的主平台时先恢复自动，再让未添加状态触发主平台回落。
        if id == switchState.main && isMainPinned {
            setAutoMain(true)
            log("已移除固定的主平台 \(ProviderRegistry.logName(id))，改回自动切换")
        }
        update(id) { $0 = PlatformState(id: id, snapshot: nil, burn: nil, status: .notAdded) }
    }

    /// 读钥匙串失败的日志：锁着（-25308）下一轮会再试；其余已停自动刷新，重启或重新登录（保存时清掉上次拒绝）后恢复
    static func keychainFailureLog(_ name: String, _ status: OSStatus) -> String {
        if status == -25308 { return "\(name) 读钥匙串失败（-25308 钥匙串已锁），下一轮自动重试" }
        let reason: String
        switch status {
        case -128: reason = " 用户拒绝"
        case -25293: reason = " 授权失败"
        case -26276: reason = " 凭据数据损坏"
        default: reason = ""
        }
        return "\(name) 读钥匙串失败（\(status)\(reason)），已停止自动刷新，点面板里的「重试」或重新登录后恢复"
    }

    /// 自动或手动发起取数前的统一检查：不叠加、不碰已停止的平台、限流期间不发
    private func canRun(_ id: ProviderID, _ now: Date) -> Bool {
        if pauseState.paused || inFlight.contains(id) || stopped.contains(id) || isHidden(id) { return false }
        if case .rateLimited(let until)? = platforms.first(where: { $0.id == id })?.status, until > now { return false }
        return true
    }

    init(providers: [UsageProvider], credentials: CredentialStore, samples: SampleStore, intervalSeconds: Int,
         clock: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = UsageStore.defaultTimeZone,
         defaults: UserDefaults = .standard, snapshotCache: SnapshotCache? = nil,
         settings: @escaping () -> ProviderSettings = { ProviderSettings.load(.standard) },
         log: @escaping (String) -> Void = { _ in }) {
        self.log = log
        self.settings = settings
        self.providers = providers
        self.credentials = credentials
        self.samples = samples
        self.clock = clock
        self.timeZone = timeZone
        self.baseInterval = TimeInterval(intervalSeconds)
        self.defaults = defaults
        self.snapshotCache = snapshotCache
        let initial = providers.map { p in
            PlatformState(id: p.id, snapshot: nil, burn: nil,
                          status: defaults.bool(forKey: Self.addedKey(p.id)) && defaults.bool(forKey: Self.hiddenKey(p.id)) ? .hidden : .loading,
                          lastSampleAt: nil, lastSample: nil)
        }
        self.platforms = initial
        let sw = Self.loadSwitchState(defaults)
        self.switchState = sw
        // 旧版的「菜单栏平台」设置不再使用：删掉存的键，菜单栏跟着主平台
        for key in Self.legacyMenuBarKeys { defaults.removeObject(forKey: key) }
        self.menuBarProvider = sw.main
        self.menuBarRotation = [sw.main]
        // 上次的常用平台：还在已添加的平台里才用（存的平台没添加 / 认不出当没有）；preferredAt 留空，读完日志照常重算
        if let raw = defaults.string(forKey: Self.preferredPlatformKey) {
            if let id = ProviderID(rawValue: raw), providers.contains(where: { $0.id == id }), defaults.bool(forKey: Self.addedKey(id)) {
                self.preferredPlatform = id
            } else {
                // 用不上的旧值删掉：免得以后重新添加这个平台时，很久以前的常用平台又被恢复、还占着防抖的便宜
                defaults.removeObject(forKey: Self.preferredPlatformKey)
            }
        }
        ensureMainAdded()
    }

    private func base(_ p: UsageProvider) -> TimeInterval { max(baseInterval, p.capabilities.minPollInterval) }

    /// 复用界面数据刷新节奏。昨日的采样在日界后 15 分钟就固定，可整天共用。
    func spendHistory(now: Date, timeZone: TimeZone) -> [ProviderID: [Sample]] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let path = samples.path
        guard path != ":memory:", let range = SpendComparison.historyInterval(now: now, calendar: calendar),
              platforms.contains(where: { $0.status.isShown && $0.snapshot?.source == .bill && $0.snapshot?.today != nil })
        else { return [:] }
        let key = SpendHistoryKey(range: range, complete: now >= range.end)
        if loadedSpendHistory != key && pendingSpendHistory != key {
            let ids = providers.filter { $0.capabilities.meter != .quota && !$0.capabilities.estimatesSpendFromBalance }.map(\.id)
            pendingSpendHistory = key
            spendHistoryGeneration += 1
            let generation = spendHistoryGeneration
            Task { [weak self] in
                let history = await Task.detached(priority: .utility) {
                    try? SampleStore.loadCostHistory(path: path, ids: ids, range: range)
                }.value
                guard let self, self.spendHistoryGeneration == generation else { return }
                self.pendingSpendHistory = nil
                guard let history else { return }
                self.loadedSpendHistory = key
                self.spendHistory = history
            }
        }
        return loadedSpendHistory?.range == range ? spendHistory : [:]
    }

    func currentInterval(_ id: ProviderID) -> TimeInterval {
        guard let p = providers.first(where: { $0.id == id }) else { return baseInterval }
        if p.capabilities.meter == .quota {
            let state = platforms.first { $0.id == id }
            if state?.status == .credentialInvalid, let retry = p.capabilities.credentialRetryInterval { return retry }
            let renewed = state?.snapshot?.quota?.windows.contains { $0.isReset(at: clock()) } ?? false
            return QuotaCadence.interval(visible: quotaVisible(id), renewedPending: renewed,
                                         failure: state.flatMap { FailureKind.from($0.status) },
                                         failuresInARow: quotaFailures[id] ?? 0)
        }
        // 正在用时每分钟查一次；被限流时仍按限流退避翻倍（审核必须改：否则在用期间被 429 会每 2 分钟重试）
        if let last = paygActive[id], clock().timeIntervalSince(last) <= PaygActivity.window, !isRateLimited(id) {
            return p.capabilities.minPollInterval
        }
        return interval[id] ?? base(p)
    }

    /// 下次到点：从上一次取数的起点算；套餐平台知道 5 小时窗口的重置时间时，重置后补刷一次
    private func reschedule(_ id: ProviderID, anchor: Date, now: Date) {
        let reset = isQuota(id) && platforms.first(where: { $0.id == id }).flatMap({ FailureKind.from($0.status) }) == nil
            ? platforms.first { $0.id == id }?.snapshot?.quota?.windows.first { $0.kind == .session }?.resetsAt : nil
        nextDue[id] = PollCadence.nextDue(anchor: anchor, interval: currentInterval(id), resetAt: reset, now: now)
    }

    private func quotaVisible(_ id: ProviderID) -> Bool {
        surfaceVisible || menuBarShown.contains(id)
    }

    private var visibleQuotaIDs: Set<ProviderID> {
        Set(providers.filter { $0.capabilities.meter == .quota && quotaVisible($0.id) }.map(\.id))
    }

    func setSurfaceVisible(_ visible: Bool) async {
        guard surfaceVisible != visible else { return }
        let previous = visibleQuotaIDs
        surfaceVisible = visible
        await rescheduleQuotaVisibility(previous: previous)
    }

    /// 用户 2026-11-13 反馈「刷新慢」：菜单栏常驻读数也算可见，仅放宽正在显示的套餐；按量付费节奏独立。
    func setMenuBarShown(_ ids: Set<ProviderID>) async {
        guard menuBarShown != ids else { return }
        let previous = visibleQuotaIDs
        menuBarShown = ids
        await rescheduleQuotaVisibility(previous: previous)
    }

    /// 面板、小组件和菜单栏共用有效可见性变化的重排，失败退避、窗口重置补刷和锁屏暂停仍由原策略决定。
    private func rescheduleQuotaVisibility(previous: Set<ProviderID>) async {
        for p in providers where p.capabilities.meter == .quota {
            let visible = quotaVisible(p.id)
            guard visible != previous.contains(p.id) else { continue }
            let now = clock()
            let state = platforms.first { $0.id == p.id }
            // 可见性不能提前重试失败请求；按原锚点和退避间隔重排，交给 tick 到点取数。
            if visible, state.flatMap({ FailureKind.from($0.status) }) == nil, canRun(p.id, now),
               state?.snapshot.map({ now.timeIntervalSince($0.fetchedAt) > QuotaCadence.visible }) ?? true {
                await run(p)
            } else if let anchor = lastRunAt[p.id] {
                reschedule(p.id, anchor: anchor, now: now)
            }
        }
    }

    func setPaused(_ paused: Bool) {
        guard pauseState.setPaused(paused) else { return }
        timer?.invalidate()
        timer = nil
        mainRotationTimer?.invalidate()
        mainRotationTimer = nil
        if !paused { start(intervalSeconds: Int(baseInterval)) }
    }

    /// 立即刷新（打开面板、点刷新、网络恢复）：不等到点，但遵守不叠加、限流退避和凭据失效停止；
    /// 凭据失效后要重新登录（saveCredentials）才恢复。id 为 nil 时刷新全部。
    /// resetSlowdown：只有点「刷新」按钮时为 true，按量付费平台「余额没变就放慢」清零、回到设置的间隔；
    /// 打开面板等只取一次最新数，放慢照旧（11/6 用户定：原来每次开面板都清零，放慢撑不过一次开面板）
    func refresh(_ id: ProviderID? = nil, resetSlowdown: Bool = false) async {
        let now = clock()
        var ran = false
        for p in providers where (id == nil || p.id == id) && canRun(p.id, now) {
            if resetSlowdown { unchangedRuns[p.id] = 0 }
            await run(p)
            ran = true
        }
        if ran { stepMainSwitch() }
    }

    /// 定时器调用：只刷新到点且没被停止的平台。下次到点从这一拍算起，不从真正开始取数的时刻算——
    /// 前面的平台（如 claude 子进程）要花几秒，否则后面的平台每次都差一点没到点，2 分钟变成 2 分 15 秒（10-19 实测）
    func tick() async {
        let now = clock()
        var ran = false
        for p in providers {
            // 到点判断用现在的时刻：前面的平台可能卡了十几秒（超时 25 秒），期间下一拍已经把后面的平台取过、
            // nextDue 往后推了；再拿这一拍开始时的旧时刻比，会被当成「时钟往回拨」又取一次（11-05 19:40 日志实证）
            let current = clock()
            guard canRun(p.id, current), PollCadence.isDue(nextDue: nextDue[p.id], now: current, interval: currentInterval(p.id)) else { continue }
            // 锚点：这一拍开始的时刻（防漂移）；卡住期间才到点的平台从原定到点时刻算，不早于它（否则下次来得偏早）
            let anchor = max(now, min(nextDue[p.id] ?? now, current))
            await run(p, scheduledAt: anchor)
            ran = true
        }
        if ran { stepMainSwitch() }
    }

    func start(intervalSeconds: Int) {
        baseInterval = TimeInterval(intervalSeconds)
        guard !pauseState.paused else { return }
        // 改间隔 / 解锁时回到新的基础间隔，但正在限流的平台保留退避（原来一并清掉，限流一结束就按基础间隔再撞）
        // 保留的退避不短于新的基础间隔（用户把间隔调大时不能反而更勤）
        var kept: [ProviderID: TimeInterval] = [:]
        for p in providers where isRateLimited(p.id) { if let v = interval[p.id] { kept[p.id] = max(v, base(p)) } }
        interval = kept
        unchangedRuns = [:]
        steadyLogged = [:]
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer?.tolerance = 2            // 允许系统把唤醒合并（省电）；到点判断本来就容 1 秒误差
        mainRotationTimer?.invalidate()
        mainRotationTimer = Timer.scheduledTimer(withTimeInterval: MainSwitcher.rotateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceMainRotation() }
        }
        mainRotationTimer?.tolerance = 1
        Task { await refresh() }
    }

    private func update(_ id: ProviderID, _ change: (inout PlatformState) -> Void) {
        guard let i = platforms.firstIndex(where: { $0.id == id }) else { return }
        change(&platforms[i])
    }

    /// scheduledAt：定时器这一拍的时刻（下次到点从它算起）；手动刷新为 nil，从现在算起
    private func run(_ p: UsageProvider, scheduledAt: Date? = nil) async {
        let now = clock()
        let anchor = scheduledAt ?? now
        inFlight.insert(p.id)
        defer { inFlight.remove(p.id) }
        lastRunAt[p.id] = anchor
        nextDue[p.id] = anchor.addingTimeInterval(currentInterval(p.id))
        let creds: Credentials
        let isQuota = p.capabilities.meter == .quota
        if !p.capabilities.needsCredentials {
            // 免凭据平台：没添加过就停在「未添加」，添加后用空凭据取数；不读钥匙串
            guard defaults.bool(forKey: addedKey(p.id)) else {
                stopped.insert(p.id)
                update(p.id) { $0.status = .notAdded }
                return
            }
            creds = Credentials(values: [:])
            cache[p.id] = creds
        } else {
        let read = await readCredentials(p.id)
        // 读钥匙串途中（可能在等授权框）被隐藏：结果不管成败都不写状态，留在「已隐藏」
        if isHidden(p.id) { return }
        switch read {
        case .found(let c):
            creds = c
            if keychainFailed.removeValue(forKey: p.id) != nil { log("\(ProviderRegistry.logName(p.id)) 读钥匙串恢复") }
        case .notFound:
            keychainFailed.removeValue(forKey: p.id)
            // 添加过却读不到（在「钥匙串访问」里被删了）→ 凭据失效，提示重新登录；从没添加过 → 未添加
            stopped.insert(p.id)
            let added = defaults.bool(forKey: addedKey(p.id))
            update(p.id) { $0.status = added ? .credentialInvalid : .notAdded }
            return
        case .error(let status):
            // 拒绝授权等：停下自动刷新，免得反复弹授权框；钥匙串只是锁着（-25308）时下一轮再试
            if status != -25308 { stopped.insert(p.id) }
            if keychainFailed.updateValue(status, forKey: p.id) != status {
                log(Self.keychainFailureLog(ProviderRegistry.logName(p.id), status))
            }
            update(p.id) { $0.status = .keychainUnreadable(status: status) }
            return
        }
        }
        let result = await p.fetch(creds, now: now, timeZone: timeZone())
        // 取数途中重新登录或移除了账号：这次结果属于旧凭据，作废（整分支评审 I-5 后半）。
        // 换了新凭据就马上按新凭据补取一次（saveCredentials 当时因为在途没有发起）
        // 取数途中被隐藏：这次结果不要（不写读数、不记采样），状态留在「已隐藏」
        if isHidden(p.id) { return }
        guard cache[p.id] == creds else {
            if cache[p.id] != nil, !stopped.contains(p.id) { await run(p) }
            return
        }
        switch result {
        case .success:
            if fetchFailed.removeValue(forKey: p.id) != nil { log("\(ProviderRegistry.logName(p.id)) 取数恢复") }
        case .failure(let error):
            if fetchFailed.updateValue(error, forKey: p.id) != error {
                let reason = error.detail ?? "被限流"
                // 有的原因自带「稍后自动再查」，不再重复补一句
                let tail = (reason.contains("稍后") || reason.contains("later")) ? "" : "，稍后自动重试"
                log("\(ProviderRegistry.logName(p.id)) 取数失败：\(reason)\(tail)")
            }
        }
        switch result {
        case .success(let s) where isQuota:
            quotaFailures[p.id] = 0
            // 套餐平台：没有余额和 burn；只有数据比上一条采样新（真有新观测）才追加采样
            interval[p.id] = base(p)
            if let q = s.quota {
                let prev = try? samples.latest(p.id)
                if prev.map({ q.observedAt > $0.t }) ?? true {
                    let w = q.activityWindow
                    try? samples.append(Sample(provider: p.id, t: q.observedAt, balance: nil, cumulativeCost: nil,
                                               currency: p.capabilities.currency,
                                               quotaUsed: w?.effectiveUsed(at: q.observedAt), quotaWindow: w?.kind.sampleKey))
                }
                try? samples.prune(olderThan: now.addingTimeInterval(-Self.keepSamples))
            }
            try? snapshotCache?.save(s)
            update(p.id) {
                $0.snapshot = s
                $0.snapshotFromDisk = false
                $0.burn = nil
                $0.status = .ok
                $0.errorDetail = nil
                $0.lastSampleAt = now
            }
        case .success(var s):
            // 有账单时用本月累计花费作采样（单调递增）；只有余额时用余额下降量
            try? samples.append(Sample(provider: p.id, t: now, balance: s.balance?.amount,
                                       cumulativeCost: s.source == .bill ? s.month?.amount : nil, currency: p.capabilities.currency))
            try? samples.prune(olderThan: now.addingTimeInterval(-Self.keepSamples))
            notePaygActivity(p, now: now)
            noteSteady(p, s)
            if p.capabilities.estimatesSpendFromBalance, s.source == .balanceOnly { estimateSpend(&s, p, now) }
            let burn = computeBurn(p, s, now)
            try? snapshotCache?.save(s)
            update(p.id) {
                $0.snapshot = s
                $0.snapshotFromDisk = false
                $0.burn = burn
                $0.status = s.consoleLoginNeeded ? .consoleLoginNeeded : .ok
                $0.lastSampleAt = now
            }
        case .failure(let e) where isQuota:
            quotaFailures[p.id] = min(100, (quotaFailures[p.id] ?? 0) + 1)
            // 套餐取数失败保留最后的额度与时间；首次失败时可恢复磁盘快照。
            let detail = e.detail
            update(p.id) { st in
                if case .auth = e {
                    // 登录失效期间重启（重装、重启电脑）也要能看到「上次读数」：同下面一样从磁盘恢复
                    if st.snapshot == nil, let disk = self.snapshotCache?.load()[p.id], disk.quota != nil {
                        st.snapshot = disk
                        st.snapshotFromDisk = true
                    }
                    st.status = .credentialInvalid
                } else if case .schemaChanged = e {
                    st.status = .schemaChanged
                } else {
                    if st.snapshot == nil, let disk = self.snapshotCache?.load()[p.id], disk.quota != nil {
                        st.snapshot = disk
                        st.snapshotFromDisk = true
                    }
                    if let age = st.quotaAge(now: now) { st.status = .stale(minutes: Int(age) / 60) }
                    else { st.status = .offline }
                }
                st.errorDetail = detail
            }
        case .failure(let e):
            let last = try? samples.latest(p.id)
            update(p.id) { st in
                switch e {
                case .auth:
                    self.stopped.insert(p.id)
                    st.status = .credentialInvalid
                case .rateLimited:
                    // 翻倍退避，上限 900 秒；但基础间隔本身更长时以基础间隔为准，退避不能反而缩短间隔
                    let b = self.base(p)
                    let next = max(b, min(self.currentInterval(p.id) * 2, max(Self.maxBackoff, b)))
                    self.interval[p.id] = next
                    st.status = .rateLimited(until: now.addingTimeInterval(next))
                case .schemaChanged:
                    st.status = .schemaChanged
                default:
                    // 冷启动断网：内存里没有快照时，用磁盘上最近一次成功的快照，但状态仍是离线
                    if st.snapshot == nil, let disk = self.snapshotCache?.load()[p.id] {
                        st.snapshot = disk
                        st.snapshotFromDisk = true
                    }
                    if st.snapshotFromDisk {
                        st.status = .offline
                    } else if let s = st.snapshot {
                        st.status = .stale(minutes: Int(now.timeIntervalSince(s.fetchedAt) / 60))
                    } else {
                        st.status = .offline
                    }
                }
                if st.lastSampleAt == nil { st.lastSampleAt = last?.t }
                if st.lastSample == nil { st.lastSample = last }
            }
        }
        reschedule(p.id, anchor: anchor, now: clock())
    }

    private func isRateLimited(_ id: ProviderID) -> Bool {
        if case .rateLimited? = platforms.first(where: { $0.id == id })?.status { return true }
        return false
    }

    /// 即使没有新采样，任务扫描也会清掉到期活动，并从基础间隔重新安排刷新。
    private func expirePaygActivity(now: Date) {
        for (id, last) in paygActive where now.timeIntervalSince(last) > PaygActivity.window {
            paygActive.removeValue(forKey: id)
            unchangedRuns[id] = 0
            if let p = providers.first(where: { $0.id == id }), !isRateLimited(id) {
                interval[id] = base(p)
                steadyLogged[id] = base(p)
                reschedule(id, anchor: lastRunAt[id] ?? now, now: now)
            }
            log("\(ProviderRegistry.logName(id))：10 分钟没再扣费，不再算正在使用")
        }
    }

    private func notePaygActivity(_ p: UsageProvider, now: Date) {
        expirePaygActivity(now: now)
        guard let recent = try? samples.activitySamples(p.id, since: now.addingTimeInterval(-3600)) else { return }
        let before = paygActive[p.id]
        // 正在使用时只需看本次是否下降；避免一小时以前的起始阈值被裁剪后误停。
        if let last = before {
            let pair = recent.suffix(2)
            if pair.count == 2, let a = pair.first, let b = pair.last, PaygActivity.drop(a, b) != nil {
                paygActive[p.id] = pair.last?.t
            } else {
                paygActive[p.id] = last
            }
        } else {
            paygActive[p.id] = PaygActivity.lastActive(samples: recent, now: now)
        }
        if before == nil, paygActive[p.id] != nil {
            let what = recent.last?.balance == nil ? "有新的花费" : "余额在减少"
            log("\(ProviderRegistry.logName(p.id))：\(what)，算作正在使用")
            stepMainSwitch()
        }
    }

    /// 按量付费平台取数成功：余额（和本月花费）跟上一次比，连续没变就放慢，变了回到设置的间隔；间隔变了才写日志
    private func noteSteady(_ p: UsageProvider, _ s: ProviderSnapshot) {
        let reading = [s.balance?.amount, s.month?.amount]
        let same = lastReading[p.id].map { $0 == reading } ?? false
        lastReading[p.id] = reading
        let n = same && paygActive[p.id] == nil ? (unchangedRuns[p.id] ?? 0) + 1 : 0
        unchangedRuns[p.id] = n
        let b = base(p)
        let next = PollCadence.steadyInterval(base: b, unchanged: n)
        interval[p.id] = next
        let before = steadyLogged[p.id] ?? b
        guard next != before else { return }
        steadyLogged[p.id] = next
        let name = ProviderRegistry.logName(p.id)
        if next > before {
            log("\(name)：余额连续 \(n) 次没变，改为每 \(PollCadence.label(next))一次")
        } else {
            log("\(name)：恢复每 \(PollCadence.label(next))一次")
        }
    }

    /// 套餐平台近 1 小时额度已用的涨幅（百分点）；非套餐平台或这轮没取到返回 nil
    func quotaRise(_ id: ProviderID) -> Double? {
        guard isQuota(id), platforms.first(where: { $0.id == id })?.status == .ok else { return nil }
        let now = clock()
        let recent = (try? samples.samples(id, since: now.addingTimeInterval(-86400 - 1))) ?? []
        return QuotaActivity.risePP(recent, now: now)
    }

    /// 没有账单接口的平台：按余额采样估算今日 / 本月 / 近 7 天花费（近 7 天日均用来算续航）
    private func estimateSpend(_ s: inout ProviderSnapshot, _ p: UsageProvider, _ now: Date) {
        let tz = timeZone()
        let store = samples
        guard let e = try? spendCache.estimate(id: p.id, now: now, timeZone: tz, currency: p.capabilities.currency,
                                               load: { try store.balanceSamples(p.id, since: $0) }) else { return }
        s.today = Money(amount: e.today, currency: p.capabilities.currency)
        s.month = Money(amount: e.month, currency: p.capabilities.currency)
        s.trend7 = e.week
        s.source = .balanceEstimate
    }

    private func computeBurn(_ p: UsageProvider, _ s: ProviderSnapshot, _ now: Date) -> BurnStats {
        let recent = (try? samples.samples(p.id, since: now.addingTimeInterval(-86400 - 1))) ?? []
        return BurnCalculator.stats(samples: recent, now: now, tankRemaining: s.balance?.amount,
                                    weekCostByDay: s.trend7.map { $0.cost?.amount ?? 0 },
                                    observedSince: (try? samples.earliest(p.id)) ?? nil,
                                    billHistory: s.source == .bill, timeZone: p.capabilities.billingTimeZone ?? timeZone(),
                                    dailyAverage: s.trend7.isEmpty ? s.dailyAverage : nil,
                                    currency: s.balance?.currency ?? p.capabilities.currency)
    }

    /// 按紧迫程度汇总续航风险；预警线口径与异常列表一致。
    func risks(lowThreshold: [ProviderID: Decimal]? = nil) -> [PlatformRisk] {
        let now = clock()
        let thresholds = lowThreshold ?? settings().lowAlerts
        let inputs = platforms.map { st -> RiskInput in
            let threshold = thresholds[st.id]
            var below = false
            if isQuota(st.id) {
                if let remaining = st.snapshot?.quota?.remainingPercent(at: now),
                   let threshold = threshold, threshold > 0 {
                    below = remaining < AppDataMapping.double(threshold)
                }
                let tooOld = st.quotaTooOld(now: now)
                var status = st.status
                if case .stale = status, !tooOld { status = .ok }
                return RiskInput(id: st.id, status: status, payg: nil,
                                 quota: tooOld ? nil : Runway.quota(st.snapshot?.quota, risePP: quotaRise(st.id), now: now),
                                 belowThreshold: tooOld ? false : below)
            }
            if let balance = st.snapshot?.balance?.amount, let threshold = threshold, threshold > 0 {
                below = balance < threshold
            }
            return RiskInput(id: st.id, status: st.status,
                             payg: Runway.payg(balance: st.snapshot?.balance?.amount, burn: st.burn),
                             quota: nil, belowThreshold: below)
        }
        return RiskRanker.rank(inputs)
    }

    /// 这一轮有读数的平台（判断「低于预警线」用的同一份数：按量付费看余额，套餐看剩余百分比且不太旧）。
    /// 启动时正在连接的平台不在里面：提醒状态不能把它们当成「回到线上」
    func platformsWithReading() -> Set<ProviderID> {
        let now = clock()
        return Set(platforms.filter { st in
            if isQuota(st.id) { return !st.quotaTooOld(now: now) && st.snapshot?.quota?.remainingPercent(at: now) != nil }
            return st.snapshot?.balance != nil
        }.map(\.id))
    }

    /// 异常列表：先按平台顺序，再按严重程度
    func anomalies(lowThreshold: [ProviderID: Decimal]? = nil) -> [Anomaly] {
        let now = clock()
        let lowThreshold = lowThreshold ?? settings().lowAlerts
        var out: [Anomaly] = []
        for st in platforms where st.status != .hidden {
            if isQuota(st.id) {
                // 登录错误先进入 unknown 集合，旧额度不能让低额度提醒误认为已经恢复。
                if st.status == .credentialInvalid { out.append(.credentialInvalid(st.id)); continue }
                if st.status == .offline { out.append(.offline(st.id)); continue }
                if case .expiring(let days)? = st.snapshot?.credential, days <= 3 { out.append(.expiring(st.id)) }
                if st.quotaTooOld(now: now) { continue }
                if let r = st.snapshot?.quota?.remainingPercent(at: now),
                   let th = lowThreshold[st.id], th > 0, r < AppDataMapping.double(th) { out.append(.lowTank(st.id)) }
                continue
            }
            switch st.status {
            case .offline: out.append(.offline(st.id)); continue
            case .credentialInvalid, .keychainUnreadable: out.append(.credentialInvalid(st.id)); continue
            default: break
            }
            if let t = st.snapshot?.balance?.amount, let th = lowThreshold[st.id], th > 0, t < th { out.append(.lowTank(st.id)) }
            if st.burn?.spike == true { out.append(.spike(st.id)) }
            if case .expiring(let d)? = st.snapshot?.credential, d <= 3 { out.append(.expiring(st.id)) }
            if let s = st.snapshot, now.timeIntervalSince(s.fetchedAt) > Self.staleAfter { out.append(.stale(st.id)) }
        }
        return out
    }
}
