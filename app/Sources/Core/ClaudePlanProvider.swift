import Foundation

/// Claude 套餐的额度从哪来，二选一（用户在添加时选，设置里可以切换）
enum ClaudePlanSource: String, Equatable {
    /// Claude 桌面 App 自己记的 plan-usage-history.json（不改任何设置）
    case desktop
    /// 终端版 Claude Code 的状态栏钩子写的 claude-ratelimits.json
    case terminal

    static let defaultsKey = "claudePlan.source"

    /// 存着的值认得就用它；没存过（老用户）：钩子已装好当终端，否则当桌面。存过就不再看钩子
    static func resolve(stored: String?, hookInstalled: () -> Bool) -> ClaudePlanSource {
        if let s = stored.flatMap(ClaudePlanSource.init(rawValue:)) { return s }
        return hookInstalled() ? .terminal : .desktop
    }

    /// 读来源；没存过时按上面的迁移规则定下来并存住（之后钩子状态变了也不翻转）
    static func load(_ d: UserDefaults, hookInstalled: () -> Bool) -> ClaudePlanSource {
        let stored = d.string(forKey: defaultsKey)
        let s = resolve(stored: stored, hookInstalled: hookInstalled)
        if stored != s.rawValue { s.save(d) }
        return s
    }

    func save(_ d: UserDefaults) { d.set(rawValue, forKey: Self.defaultsKey) }

    /// 设置「平台」页 Claude 套餐那一行第二行的来源说明
    var label: String { self == .desktop ? L("claude.source.desktop") : L("claude.source.terminal") }
    /// 切换到另一种来源的操作名
    var switchTitle: String { self == .desktop ? L("claude.switch.toTerminal") : L("claude.switch.toDesktop") }
}

/// Claude 套餐：按来源查询；桌面命令行失败时补查，保留最后的可靠读数。
/// 终端：读状态栏钩子写的 claude-ratelimits.json（{"writtenAt": <Unix 秒>, "rate_limits": {…}}）；
/// 桌面：优先跑本机的 `claude -p /usage`（真实额度和重置时间，不花 token）；失败后补查两次；仅没有 claude 命令时
/// 退回 Claude 桌面 App 的 plan-usage-history.json（重置时间是推算的；记录过旧就只写停在什么时候）。
/// Token Bar 自己不联网、不登录，不读 ~/.claude/.credentials.json、~/.claude.json（命令行的登录由 claude 进程自己处理）
struct ClaudePlanProvider: UsageProvider {
    let quotaFile: URL
    let desktopFile: URL
    /// 每次取数时问一次来源（设置里切换后下一次取数就生效）
    let source: @Sendable () -> ClaudePlanSource
    /// 桌面来源先问命令行（测试里替换；默认当作没装）
    let cli: @Sendable (Date) async throws -> ClaudeCLIUsage.Outcome

    let desktopInstalled: @Sendable () -> Bool

    let retryDelays: [TimeInterval]
    let sleep: @Sendable (TimeInterval) async -> Void

    init(quotaFile: URL, desktopFile: URL = ClaudeAppUsageSource.standardURL,
         source: @escaping @Sendable () -> ClaudePlanSource = { .terminal },
         cli: @escaping @Sendable (Date) async throws -> ClaudeCLIUsage.Outcome = { _ in .notInstalled },
         desktopInstalled: @escaping @Sendable () -> Bool = { true },   // 测试默认当作装了，不看本机；真 App 由 ProviderRegistry 传实际检查
         retryDelays: [TimeInterval] = [5, 25],
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.quotaFile = quotaFile
        self.desktopFile = desktopFile
        self.source = source
        self.cli = cli
        self.desktopInstalled = desktopInstalled
        self.retryDelays = retryDelays
        self.sleep = sleep
    }

    var id: ProviderID { .claudePlan }
    var displayName: String { L("provider.claudePlan") }
    var capabilities: Capabilities {
        Capabilities(hasBalance: false, currency: .cny, minPollInterval: 60, dayBoundary: .local,
                     meter: .quota, needsCredentials: false)
    }
    var loginSteps: [LoginStep] { [] }

    func validate(_ c: Credentials) async -> ValidationResult { .ok(summary: "") }

    /// 钩子装了、文件还没出现（或只写了半个）。状态栏钩子只在终端版里运行，只用桌面版时会一直停在这里
    static var waitingNote: String { L("claude.waitingNote") }
    /// 文件里一个窗口都没有
    static var noWindowsNote: String { L("claude.noWindowsNote") }
    /// 桌面来源：文件还没有，或最近没有记录
    static var desktopWaitingNote: String { L("claude.desktopWaitingNote") }
    /// 没用上命令行的原因（接在桌面记录的说明后面）
    static var cliMissingHint: String { L("claude.cliMissingHint") }
    static func cliHint(_ o: ClaudeCLIUsage.Outcome) -> String? {
        switch o {
        case .notInstalled: return cliMissingHint
        case .failed(let why): return L("claude.cliFailed", why)
        case .unrecognized: return L("claude.cliUnrecognized")
        case .quota: return nil
        }
    }
    /// 桌面记录过旧：「Claude 桌面 App 的额度记录停在 10月16日 22:37」（今天的写「今天 08:05」）
    static func staleNote(_ latest: Date, now: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.isZh ? "zh_CN" : "en_US")
        f.timeZone = timeZone
        let today = cal.isDate(latest, inSameDayAs: now)
        f.dateFormat = L10n.isZh ? (today ? "'今天' HH:mm" : "M月d日 HH:mm") : (today ? "'\(L("claude.today"))' HH:mm" : "MMM d HH:mm")
        return L("claude.staleNote", f.string(from: latest))
    }

    func fetch(_ c: Credentials, now: Date, timeZone: TimeZone) async -> Result<ProviderSnapshot, ProviderError> {
        var s = ProviderSnapshot(provider: .claudePlan, balance: nil, today: nil, month: nil, byModel: [],
                                 trend7: [], source: .quota, fetchedAt: now, credential: .ok)
        if source() == .desktop {
            var viaCLI = (try? await cli(now)) ?? .failed(L("claude.cliError"))
            for delay in retryDelays {
                if viaCLI == ClaudeCLIUsage.throttled { break }
                switch viaCLI {
                case .quota, .notInstalled: break
                case .failed, .unrecognized:
                    await sleep(delay)
                    viaCLI = (try? await cli(now)) ?? .failed(L("claude.cliError"))
                    continue
                }
                break
            }
            if case .quota(let q) = viaCLI {
                s.quota = q
                return .success(s)
            }
            guard case .notInstalled = viaCLI else {
                return .failure(.unavailable(Self.cliHint(viaCLI)!))
            }
            let hint: String? = Self.cliMissingHint
            func note(_ base: String) -> String { [base, hint].compactMap { $0 }.joined(separator: L("common.sentenceSep")) }
            switch ClaudeAppUsageSource.read(desktopFile, now: now) {
            case .missing:
                s.quotaNote = desktopInstalled() ? note(Self.desktopWaitingNote) : L("claude.nothingInstalled")
            case .noRecentData: s.quotaNote = note(Self.desktopWaitingNote)
            case .stale(let t): s.quotaNote = note(Self.staleNote(t, now: now, timeZone: timeZone))
            case .quota(var q):
                q.estimated = true
                s.quota = q
            case .tooLarge: return .failure(.unavailable(L("claude.desktopTooLarge")))
            case .corrupt: return .failure(.schemaChanged(L("claude.desktopCorrupt")))
            case .unknownVersion: return .failure(.schemaChanged(L("claude.desktopUnknownVersion")))
            }
            return .success(s)
        }
        let data: Data
        do {
            data = try Data(contentsOf: quotaFile)
        } catch {
            guard !FileManager.default.fileExists(atPath: quotaFile.path) else {
                return .failure(.unavailable(L("provider.cantRead", quotaFile.path)))
            }
            s.quotaNote = Self.waitingNote
            return .success(s)
        }
        switch Self.read(data) {
        case .failure(let e): return .failure(e)
        case .notJSON: s.quotaNote = Self.waitingNote
        case .noWindows: s.quotaNote = Self.noWindowsNote
        case .quota(let q): s.quota = q
        }
        return .success(s)
    }

    /// 解析额度文件：不是合法 JSON（空文件、半个文件）或没有窗口时为 .success(nil)
    static func parse(_ data: Data) -> Result<Quota?, ProviderError> {
        switch read(data) {
        case .failure(let e): return .failure(e)
        case .notJSON, .noWindows: return .success(nil)
        case .quota(let q): return .success(q)
        }
    }

    private enum Parsed {
        case notJSON, noWindows, quota(Quota), failure(ProviderError)
    }

    private static func read(_ data: Data) -> Parsed {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .notJSON }
        let broken = ProviderError.schemaChanged(L("claude.formatChanged"))
        guard let written = (root["writtenAt"] as? NSNumber)?.doubleValue,
              let rl = root["rate_limits"] as? [String: Any] else { return .failure(broken) }
        var windows: [QuotaWindow] = []
        for (key, kind, minutes) in [("five_hour", QuotaWindow.Kind.session, 300), ("seven_day", .weekly, 10080)] {
            guard let o = rl[key], !(o is NSNull) else { continue }
            guard let w = o as? [String: Any], let used = (w["used_percentage"] as? NSNumber)?.doubleValue else {
                return .failure(broken)
            }
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(QuotaWindow(kind: kind, usedPercent: used, resetsAt: reset, windowMinutes: minutes))
        }
        if windows.isEmpty { return .noWindows }
        return .quota(Quota(plan: nil, windows: windows, observedAt: Date(timeIntervalSince1970: written)))
    }
}

extension ClaudeStatusLineInstaller {
    /// 真 App 用的默认路径：~/.claude/settings.json 与 ~/Library/Application Support/TokenBar
    static var standard: ClaudeStatusLineInstaller {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return ClaudeStatusLineInstaller(settingsURL: AgentDirs.current.claudeConfig.appendingPathComponent("settings.json"),
                                         supportDir: home.appendingPathComponent("Library/Application Support/TokenBar", isDirectory: true))
    }
}
