import AppKit
import Combine
import SwiftUI

// ---------------------------------------------------------------- 账号：首次引导、网页登录入口、账号分组

enum OnboardingStep: Int, CaseIterable {
    /// 预览图文件名用序号，不要改顺序
    case welcome, pick, menubar, login, done
}

extension UsageModel {
    static func accountState(for st: PlatformState?) -> AccountState {
        AccountState.of(st)
    }

    /// 各平台账号状态和已添加平台（设置页与菜单栏右键菜单共用同一算法）
    static func accountStates(_ inp: AccountsInput) -> (states: [ProviderID: AccountState], added: [ProviderID]) {
        var states: [ProviderID: AccountState] = [:]
        for id in ProviderRegistry.all { states[id] = accountState(for: inp.platforms.first { $0.id == id }) }
        return (states, SettingsLayout.added(states))
    }

    /// 设置「账号」分组的数据：真 App 来自 UsageStore；离屏预览没有 store，用 mainState 和默认设置（结果才可重复）
    @MainActor var accountsInput: AccountsInput {
        if let s = usageStore {
            return AccountsInput(platforms: s.platforms, mainID: s.mainProvider, auto: s.switchState.auto,
                                 settings: ProviderSettings.load(.standard))
        }
        return AccountsInput(platforms: mainState.map { [$0] } ?? [], mainID: mainID, auto: true,
                             settings: ProviderSettings())
    }

    @MainActor
    /// claudeChoice：添加 Claude 套餐时跳过「选来源」，直接进那种来源的页（设置里「改用终端版」用）
    func openOnboarding(at step: OnboardingStep = .welcome, platform: ProviderID? = nil, claudeChoice: ClaudePlanSource? = nil) {
        Hud.windows["onboarding"]?.orderOut(nil)
        // 老用户从「添加 / 移除平台」进来是管理页：窗口标题跟着写，不再写「欢迎使用」。
        // 已有平台却还没点过引导的「完成」（上次中途关了窗）：不再从欢迎页开始，直接进管理页
        let hasAdded = OnboardingPlan.showsManage(
            added: Set(ProviderRegistry.all.filter { usageStore?.isAdded($0) == true }), only: platform)
        let step = step == .welcome && hasAdded ? .pick : step
        let manage = step == .pick && hasAdded
        _ = Hud.toggle(key: "onboarding", title: manage ? L("ob.manageTitle") : L("win.welcome", AppName.display),
                       size: CGSize(width: 420, height: 556), opaque: true,     // 高度只用于第一次建窗，实际按内容量（以 OnboardingView 的定高为准）
                       themed: (self, { p in AnyView(OnboardingView(model: self, initialStep: step, p: p, only: platform,
                                                                    claudeChoice: claudeChoice)) }),
                       origin: { size in
                           let sc = NSScreen.main?.visibleFrame ?? .zero
                           return NSPoint(x: sc.midX - size.width / 2, y: sc.midY - size.height / 2)
                       })
    }

    /// 校验并保存 API Key（DeepSeek / Kimi；合并保存：保留已有的控制台登录）。钥匙串读写都由 UsageStore 放在后台线程做
    @MainActor
    func saveApiKey(_ key: String, for id: ProviderID) async -> (ok: Bool, message: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = await ProviderRegistry.makeProvider(id, http: URLSessionHTTPClient()).validate(Credentials(values: ["apiKey": trimmed]))
        let msg = ValidationCopy.message(for: r, provider: id)
        guard case .ok = r, let store = usageStore else { return (false, msg) }
        do { try await store.saveCredentials(["apiKey": trimmed], for: id) }
        catch { return (false, L("keychain.saveFailed", error)) }
        logLine("\(ProviderRegistry.logName(id)) API Key 已验证并存入钥匙串")
        return (true, msg)
    }

    /// 校验并保存控制台访问令牌 + 用户 ID（PackyAPI）。日志只写平台名，不写令牌和用户 ID
    @MainActor
    func saveAccessToken(_ token: String, userId: String, for id: ProviderID) async -> (ok: Bool, message: String) {
        let values = ["accessToken": token.trimmingCharacters(in: .whitespacesAndNewlines),
                      "userId": userId.trimmingCharacters(in: .whitespacesAndNewlines)]
        let r = await ProviderRegistry.makeProvider(id, http: URLSessionHTTPClient()).validate(Credentials(values: values))
        let msg = ValidationCopy.message(for: r, provider: id)
        guard case .ok = r, let store = usageStore else { return (false, msg) }
        do { try await store.saveCredentials(values, for: id) }
        catch { return (false, L("keychain.saveFailed", error)) }
        logLine("\(ProviderRegistry.logName(id)) 访问令牌已验证并存入钥匙串")
        return (true, msg)
    }

    /// Starting either path supersedes every earlier Claude sign-in attempt.
    @MainActor
    func beginClaudeLogin() -> ClaudeLoginAttempts.Ticket {
        let attempt = claudeLoginAttempts.begin()
        WebLoginController.current?.stop()
        WebLoginController.current = nil
        Hud.discard("weblogin")
        return attempt
    }

    /// Both capture paths share persistence acknowledgement, then source activation and refresh.
    @MainActor
    func saveClaudeSession(_ input: String, attempt: ClaudeLoginAttempts.Ticket,
                           onPersisted: @escaping () -> Void = {},
                           onDone: @escaping (Bool, String) -> Void) async {
        guard attempt.isCurrent else { return }
        guard let store = usageStore else { onDone(false, L("claudeWeb.unrecognized")); return }
        let result = await ClaudeBrowserLogin.connect(input, isCurrent: { attempt.isCurrent }, validate: { key in
            if case .failure(let error) = await ClaudeWebUsage.fetch(
                http: URLSessionHTTPClient(cookies: false), sessionKey: key, now: Date()) { return error }
            return nil
        }, save: { key in
            try await store.saveCredentials([ClaudeWebUsage.credentialKey: key], for: .claudePlan,
                                            attempt: attempt, onPersisted: onPersisted, refresh: false)
        }, activate: {
            self.setClaudeSource(.web)
            self.reloginNotes[.claudePlan] = nil
        })
        guard attempt.isCurrent else { return }
        logLine(result.ok ? "claude.ai 登录成功" : "claude.ai 登录验证或保存失败")
        if result.ok { await store.refresh(.claudePlan) }
        guard attempt.isCurrent else { return }
        onDone(result.ok, result.message)
    }

    /// 内嵌 WKWebView 登录控制台：DeepSeek 读 localStorage 的 userToken；硅基流动读登录 Cookie 和 subject id。
    /// 硅基流动取到后先拉一次余额验证，通过才存；onDone 收到（是否成功, 给用户看的话）
    @MainActor
    /// onCancel：用户没登录就关掉了登录窗（引导页要把「等待登录」复位）
    func openWebLogin(_ id: ProviderID, onDone: ((Bool, String) -> Void)? = nil, onCancel: (() -> Void)? = nil,
                      onPersisted: @escaping () -> Void = {}) {
        let url: URL, capture: WebLoginController.Capture, title: String, hint: String?
        switch id {
        case .deepseek:
            url = URL(string: "https://platform.deepseek.com/sign_in")!
            capture = .localStorage(key: "userToken"); title = L("login.dsConsole")
            hint = L("login.dsProxyHint")
        case .siliconflow:
            url = SiliconFlowProvider.consoleURL
            capture = .cookie(name: "__SF_auth.session-token", domain: ".siliconflow.cn"); title = L("ob.sf.title")
            hint = nil
        case .claudePlan:
            // Claude 套餐「登录 claude.ai」来源（用户 11/6 选）：取 sessionKey Cookie；Google 账号常被拦，提示改用邮箱
            url = ClaudeWebUsage.loginURL
            capture = .claudeSession; title = L("ob.claude.webTitle")
            hint = L("ob.claude.webGoogle")
        default: return
        }
        let claudeAttempt = id == .claudePlan ? beginClaudeLogin() : nil
        WebLoginController.installCloseKeyMonitor()
        WebLoginController.current?.stop()          // 再次打开时先停掉上一个，免得后台继续每秒轮询
        let controller = WebLoginController(url: url, capture: capture) { [weak self] values in
            if let claudeAttempt, !claudeAttempt.isCurrent { return }
            WebLoginController.current?.stop()
            WebLoginController.current = nil
            // 这里还在网页的回调里：下一轮再拆掉窗口和网页
            let capturedWindow = Hud.windows["weblogin"]
            DispatchQueue.main.async {
                if Hud.windows["weblogin"] === capturedWindow { Hud.discard("weblogin") }
            }
            guard let store = self?.usageStore else { onDone?(false, L("claudeWeb.unrecognized")); return }
            Task { @MainActor in
                var msg = L("relogin.signedIn")
                if id == .claudePlan {
                    guard let self, let claudeAttempt, claudeAttempt.isCurrent else { return }
                    await self.saveClaudeSession(values[ClaudeWebUsage.credentialKey] ?? "", attempt: claudeAttempt,
                                                 onPersisted: onPersisted, onDone: { onDone?($0, $1) })
                    return
                }
                if id == .siliconflow {
                    let r = await SiliconFlowProvider().validate(Credentials(values: values))
                    msg = ValidationCopy.message(for: r, provider: id,
                                                 expiresInDays: ValidationCopy.daysLeft(expiresAt: values["webTokenExpiresAt"], now: Date()))
                    guard case .ok = r else {
                        logLine("硅基流动登录验证未通过")
                        onDone?(false, msg)
                        return
                    }
                }
                do {
                    try await store.saveCredentials(values, for: id)
                    logLine("\(ProviderRegistry.logName(id)) 登录成功，登录凭证已存入钥匙串")
                    onDone?(true, msg)
                } catch {
                    logLine("登录凭证存进钥匙串失败：\(error)")
                    onDone?(false, L("keychain.saveFailed", error))
                }
            }
        }
        WebLoginController.current = controller
        Hud.discard("weblogin")                       // 上一次的登录窗（如果还在）连网页一起放掉，下面新建
        Hud.onClose["weblogin"] = {                  // 用户没登录就关窗：停止轮询、释放网页
            // 登录成功时控制器已清掉（窗口只是收起）；还在等就是用户取消
            let cancelled = WebLoginController.current === controller
            if cancelled {
                controller.stop()
                WebLoginController.current = nil
                if claudeAttempt?.isCurrent != false { onCancel?() }
            }
            let closingWindow = Hud.windows["weblogin"]
            DispatchQueue.main.async {
                if Hud.windows["weblogin"] === closingWindow { Hud.discard("weblogin") }
            }   // 正在关窗：下一轮再放掉网页
        }
        _ = Hud.toggle(key: "weblogin", title: title, size: CGSize(width: 480, height: 680), plain: true,
                       origin: { size in
                           let sc = NSScreen.main?.visibleFrame ?? .zero
                           return NSPoint(x: sc.midX - size.width / 2, y: sc.midY - size.height / 2)
                       },
                       content: AnyView(VStack(spacing: 0) {
                           if let hint {
                               Text(hint).font(.system(size: 11)).foregroundColor(.secondary)
                                   .fixedSize(horizontal: false, vertical: true)
                                   .frame(maxWidth: .infinity, alignment: .leading)
                                   .padding(.horizontal, 12).padding(.vertical, 6)
                           }
                           WebLoginContent(controller: controller).frame(maxHeight: .infinity)
                       }.frame(width: 480, height: 680)))
    }

    /// 添加套餐平台（读本机文件，不需要凭据）：只记「添加过」，随后立刻取一次
    @MainActor
    func addPlanPlatform(_ id: ProviderID) async {
        await usageStore?.addCredentialFree(id)
    }

    /// 兼容旧入口：登录 DeepSeek 控制台
    @MainActor
    func openConsoleLogin() { openWebLogin(.deepseek) }

    @MainActor
    func removeAccount(_ id: ProviderID) {
        guard confirmRemove([id]) else { return }
        performRemove(id)
    }

    /// 移除确认框（设置里的「移除」和选平台页取消勾选共用）：点了「移除」返回 true
    @MainActor
    func confirmRemove(_ ids: [ProviderID]) -> Bool {
        guard !ids.isEmpty else { return true }
        let a = NSAlert()
        let c = OnboardingPlan.removeConfirm(ids, claudeRestoresHook: !ids.contains(.claudePlan) || claudeRemoveRestoresHook)
        a.messageText = c.title
        a.informativeText = c.detail
        a.addButton(withTitle: L("remove.button"))
        a.addButton(withTitle: L("ob.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    /// 暂时隐藏 / 显示平台（今天页卡片右键、底部「显示」、管理页「显示」）：登录和「已添加」都保留。
    /// 隐藏时把安静时段里攒着的它的提醒也丢掉（不刷新了，旧提醒不该再冒出来）
    @MainActor func setPlatformHidden(_ id: ProviderID, _ hidden: Bool) {
        guard let store = usageStore else { return }
        if hidden {
            var backlog = QuietBacklog.load(.standard)
            backlog.remove(id)
            backlog.save(.standard)
            if detailPlatform == id { showTodayHome() }
        }
        Task { @MainActor in await store.setHidden(id, hidden) }
    }

    /// 确认过以后真正移除：Claude 套餐先还原状态栏设置，再从 UsageStore 删掉。
    /// 返回 false 表示没有移除（Claude 套餐的状态栏设置还原不了，原因写在 reloginNotes 里）
    @MainActor @discardableResult
    func performRemove(_ id: ProviderID) -> Bool {
        guard let store = usageStore else { return false }
        let isPlan = ProviderRegistry.meter(id) == .quota
        reloginNotes[id] = nil
        // Claude 套餐：先还原状态栏设置（桌面来源且没留着钩子时不碰任何文件）；
        // 还原不了（记录的原设置读不出来、写不进去）就不移除，免得钩子没人管
        var restoreNote: ReloginNote?
        if id == .claudePlan {
            if claudeRemoveRestoresHook {
                let r = restoreClaudeHook()
                guard r.ok else {
                    if let n = reloginNotes[id] { reloginNotes[id] = ReloginNote(text: n.text + L("remove.claudeNotRemoved"), isError: true) }
                    return false
                }
                restoreNote = r.note
            }
            UserDefaults.standard.removeObject(forKey: ClaudePlanSource.defaultsKey)
        }
        Task { @MainActor in
            do {
                try await store.removeAccount(id)
                platformAlerts.forget(id)
                platformAlerts.save(.standard)
                AlertMute.unmute(id)
                var backlog = QuietBacklog.load(.standard)
                backlog.remove(id)
                backlog.save(.standard)
                if let n = restoreNote { reloginNotes[id] = n }
                updateProviderSettings { s in
                    s.lowAlerts[id] = nil
                    s.hourlyAlerts[id] = nil
                }
                // 套餐平台清掉预警线会存成「关闭」；移除时删掉这个键，再添加时回到默认 10%
                if isPlan { UserDefaults.standard.removeObject(forKey: ProviderSettings.lowAlertKey(id)); objectWillChange.send() }
                // 仅移除固定的主平台时，UsageStore.removeAccount 会恢复自动切换；其他情况保留原设置。
                logLine(isPlan ? "已移除 \(ProviderRegistry.logName(id))" : "已移除 \(ProviderRegistry.logName(id))（钥匙串凭据已删除）")
            } catch { logLine("移除 \(ProviderRegistry.logName(id)) 失败：\(error)") }
        }
        return true
    }

    /// 启动时：已有凭据 → 直接用；没有 → 打开首次引导。
    /// 读钥匙串出错（如拒绝授权）时什么都不问：那不是「没添加」
    @MainActor
    func startupAccountsCheck() {
        guard !kRendering, let store = usageStore else { return }
        Task { @MainActor in
            let d = UserDefaults.standard
            // 任一平台读到凭据就算引导完成；读出错（如拒绝授权）时什么都不问
            var readFailed = false
            for id in ProviderID.allCases {
                switch await store.readCredentials(id) {
                case .found: d.set(true, forKey: "onboardingDone"); return
                case .error: readFailed = true
                case .notFound: break
                }
            }
            if readFailed { return }
            // 只添加了不需要凭据的套餐平台：钥匙串里什么都没有，也算引导完成（自查 Bug E）
            if ProviderID.allCases.contains(where: { store.isAdded($0) }) { d.set(true, forKey: "onboardingDone"); return }
            if !d.bool(forKey: "onboardingDone") { openOnboarding() }
        }
    }
}

// ---------------------------------------------------------------- 设置「平台」页的账号数据

/// 设置「平台」「显示」「提醒」页要用的账号数据（真 App 来自 UsageStore，预览直接给）
struct AccountsInput {
    var platforms: [PlatformState]
    var mainID: ProviderID
    var auto: Bool
    var settings: ProviderSettings
    var customDirs: [AgentDirKind: String] = [:]
}

/// 金额输入框：只接受正数，空 = 清除；停手 0.8 秒后才提交，避免每敲一个字就存一次
struct AmountField: View {
    let placeholder: String
    let onCommit: (Decimal?) -> Void
    @State private var text: String
    @State private var pending: Task<Void, Never>?

    init(value: Decimal?, placeholder: String, onCommit: @escaping (Decimal?) -> Void) {
        self.placeholder = placeholder
        self.onCommit = onCommit
        _text = State(initialValue: value.map { "\($0)" } ?? "")
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder).frame(width: 72).font(.num(12, .regular))
            .onChange(of: text) { _, v in
                let t = v.trimmingCharacters(in: .whitespaces)
                let parsed = Decimal(string: t, locale: Locale(identifier: "en_US_POSIX"))
                guard t.isEmpty || (parsed ?? 0) > 0 else { return }
                pending?.cancel()
                pending = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if !Task.isCancelled { onCommit(t.isEmpty ? nil : parsed) }
                }
            }
    }
}
