import Foundation

// ---------------------------------------------------------------- 设置面板（侧栏偏好设置）：四页的排布，纯逻辑

/// 账号在界面上的状态（设置「账号」分组每行显示）
enum AccountState: Equatable {
    case notAdded, connecting, ok, balanceOnly, consoleExpired, invalid, offline
    /// 登录会话快到期（硅基流动）
    case expiring(days: Int)

    /// 平台状态 → 设置「账号」行的状态
    static func of(_ st: PlatformState?) -> AccountState {
        guard let st = st else { return .notAdded }
        switch st.status {
        case .notAdded: return .notAdded
        case .loading: return .connecting
        case .credentialInvalid: return .invalid
        case .consoleLoginNeeded: return .consoleExpired
        case .schemaChanged, .rateLimited, .stale, .offline:
            // 出错且手里没有这次运行取到的数据（首次就失败）：不能显示「正常」
            if st.snapshot == nil || st.snapshotFromDisk { return .offline }
            fallthrough
        default:
            if case .expiring(let d)? = st.snapshot?.credential { return .expiring(days: d) }
            return st.snapshot?.source == .balanceOnly ? .balanceOnly : .ok
        }
    }

    /// 账号行右侧的状态文字
    var label: String {
        switch self {
        case .notAdded: return L("acct.notAdded")
        case .connecting: return L("acct.connecting")
        case .ok: return L("acct.ok")
        case .balanceOnly: return L("acct.balanceOnly")
        case .consoleExpired: return L("acct.consoleExpired")
        case .invalid: return L("acct.invalid")
        case .offline: return L("acct.offline")
        case .expiring(let d): return d <= 0 ? L("acct.expiresToday") : L("acct.expiresInDays", d)
        }
    }

    /// 账号行的状态文字：套餐平台读的是本机文件，出错时不说「连不上」
    func label(for id: ProviderID) -> String {
        if self == .offline, ProviderRegistry.meter(id) == .quota { return L("acct.noLocalRecords") }
        return label
    }

    /// 状态文字的颜色档：正常 / 灰 / 需要处理
    enum Tone { case good, neutral, warn }
    var tone: Tone {
        switch self {
        case .ok: return .good
        case .balanceOnly, .notAdded, .connecting: return .neutral
        default: return .warn
        }
    }
}

/// 侧栏的四个分类（顺序即侧栏顺序）
enum SettingsPage: String, CaseIterable {
    case platform, menuBar, alerts, general
    var title: String {
        switch self {
        case .platform: return L("page.platform")
        case .menuBar: return L("page.menuBar")
        case .alerts: return L("page.alerts")
        case .general: return L("page.general")
        }
    }
    /// 侧栏图标（SF Symbols 名）
    var symbol: String {
        switch self {
        case .platform: return "square.stack.3d.up"
        case .menuBar: return "menubar.rectangle"
        case .alerts: return "bell"
        case .general: return "gearshape"
        }
    }
}

/// 平台行第二行的当前读数
enum AccountReading: Equatable {
    /// 按量付费：余额（currency 为 "USD" 时写 $，其余写 ¥）
    case money(Double, currency: String?)
    /// 套餐：5 小时窗口剩余百分比
    case session(Double)
    /// 套餐没有 5 小时窗口：每周窗口（没有则第一个窗口）的剩余百分比
    case remaining(Double)

    static func from(balance: Money?, quota: Quota?, meter: Meter, now: Date) -> AccountReading? {
        switch meter {
        case .money:
            guard let b = balance else { return nil }
            return .money(NSDecimalNumber(decimal: b.amount).doubleValue, currency: b.currency.rawValue)
        case .quota:
            guard let q = quota else { return nil }
            if let s = q.windows.first(where: { $0.kind == .session }) { return .session(100 - s.effectiveUsed(at: now)) }
            return q.displayRemainingPercent(at: now).map { .remaining($0) }
        }
    }

    var text: String {
        switch self {
        case .money(let v, let c): return L("reading.balance", fmtMoney(v, c))
        case .session(let v): return L("reading.sessionUsed", quotaUsedPercent(remaining: v))
        case .remaining(let v): return L("reading.used", quotaUsedPercent(remaining: v))
        }
    }
}

/// 设置里的一行（顺序即界面顺序）
enum SettingsRowID: Equatable {
    case mainPlatform
    case account(ProviderID), addPlatform
    case launchAtLogin, refreshInterval, exchangeRate, updateCheck, diagnostics
    case menuBarMode
    case theme, transparency, widget
    case tank
    case alert(ProviderID), alertCustom(ProviderID), fuelFull
    case alertRepeat
    case spikeAlert
    /// 提醒表头区分金额与百分比；套餐共用重置前耗尽开关
    case alertHeader(quota: Bool), runoutAlert
}

struct SettingsSection: Equatable {
    /// 空字符串 = 不画分组标题
    var title: String
    var rows: [SettingsRowID]
}

/// 「···」菜单里的一项
struct AccountAction: Equatable {
    enum Kind: Equatable { case setMain, apiKey, console, webRelogin, reinstallHook, switchClaudeSource, remove }
    let kind: Kind
    let title: String
    var destructive: Bool { kind == .remove }
}

enum SettingsLayout {
    typealias Option = (key: String, label: String)

    /// 已添加的平台，按界面顺序
    static func added(_ states: [ProviderID: AccountState]) -> [ProviderID] {
        ProviderRegistry.all.filter { (states[$0] ?? .notAdded) != .notAdded }
    }

    /// 还没添加、可以从「＋ 添加平台」加的平台
    static func addable(added: [ProviderID]) -> [ProviderID] {
        ProviderRegistry.all.filter { !added.contains($0) }
    }

    /// 设置里添加套餐平台（直接添加、首次读本机记录）进行中，「＋ 添加平台」那一行换成这句
    static func addingText(_ id: ProviderID) -> String { L("settings.adding", ProviderRegistry.displayName(id)) }

    /// 「＋ 添加平台」一行：还有没添加的平台才显示
    static func showsAddPlatform(added: [ProviderID]) -> Bool { !addable(added: added).isEmpty }

    /// 每页有哪些分组、每组有哪些行。main：主平台（nil = 没有已添加的平台）
    static func sections(_ page: SettingsPage, added: [ProviderID], main: ProviderID?,
                         customOpen: Set<ProviderID>) -> [SettingsSection] {
        switch page {
        case .platform:
            var accounts = added.map { SettingsRowID.account($0) }
            if showsAddPlatform(added: added) { accounts.append(.addPlatform) }
            return [SettingsSection(title: L("section.display"), rows: [.mainPlatform]),
                    SettingsSection(title: L("section.addedPlatforms"), rows: accounts)]
        case .menuBar:
            return [SettingsSection(title: L("section.menuBar"), rows: [.menuBarMode]),
                    SettingsSection(title: L("section.panelWindows"), rows: [.theme, .transparency, .widget])]
        case .alerts:
            let platforms = alertPlatforms(added: added)
            let money = platforms.filter { ProviderRegistry.meter($0) == .money }
            let quota = platforms.filter { ProviderRegistry.meter($0) == .quota }
            func rows(_ ids: [ProviderID], quota: Bool) -> [SettingsRowID] {
                var out: [SettingsRowID] = [.alertHeader(quota: quota)]
                for id in ids {
                    out.append(.alert(id))
                    if customOpen.contains(id) { out.append(.alertCustom(id)) }
                }
                if quota { out.append(.runoutAlert) }
                return out
            }
            // 余额规格只随按量付费主平台显示；有平台时才显示充值提醒。
            var top: [SettingsRowID] = [.tank]
            if let main, added.contains(main), ProviderRegistry.meter(main) == .money { top.append(.fuelFull) }
            var out = [SettingsSection(title: scaleTitle(main: main), rows: top)]
            if !money.isEmpty { out.append(SettingsSection(title: L("section.payg"), rows: rows(money, quota: false))) }
            if !quota.isEmpty { out.append(SettingsSection(title: L("section.plans"), rows: rows(quota, quota: true))) }
            out.append(SettingsSection(title: L("section.alerts"), rows: platforms.isEmpty ? [.spikeAlert] : [.alertRepeat, .spikeAlert]))
            return out
        case .general:
            return [SettingsSection(title: L("section.thisMac"), rows: [.launchAtLogin, .refreshInterval, .exchangeRate, .updateCheck, .diagnostics])]
        }
    }

    /// 「余额预警」里列哪些平台：已添加的全部（按界面顺序）
    static func alertPlatforms(added: [ProviderID]) -> [ProviderID] {
        ProviderRegistry.all.filter { added.contains($0) }
    }

    /// 「···」菜单：按平台原有能力给操作，最后一项总是「移除…」。
    /// Claude 套餐按来源：终端有「重装状态栏钩子」；两种来源都能切换到另一种
    static func accountActions(_ id: ProviderID, state: AccountState, isMain: Bool,
                               claudeSource: ClaudePlanSource = .terminal) -> [AccountAction] {
        var out: [AccountAction] = []
        if !isMain { out.append(AccountAction(kind: .setMain, title: L("action.pinIt"))) }
        switch id {
        case .deepseek:
            out.append(AccountAction(kind: .apiKey, title: state == .invalid ? L("action.relogin") : L("action.changeKey")))
            out.append(AccountAction(kind: .console, title: state == .balanceOnly ? L("action.loginConsole") : L("action.reloginConsole")))
        case .siliconflow:
            out.append(AccountAction(kind: .webRelogin, title: L("action.relogin")))
        case .codexPlan:
            break       // 读本机记录，不需要登录
        case .claudePlan:
            if claudeSource == .terminal { out.append(AccountAction(kind: .reinstallHook, title: L("action.reinstallHook"))) }
            out.append(AccountAction(kind: .switchClaudeSource, title: claudeSource.switchTitle))
        }
        out.append(AccountAction(kind: .remove, title: L("action.remove")))
        return out
    }

    /// 行内突出当前需要处理的一项；重装钩子只适用于 Claude 套餐。
    static func urgentAction(_ id: ProviderID, state: AccountState, hookGone: Bool) -> AccountAction? {
        switch (id, state) {
        case (.deepseek, .balanceOnly): return AccountAction(kind: .console, title: L("action.loginConsole"))
        case (.deepseek, .consoleExpired): return AccountAction(kind: .console, title: L("action.reloginConsole"))
        case (.deepseek, .invalid): return AccountAction(kind: .apiKey, title: L("action.relogin"))
        case (.siliconflow, .invalid), (.siliconflow, .expiring):
            return AccountAction(kind: .webRelogin, title: L("action.relogin"))
        case (.claudePlan, _) where hookGone:
            return AccountAction(kind: .reinstallHook, title: L("action.reinstallHook"))
        default: return nil
        }
    }

    /// 菜单按操作类型排除行内紧急操作，保持其余顺序，「移除…」始终在最后。
    static func menuActions(_ id: ProviderID, state: AccountState, isMain: Bool,
                            claudeSource: ClaudePlanSource, hookGone: Bool) -> [AccountAction] {
        let urgent = urgentAction(id, state: state, hookGone: hookGone)
        return accountActions(id, state: state, isMain: isMain, claudeSource: claudeSource)
            .filter { $0.kind != urgent?.kind }
    }

    /// 平台行第二行状态文字之后的部分：当前读数 + 简短说明（都没有为 nil）。
    /// 失效、连不上、正在连接时不写读数（可能是旧数）；stale：数据源已停止更新（Claude 套餐钩子不在了），也不写。
    /// Claude 套餐总写上额度来自哪里
    static func accountDetail(_ id: ProviderID, state: AccountState, reading: AccountReading?, stale: Bool = false,
                              claudeSource: ClaudePlanSource = .terminal) -> String? {
        var parts: [String] = []
        var showReading: Bool
        switch state {
        case .invalid, .offline, .connecting, .notAdded: showReading = false
        default: showReading = true
        }
        if stale { showReading = false }
        if showReading, let r = reading { parts.append(r.text) }
        switch id {
        case .codexPlan: parts.append(L("acct.note.codexLocal"))
        case .claudePlan:
            parts.append(claudeSource.label)
            if reading == nil && !stale && (state == .ok || state == .connecting) {
                parts.append(claudeSource == .desktop ? L("acct.note.claudeDesktop") : L("acct.note.claudeTerminal"))
            }
        default: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: 说明文字

    /// 提醒页顶部进度条的名字（用户 2026-10-17 定名：原「油箱」→「余额标尺」→「余额进度条」）：主平台是套餐时叫「额度进度条」
    static func scaleTitle(main: ProviderID?) -> String {
        main.map { ProviderRegistry.meter($0) == .quota } == true ? L("settings.quotaBar") : L("settings.balanceBar")
    }

    /// 「显示哪个平台」那一行的说明：按选中值写真实规则（MainSwitcher：10 分钟内在跑的任务、多个轮流、都没在跑保持）。
    /// 面板和菜单栏共用这一个设置（用户 10-19）
    static func mainHelp(auto: Bool, main: ProviderID) -> String {
        auto ? L("settings.mainAutoNote") : L("settings.mainPinnedNote", ProviderRegistry.displayName(main))
    }

    // MARK: 下拉选项与选中值

    static func mainOptions(added: [ProviderID]) -> [Option] {
        [("auto", L("opt.currentUse"))] + added.map { ($0.rawValue, L("opt.pinned", ProviderRegistry.displayName($0))) }
    }

    /// 主平台下拉的选中值：自动，或固定的那个（它已不在已添加里时按「自动」显示）
    static func mainSelection(auto: Bool, main: ProviderID, added: [ProviderID]) -> String {
        !auto && added.contains(main) ? main.rawValue : "auto"
    }

    static var menuBarModeOptions: [Option] { [("balance", L("opt.mb.balance")), ("cost", L("opt.mb.cost")), ("icon", L("opt.mb.icon"))] }
    static var themeOptions: [Option] { [("light", L("opt.theme.light")), ("dark", L("opt.theme.dark")), ("system", L("opt.theme.system"))] }
    static func refreshLabel(_ s: Int) -> String { s < 60 || s % 60 != 0 ? L("opt.seconds", s) : L("opt.minutes", s / 60) }
    /// 各平台 minPollInterval 都是 60 秒，30 秒选了也不生效，所以不提供（自查第 3 条）
    static var refreshOptions: [Option] { [60, 120, 300].map { ("\($0)", refreshLabel($0)) } }
    static let fuelFullOptions: [Option] = [20, 50, 100, 200].map { ("\($0)", "¥\($0)") }

    static let alertPresets: [Double] = [5, 10, 20]

    /// 「每小时花费超过」下拉：关 / ¥1 / ¥2 / ¥5 / ¥10（默认关）
    static let hourlyPresets: [Int] = [1, 2, 5, 10]
    static func hourlyOptions(symbol: String = "¥") -> [Option] {
        [("0", L("opt.off"))] + hourlyPresets.map { ("\($0)", "\(symbol)\($0)") }
    }
    /// 选中值：没设为「0」（关）；其余按整数写（旧值不在预设里时由 fallback 显示）
    static func hourlySelection(_ v: Decimal?) -> String {
        guard let v, v > 0 else { return "0" }
        return "\(NSDecimalNumber(decimal: v).intValue)"
    }

    /// 预警线下拉：按量付费是金额，套餐是剩余百分比
    static func alertOptions(quota: Bool, symbol: String = "¥") -> [Option] {
        [("0", L("opt.offLong"))] + alertPresets.map { v in ("\(Int(v))", quota ? "\(Int(v))%" : "\(symbol)\(Int(v))") }
            + [("custom", L("opt.custom"))]
    }

    /// 预警线下拉的选中值：选过「自定义」或值不在预设里 → 自定义；0 → 关闭
    static func alertSelection(value: Double, custom: Bool) -> String {
        if custom { return "custom" }
        if value <= 0 { return "0" }
        return alertPresets.contains(value) ? "\(Int(value))" : "custom"
    }

    /// 选中值对应的显示文字；不在选项里（旧版存的值）时显示 fallback，没给就显示原值，不冒充第一项
    static func label(of key: String, in options: [Option], fallback: String? = nil) -> String {
        options.first { $0.key == key }?.label ?? fallback ?? key
    }

    /// 主平台下拉选中后要做的事：pin = 先把主平台换成它（已经是它就不换），auto = 自动切换开关
    struct MainPick: Equatable { var pin: ProviderID?; var auto: Bool }
    static func mainPick(_ key: String, current: ProviderID) -> MainPick {
        guard let id = ProviderID(rawValue: key) else { return MainPick(pin: nil, auto: true) }
        return MainPick(pin: id == current ? nil : id, auto: false)
    }

    /// 预警线的写入：打开自定义输入，或写入一个值（nil = 关闭）
    enum AlertWrite: Equatable { case custom, set(Decimal?), ignore }
    static func alertPick(_ key: String) -> AlertWrite {
        if key == "custom" { return .custom }
        return .set(key == "0" ? nil : Decimal(string: key))
    }
    /// 自定义输入框：套餐预警线是百分比，超过 100 不收；主平台清空输入不改（同原来），其他平台清空等于关闭
    static func customAlertInput(_ d: Decimal?, quota: Bool, isMain: Bool) -> AlertWrite {
        if let d, quota, d > 100 { return .ignore }
        if d == nil && isMain { return .ignore }
        return .set(d)
    }
}
