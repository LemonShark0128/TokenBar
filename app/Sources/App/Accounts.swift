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

    var accountState: AccountState {
        if needsSetup { return .notAdded }
        return Self.accountState(for: mainState ?? PlatformState(id: mainID, snapshot: nil, burn: nil, status: .offline))
    }

    /// 设置「账号」分组的数据：真 App 来自 UsageStore；离屏预览没有 store，用 mainState 和默认设置（结果才可重复）
    @MainActor var accountsInput: AccountsInput {
        if let s = usageStore {
            return AccountsInput(platforms: s.platforms, mainID: s.mainProvider, auto: s.switchState.auto,
                                 menuBar: s.menuBarProvider, settings: ProviderSettings.load(.standard))
        }
        return AccountsInput(platforms: mainState.map { [$0] } ?? [], mainID: mainID, auto: true,
                             menuBar: mainID, settings: ProviderSettings())
    }

    @MainActor
    /// claudeChoice：添加 Claude 套餐时跳过「选来源」，直接进那种来源的页（设置里「改用终端版」用）
    func openOnboarding(at step: OnboardingStep = .welcome, platform: ProviderID? = nil, claudeChoice: ClaudePlanSource? = nil) {
        Hud.windows["onboarding"]?.orderOut(nil)
        _ = Hud.toggle(key: "onboarding", title: L("win.welcome", AppName.display), size: CGSize(width: 420, height: 420),
                       themed: (self, { p in AnyView(OnboardingView(model: self, initialStep: step, p: p, only: platform,
                                                                    claudeChoice: claudeChoice)) }),
                       origin: { size in
                           let sc = NSScreen.main?.visibleFrame ?? .zero
                           return NSPoint(x: sc.midX - size.width / 2, y: sc.midY - size.height / 2)
                       })
    }

    /// 校验并保存 API Key（合并保存：保留已有的控制台登录）。钥匙串读写都由 UsageStore 放在后台线程做
    @MainActor
    func saveDeepSeekKey(_ key: String) async -> (ok: Bool, message: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = await DeepSeekProvider().validate(Credentials(values: ["apiKey": trimmed]))
        let msg = ValidationCopy.message(for: r, provider: .deepseek)
        guard case .ok = r, let store = usageStore else { return (false, msg) }
        do { try await store.saveCredentials(["apiKey": trimmed], for: .deepseek) }
        catch { return (false, L("keychain.saveFailed", error)) }
        logLine("DeepSeek API Key 已验证并存入钥匙串")
        return (true, msg)
    }

    /// 内嵌 WKWebView 登录控制台：DeepSeek 读 localStorage 的 userToken；硅基流动读登录 Cookie 和 subject id。
    /// 硅基流动取到后先拉一次余额验证，通过才存；onDone 收到（是否成功, 给用户看的话）
    @MainActor
    /// onCancel：用户没登录就关掉了登录窗（引导页要把「等待登录」复位）
    func openWebLogin(_ id: ProviderID, onDone: ((Bool, String) -> Void)? = nil, onCancel: (() -> Void)? = nil) {
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
        default: return
        }
        WebLoginController.installCloseKeyMonitor()
        WebLoginController.current?.stop()          // 再次打开时先停掉上一个，免得后台继续每秒轮询
        let controller = WebLoginController(url: url, capture: capture) { [weak self] values in
            WebLoginController.current?.stop()
            WebLoginController.current = nil
            // 这里还在网页的回调里：下一轮再拆掉窗口和网页
            DispatchQueue.main.async { Hud.discard("weblogin") }
            guard let store = self?.usageStore else { return }
            Task { @MainActor in
                var msg = L("relogin.signedIn")
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
            WebLoginController.current?.stop()
            WebLoginController.current = nil
            if cancelled { onCancel?() }
            DispatchQueue.main.async { Hud.discard("weblogin") }   // 正在关窗：下一轮再放掉网页
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
                if let n = restoreNote { reloginNotes[id] = n }
                updateProviderSettings { s in s.lowAlerts[id] = nil }
                // 套餐平台清掉预警线会存成「关闭」；移除时删掉这个键，再添加时回到默认 10%
                if isPlan { UserDefaults.standard.removeObject(forKey: ProviderSettings.lowAlertKey(id)); syncAlertFromSettings() }
                // 菜单栏固定的就是被移除的这个：UsageStore.removeAccount 已改回自动跟随
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
    /// 菜单栏显示的平台（10-19 起永远等于主平台）
    var menuBar: ProviderID
    var settings: ProviderSettings
    /// 旧的离屏预览还会设置它；菜单栏不再单独选平台，这个值不再影响任何界面
    var menuBarAuto = true
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
