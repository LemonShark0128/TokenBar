import Combine
import Foundation

enum PlatformStatus: Equatable {
    /// 刚启动、第一次取数还没回来：不是离线，界面显示「正在连接」
    case loading
    case ok
    /// 这次没取到，显示的是 N 分钟前的数据
    case stale(minutes: Int)
    case credentialInvalid
    /// API Key 正常，但控制台登录失效（只剩余额）
    case consoleLoginNeeded
    /// 接口格式变了（与登录失效分开，重新登录也没用）
    case schemaChanged
    case rateLimited(until: Date)
    /// 从没取到过数据
    case offline
    /// 还没添加这个平台（钥匙串里没有、也没添加过）
    case notAdded
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
    /// 正在轮流显示的平台（主平台「当前使用」轮流列表；只有一个时不轮流）。面板标题旁的小圆点和菜单栏悬停提示用
    @Published private(set) var menuBarRotation: [ProviderID]
    /// 各平台最近一次本机任务活动时间（RunningTasks 扫出来的，只在内存里）
    private var runningLast: [ProviderID: Date] = [:]
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
    private let clock: () -> Date
    private let timeZone: () -> TimeZone
    private var baseInterval: TimeInterval
    private var interval: [ProviderID: TimeInterval] = [:]
    private var nextDue: [ProviderID: Date] = [:]
    /// 凭据失效后停止自动刷新，直到用户重新登录后手动刷新
    private var stopped: Set<ProviderID> = []
    private var timer: Timer?
    private var mainRotationTimer: Timer?
    private var mainRotation: [ProviderID] = []
    private var lastMainRotationAt: Date?
    private let log: (String) -> Void
    /// 取数失败的状态独立于界面的过时、离线等状态，只在失败和恢复之间记日志。
    private var fetchFailed: Set<ProviderID> = []
    private let defaults: UserDefaults
    private let snapshotCache: SnapshotCache?
    private let settings: () -> ProviderSettings
    /// 读到的凭据缓存在内存：钥匙串只在启动后第一次（或重新登录后）读一次，不在每轮刷新时读
    private var saving: [ProviderID: Task<Void, Error>] = [:]
    private var cache: [ProviderID: Credentials] = [:]
    private var reading: [ProviderID: Task<CredentialRead, Never>] = [:]
    /// 正在取数的平台：上一轮没回来就不再发起，避免请求叠加、旧结果覆盖新结果
    private var inFlight: Set<ProviderID> = []
    /// 套餐平台本机有没有在用（PollCadence）；还没扫过活动时没有这一项，按有活动处理（照旧的间隔）
    private var planActive: [ProviderID: Bool] = [:]
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

    private func addedKey(_ id: ProviderID) -> String { "accountAdded.\(id.rawValue)" }
    /// 用户添加过这个平台（以「已添加」标记为准；启动时状态还是 .loading，不能看状态）
    func isAdded(_ id: ProviderID) -> Bool { defaults.bool(forKey: addedKey(id)) }
    static let mainSwitchKey = "mainSwitch"
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
        ProviderRegistry.all.first { id in platforms.contains { $0.id == id && $0.status != .notAdded } } ?? .deepseek
    }

    /// 主平台必须是已添加的平台：当前主平台未添加（或不在列表里）时回落到第一个已添加的。回落不算切换
    private func ensureMainAdded() {
        let ok = platforms.contains { $0.id == switchState.main && $0.status != .notAdded }
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
        // 按当前状态现算（手动固定后 mainRotation 要等下一次 stepMainSwitch 才更新）
        let added = Set(platforms.filter { $0.status != .notAdded }.map(\.id))
        let rotation = MainSwitcher.rotation(switchState, lastActivity: runningLast, added: added, now: clock())
        let list = rotation.count > 1 ? rotation : [main]
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
        guard let s = lastAutoSwitch, s.to == mainProvider else { return nil }
        return L("switch.notice", ProviderRegistry.displayName(s.to))
    }

    /// 提示显示过（或面板开着时已播过动画）后清空
    func consumeAutoSwitch() { lastAutoSwitch = nil }

    /// 调试用：主平台换成第一个辅助平台（与面板辅助区同序），按一次自动切换处理，不暂停自动切换
    func demoSwitch() {
        guard let to = platforms.first(where: { $0.id != mainProvider && $0.status != .notAdded })?.id else { return }
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

    /// 每轮刷新、每次任务扫描后协调主平台；多平台只保留当前项，单平台切换才记提示
    private func stepMainSwitch() {
        let now = clock()
        let before = switchState.main
        let added = Set(platforms.filter { $0.status != .notAdded }.map(\.id))
        let list = MainSwitcher.rotation(switchState, lastActivity: runningLast, added: added, now: now)
        if list != mainRotation {
            mainRotation = list
            lastMainRotationAt = now
        }
        let next = MainSwitcher.step(switchState, lastActivity: runningLast, added: added, now: now)
        if next != switchState { switchState = next }
        if list.count > 1 {
            lastAutoSwitch = nil
        } else if switchState.main != before {
            lastAutoSwitch = (to: switchState.main, at: now)
        }
        ensureMainAdded()
    }

    /// 独立的 10 秒时钟推进轮流；扫描只协调列表，不抢走当前平台，不生成切换提示或冷却。
    func advanceMainRotation() {
        stepMainSwitch()
        let now = clock()
        guard mainRotation.count > 1,
              lastMainRotationAt.map({ now.timeIntervalSince($0) >= MainSwitcher.rotateInterval }) ?? true else { return }
        // 按原来的到期节拍推进，避免一次回调略迟、下次不足整 10 秒而漏轮流。
        let elapsed = now.timeIntervalSince(lastMainRotationAt ?? now)
        lastMainRotationAt = now.addingTimeInterval(-elapsed.truncatingRemainder(dividingBy: MainSwitcher.rotateInterval))
        lastAutoSwitch = nil
        switchState.main = MenuBarRotation.next(mainRotation, after: switchState.main)
    }

    /// 下次自动刷新的时间（各平台独立）
    func nextDueAt(_ id: ProviderID) -> Date? { nextDue[id] }

    /// 读凭据：先用内存缓存；要读钥匙串时放到后台线程（系统授权框弹出时不卡住菜单栏），同一平台同时只读一次
    func readCredentials(_ id: ProviderID) async -> CredentialRead {
        if let c = cache[id] { return .found(c) }
        if let t = reading[id] { return await t.value }
        let cs = credentials
        let t = Task.detached { cs.read(id) }
        reading[id] = t
        let r = await t.value
        reading[id] = nil
        if case .found(let c) = r {
            cache[id] = c
            defaults.set(true, forKey: addedKey(id))
        }
        return r
    }

    /// 保存（合并到已有凭据上，如只更新 webToken 时保留 API Key），然后立刻按新凭据取一次
    func saveCredentials(_ values: [String: String], for id: ProviderID) async throws {
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
            try await Task.detached { try cs.save(creds, for: id) }.value
            cache[id] = creds
            defaults.set(true, forKey: addedKey(id))
            stopped.remove(id)
            interval[id] = nil
            nextDue[id] = nil
        }
        saving[id] = task
        try await task.value
        if let p = providers.first(where: { $0.id == id }), !inFlight.contains(id) { await run(p) }
    }

    /// 添加免凭据平台（套餐平台读本地文件）：只写「添加过」标记，不碰钥匙串，然后立刻取一次
    func addCredentialFree(_ id: ProviderID) async {
        defaults.set(true, forKey: addedKey(id))
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
        }
        cache[id] = nil
        defaults.removeObject(forKey: addedKey(id))
        try? snapshotCache?.remove(id)
        stopped.insert(id)
        fetchFailed.remove(id)
        update(id) { $0 = PlatformState(id: id, snapshot: nil, burn: nil, status: .notAdded) }
    }

    /// 自动或手动发起取数前的统一检查：不叠加、不碰已停止的平台、限流期间不发
    private func canRun(_ id: ProviderID, _ now: Date) -> Bool {
        if inFlight.contains(id) || stopped.contains(id) { return false }
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
        let initial = providers.map { PlatformState(id: $0.id, snapshot: nil, burn: nil, status: .loading,
                                                    lastSampleAt: nil, lastSample: nil) }
        self.platforms = initial
        let sw = Self.loadSwitchState(defaults)
        self.switchState = sw
        // 旧版的「菜单栏平台」设置不再使用：删掉存的键，菜单栏跟着主平台
        for key in Self.legacyMenuBarKeys { defaults.removeObject(forKey: key) }
        self.menuBarProvider = sw.main
        self.menuBarRotation = [sw.main]
        ensureMainAdded()
    }

    private func base(_ p: UsageProvider) -> TimeInterval { max(baseInterval, p.capabilities.minPollInterval) }

    func currentInterval(_ id: ProviderID) -> TimeInterval {
        guard let p = providers.first(where: { $0.id == id }) else { return baseInterval }
        if p.capabilities.meter == .quota, let idle = PollCadence.idleInterval(id) {
            return PollCadence.quotaInterval(base: base(p), idle: idle, active: planActive[id] ?? true)
        }
        return interval[id] ?? base(p)
    }

    /// 下次到点：从上一次取数的起点算；套餐平台知道 5 小时窗口的重置时间时，重置后补刷一次
    private func reschedule(_ id: ProviderID, anchor: Date, now: Date) {
        let reset = isQuota(id)
            ? platforms.first { $0.id == id }?.snapshot?.quota?.windows.first { $0.kind == .session }?.resetsAt : nil
        nextDue[id] = PollCadence.nextDue(anchor: anchor, interval: currentInterval(id), resetAt: reset, now: now)
    }

    /// 本机 Claude / Codex 最近一次活动（在跑的任务、会话日志、桌面 App 的额度记录；由任务扫描交来，没有活动的平台不在里面）。
    /// 状态变了才写日志；从空闲变成有活动立即刷一次，变成空闲则按空闲间隔重排下次到点
    func setPlanActivity(_ last: [ProviderID: Date]) async {
        let now = clock()
        var ran = false
        for p in providers where p.capabilities.meter == .quota && PollCadence.idleInterval(p.id) != nil {
            let active = PollCadence.isActive(lastActivity: last[p.id], now: now)
            let was = planActive[p.id]
            guard was != active else { continue }
            planActive[p.id] = active
            guard isAdded(p.id), !stopped.contains(p.id) else { continue }
            let name = ProviderRegistry.logName(p.id)
            let every = PollCadence.label(currentInterval(p.id))
            if active {
                // 启动后第一次扫到有活动（was == nil）：刚取过，不补
                let refreshNow = was == false && canRun(p.id, now)
                log("\(name)：有活动，改为每 \(every)一次\(refreshNow ? "，立即刷新" : "")")
                if refreshNow { await run(p); ran = true }
            } else {
                log("\(name)：空闲，改为每 \(every)一次")
                if let a = lastRunAt[p.id], !inFlight.contains(p.id) { reschedule(p.id, anchor: a, now: now) }
            }
        }
        if ran { stepMainSwitch() }
    }

    /// 手动刷新（打开面板、点刷新、网络恢复）：不等到点，但遵守不叠加、限流退避和凭据失效停止；
    /// 凭据失效后要重新登录（saveCredentials）才恢复。id 为 nil 时刷新全部
    func refresh(_ id: ProviderID? = nil) async {
        let now = clock()
        var ran = false
        for p in providers where (id == nil || p.id == id) && canRun(p.id, now) {
            unchangedRuns[p.id] = 0         // 手动刷新、打开面板：按量付费平台回到设置的间隔
            await run(p)
            ran = true
        }
        if ran { stepMainSwitch() }
    }

    /// 计时器每拍允许的误差：这一拍比上一拍触发得早一点点，也算到点（否则顺延一整拍 15 秒）
    static let dueSlack: TimeInterval = PollCadence.dueSlack

    /// 定时器调用：只刷新到点且没被停止的平台。下次到点从这一拍算起，不从真正开始取数的时刻算——
    /// 前面的平台（如 claude 子进程）要花几秒，否则后面的平台每次都差一点没到点，2 分钟变成 2 分 15 秒（10-19 实测）
    func tick() async {
        let now = clock()
        var ran = false
        for p in providers where canRun(p.id, now) && PollCadence.isDue(nextDue: nextDue[p.id], now: now, interval: currentInterval(p.id)) {
            await run(p, scheduledAt: now)
            ran = true
        }
        if ran { stepMainSwitch() }
    }

    func start(intervalSeconds: Int) {
        baseInterval = TimeInterval(intervalSeconds)
        interval = [:]
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
        switch await readCredentials(p.id) {
        case .found(let c): creds = c
        case .notFound:
            // 添加过却读不到（在「钥匙串访问」里被删了）→ 凭据失效，提示重新登录；从没添加过 → 未添加
            stopped.insert(p.id)
            let added = defaults.bool(forKey: addedKey(p.id))
            update(p.id) { $0.status = added ? .credentialInvalid : .notAdded }
            return
        case .error(let status):
            // 拒绝授权等：停下自动刷新，免得反复弹授权框；钥匙串只是锁着（-25308）时下一轮再试
            if status != -25308 { stopped.insert(p.id) }
            update(p.id) { $0.status = .credentialInvalid }
            return
        }
        }
        let result = await p.fetch(creds, now: now, timeZone: timeZone())
        // 取数途中重新登录或移除了账号：这次结果属于旧凭据，作废（整分支评审 I-5 后半）。
        // 换了新凭据就马上按新凭据补取一次（saveCredentials 当时因为在途没有发起）
        guard cache[p.id] == creds else {
            if cache[p.id] != nil, !stopped.contains(p.id) { await run(p) }
            return
        }
        switch result {
        case .success:
            if fetchFailed.remove(p.id) != nil { log("\(ProviderRegistry.logName(p.id)) 取数恢复") }
        case .failure(let error):
            if fetchFailed.insert(p.id).inserted {
                let reason: String
                switch error {
                case .network(let m), .auth(let m), .schemaChanged(let m), .badRequest(let m), .unavailable(let m): reason = m
                case .rateLimited: reason = "被限流"
                }
                log("\(ProviderRegistry.logName(p.id)) 取数失败：\(reason)，稍后自动重试")
            }
        }
        switch result {
        case .success(let s) where isQuota:
            // 套餐平台：没有余额和 burn；只有数据比上一条采样新（真有新观测）才追加采样
            interval[p.id] = base(p)
            if let q = s.quota {
                let prev = try? samples.latest(p.id)
                if prev.map({ q.observedAt > $0.t }) ?? true {
                    try? samples.append(Sample(provider: p.id, t: q.observedAt, balance: nil, cumulativeCost: nil,
                                               currency: p.capabilities.currency,
                                               quotaUsed: q.activityWindow?.effectiveUsed(at: q.observedAt)))
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
        case .success(let s):
            noteSteady(p, s)
            // 有账单时用本月累计花费作采样（单调递增）；只有余额时用余额下降量
            try? samples.append(Sample(provider: p.id, t: now, balance: s.balance?.amount,
                                       cumulativeCost: s.source == .bill ? s.month?.amount : nil, currency: p.capabilities.currency))
            try? samples.prune(olderThan: now.addingTimeInterval(-Self.keepSamples))
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
            // 套餐取数失败保留最后的额度与时间；首次失败时可恢复磁盘快照。
            let detail: String?
            switch e {
            case .network(let m), .auth(let m), .schemaChanged(let m), .badRequest(let m), .unavailable(let m): detail = m
            case .rateLimited: detail = nil
            }
            update(p.id) { st in
                if case .schemaChanged = e {
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

    /// 按量付费平台取数成功：余额（和本月花费）跟上一次比，连续没变就放慢，变了回到设置的间隔；间隔变了才写日志
    private func noteSteady(_ p: UsageProvider, _ s: ProviderSnapshot) {
        let reading = [s.balance?.amount, s.month?.amount]
        let same = lastReading[p.id].map { $0 == reading } ?? false
        lastReading[p.id] = reading
        let n = same ? (unchangedRuns[p.id] ?? 0) + 1 : 0
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

    private func computeBurn(_ p: UsageProvider, _ s: ProviderSnapshot, _ now: Date) -> BurnStats {
        let recent = (try? samples.samples(p.id, since: now.addingTimeInterval(-86400 - 1))) ?? []
        return BurnCalculator.stats(samples: recent, now: now, tankRemaining: s.balance?.amount,
                                    weekCostByDay: s.trend7.map { $0.cost?.amount ?? 0 })
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

    /// 异常列表：先按平台顺序，再按严重程度
    /// 这一轮有读数的平台（判断「低于预警线」用的同一份数：按量付费看余额，套餐看剩余百分比且不太旧）。
    /// 启动时正在连接的平台不在里面：提醒状态不能把它们当成「回到线上」
    func platformsWithReading() -> Set<ProviderID> {
        let now = clock()
        return Set(platforms.filter { st in
            if isQuota(st.id) { return !st.quotaTooOld(now: now) && st.snapshot?.quota?.remainingPercent(at: now) != nil }
            return st.snapshot?.balance != nil
        }.map(\.id))
    }

    func anomalies(lowThreshold: [ProviderID: Decimal]? = nil) -> [Anomaly] {
        let now = clock()
        let lowThreshold = lowThreshold ?? settings().lowAlerts
        var out: [Anomaly] = []
        for st in platforms {
            if isQuota(st.id) {
                if st.quotaTooOld(now: now) { continue }
                // 套餐平台只看离线和低油量
                if st.status == .offline { out.append(.offline(st.id)); continue }
                if let r = st.snapshot?.quota?.remainingPercent(at: now),
                   let th = lowThreshold[st.id], th > 0, r < AppDataMapping.double(th) { out.append(.lowTank(st.id)) }
                continue
            }
            switch st.status {
            case .offline: out.append(.offline(st.id)); continue
            case .credentialInvalid: out.append(.credentialInvalid(st.id)); continue
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
