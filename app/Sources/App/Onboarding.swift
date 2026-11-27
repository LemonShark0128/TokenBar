import AppKit
import SwiftUI

// ---------------------------------------------------------------- 首次引导

/// 离屏预览用的初始状态（真窗口不用）
struct OnboardingPreview {
    var picked: Set<ProviderID> = [.deepseek]
    /// 已添加的平台（选平台页里默认勾着、不用再验证）
    var added: Set<ProviderID> = []
    var loginIndex = 0
    /// Claude 套餐：settings.json 解析不了时要手动粘贴的片段（预览「没有安装」那一页）
    var claudeSnippet: String?
    /// Claude 套餐：已安装，停在「在终端里用一次 Claude Code」那一步
    var claudeInstalled = false
    /// Claude 套餐：已选的来源（nil = 停在「选来源」那一页）
    var claudeChoice: ClaudePlanSource?
    /// Claude 套餐（桌面来源）：已添加，停在结果页；hasData = 命令行或桌面 App 已有额度数据
    var claudeDesktopAdded = false
    var claudeDesktopHasData = false
    var claudeDesktopViaCLI = false
    /// 「用本机 Claude Code 查」结果页的情况（没装 / 没登录等）；nil 时按上面两项
    var claudeCLIResult: ClaudeDesktopResult?
    /// 「登录 claude.ai」已登录好
    var claudeWebDone = false
    /// 已添加平台的连接状态（选平台页的勾选颜色）；不给时已添加的都算已连接
    var states: [ProviderID: AccountState]?
    /// 管理页每行的读数（余额 / 剩余百分比）
    var readings: [ProviderID: AccountReading]?
}

/// Claude 套餐安装相关的文案（引导页和重装弹窗共用）
enum ClaudeHookCopy {
    static var unparseable: String { L("hook.unparseable") }
    static var hookGone: String { L("hook.gone") }
}

struct OnboardingView: View {
    @ObservedObject var model: UsageModel
    let p: Palette
    @State var step: OnboardingStep
    /// 勾选和待连接队列。必须放在 @State 里：界面每次刷新都会重新调用 init，
    /// 若按此刻的已添加平台重算，刚连上的平台会从队列里消失（第四批第 3 条：装好 Claude 套餐后跳成 DeepSeek 登录页）
    @State var flow: OnboardingFlow
    @State var menuBar: ProviderID = .deepseek
    /// 「显示哪个平台」选了「当前使用」（默认）；否则固定 menuBar
    @State var menuBarAuto = true
    @State var menuBarConfirmed = false
    @State var connected: Set<ProviderID> = []
    @State var apiKey = ""
    /// PackyAPI 的用户 ID（和访问令牌一起填；访问令牌借用 apiKey）
    @State var userId = ""
    @State var message = ""
    @State var verified = false
    @State var busy = false
    /// Claude 套餐安装：settings.json 解析不了时显示的手动片段
    @State var claudeSnippet: String?
    @State var claudeInstalled = false
    /// Claude 套餐的来源：nil = 还没选（显示「选来源」页）；presetClaudeChoice 不为 nil 时跳过选择
    @State var claudeChoice: ClaudePlanSource?
    /// 「选来源」页当前点着的那一项（默认桌面 App）
    @State var claudePick: ClaudePlanSource = .web
    @State var claudeDesktopAdded = false
    @State var claudeDesktopHasData = false
    @State var claudeDesktopViaCLI = false
    @State var claudeCLIResult: ClaudeDesktopResult?
    @State var claudeWebDone = false
    @State var claudeSessionInput = ""
    let presetClaudeChoice: ClaudePlanSource?
    /// 刚复制过的代码框内容（那个框的按钮显示「已复制」）
    @State var copiedBox: String?
    /// 在选平台页移除过平台：done 页不再用（异步还没更新的）needsSetup 判断有没有平台
    @State var removedSome = false
    /// 老用户从「添加 / 移除平台」进来：选平台这一步画管理页。放在 @State 里、只在打开时定下：
    /// 界面刷新会重跑 init，第一次引导中途连上第一个平台后不能突然变成管理页；移除光了也不变
    @State var manageMode: Bool
    /// 在管理页点了「添加」、正在走那一个平台的连接：办完回到管理页
    @State var manageAdding = false
    let preview: OnboardingPreview?

    init(model: UsageModel, initialStep: OnboardingStep = .welcome, p: Palette, only: ProviderID? = nil,
         claudeChoice: ClaudePlanSource? = nil, preview: OnboardingPreview? = nil) {
        self.model = model
        self.p = p
        self.preview = preview
        self.presetClaudeChoice = claudeChoice
        _claudeChoice = State(initialValue: preview?.claudeChoice ?? claudeChoice)
        _claudeDesktopAdded = State(initialValue: preview?.claudeDesktopAdded ?? false)
        _claudeDesktopHasData = State(initialValue: preview?.claudeDesktopHasData ?? false)
        _claudeDesktopViaCLI = State(initialValue: preview?.claudeDesktopViaCLI ?? false)
        _claudeCLIResult = State(initialValue: preview?.claudeCLIResult)
        _claudeWebDone = State(initialValue: preview?.claudeWebDone ?? false)
        _step = State(initialValue: initialStep)
        // 只在第一次 init 时生效（@State 的初始值），之后的 init 读到的新值会被丢掉
        let added = preview?.added
            ?? Set(ProviderRegistry.all.filter { model.usageStore?.isAdded($0) == true })
        _manageMode = State(initialValue: OnboardingPlan.showsManage(added: added, only: only))
        var flow = OnboardingFlow(added: added, only: only, picked: preview?.picked)
        if initialStep == .login { flow.startLogin(at: preview?.loginIndex ?? 0) }
        _flow = State(initialValue: flow)
        _connected = State(initialValue: added)
        // 「显示哪个平台」从现在的设置开始：已有平台时用户在这一步不改，就不写回、不动主平台
        if let store = model.usageStore, !store.switchState.auto { _menuBar = State(initialValue: store.mainProvider) }
        _menuBarAuto = State(initialValue: model.usageStore?.switchState.auto ?? true)
        _claudeSnippet = State(initialValue: preview?.claudeSnippet)
        _claudeInstalled = State(initialValue: preview?.claudeInstalled ?? false)
    }

    var added: Set<ProviderID> { flow.addedAtOpen }
    var only: ProviderID? { flow.only }
    var picked: Set<ProviderID> {
        get { flow.picked }
        nonmutating set { flow.picked = newValue }
    }
    /// 勾着的全部平台（含已添加的），菜单栏平台从这里选
    var allPicked: [ProviderID] { ProviderRegistry.all.filter { picked.contains($0) } }
    /// 正在连接的平台；队列走完为 nil（不回落到任何默认平台）
    var current: ProviderID? { flow.current }
    var chosenMenuBar: ProviderID { allPicked.contains(menuBar) ? menuBar : (allPicked.first ?? .deepseek) }
    var isLast: Bool { flow.isLast }

    var body: some View {
        // 各步高度统一：窗口只在打开时量一次高度，翻页时不跳；底部按钮固定在同一位置
        Group {
            switch step {
            case .welcome: welcome
            case .pick: if manageMode { manage } else { pick }
            case .menubar: menubar
            case .login: login
            case .done: done
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 22).padding(.vertical, 16)
        // 508 → 556（11/24）：8 个平台时选平台页（两组 8 行）和管理页放得下底部按钮
        .frame(width: 420, height: 556, alignment: .topLeading)
    }

    func title(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t).font(.system(size: 17, weight: .semibold)).foregroundColor(p.text)
            Text(sub).font(.system(size: 12)).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder func next(_ label: String = L("ob.next"), disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Spacer(minLength: 0)
        HStack {
            Spacer()
            Button(label, action: action).keyboardShortcut(.defaultAction).disabled(disabled)
        }
    }

    // 流程推进 ---------------------------------------------------------

    func resetPlatform() {
        apiKey = ""; userId = ""; message = ""; verified = false; busy = false
        claudeSnippet = nil; claudeInstalled = false; copiedBox = nil
        claudeChoice = presetClaudeChoice; claudePick = .web; claudeDesktopAdded = false; claudeDesktopHasData = false; claudeDesktopViaCLI = false
        claudeCLIResult = nil; claudeWebDone = false; claudeSessionInput = ""
    }

    /// 当前平台办完（或跳过）：下一个平台，没有了就收尾
    func advance() {
        resetPlatform()
        if flow.advance() { step = .login; return }
        // 从管理页点「添加」进来的：办完（或跳过）回到管理页，不动菜单栏设置
        if manageAdding { manageAdding = false; step = .pick; return }
        // 「显示哪个平台」：只有走过这一步才生效。当前使用：打开自动；固定：它确实连上了才生效
        if menuBarConfirmed, let store = model.usageStore {
            if menuBarAuto {
                if !store.switchState.auto { model.chooseMain("auto") }
            } else if connected.contains(chosenMenuBar) {
                model.chooseMain(chosenMenuBar.rawValue)
            }
        }
        step = .done
    }

    // 各页 -------------------------------------------------------------

    var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                GaugeLogo(value: 0.54, size: 40)
                title(AppName.display, L("ob.tagline"))
            }
            LT("ob.welcomeNote")
                .font(.system(size: 12.5)).foregroundColor(p.text).fixedSize(horizontal: false, vertical: true)
            next(L("ob.start")) { step = .pick }
        }
    }

    var pick: some View {
        // 第一次打开：按量付费 / 套餐两组，每行一句短说明（窗口定高，英文也要放得下底部按钮）；老用户进来走管理页（manage）
        // 不用 ScrollView：离屏预览画不出 ScrollView 的内容
        VStack(alignment: .leading, spacing: 12) {
            title(L("ob.pickTitle"), added.isEmpty ? L("ob.pickNote")
                                           : L("ob.pickNoteAdded"))
            pickGroups
            next(only == nil ? OnboardingPlan.pickButton(picked: picked, added: added) : L("ob.next")) {
                // 取消勾选的已添加平台：先确认，确认后才移除；取消就留在这一页
                let removing = only == nil ? OnboardingPlan.toRemove(picked: picked, added: added) : []
                if preview == nil, !removing.isEmpty {
                    guard model.confirmRemove(removing) else { return }
                    let failed = removing.filter { !model.performRemove($0) }
                    connected.subtract(removing.filter { !failed.contains($0) })
                    removedSome = removedSome || failed.count < removing.count
                    // 移除的正好是固定显示的平台：UsageStore 会改回自动切换（异步，这里还读不到），
                    // 页面里打开时读的「固定」也要跟着改，否则下一步会把回落的平台重新固定
                    if !menuBarAuto, removing.contains(menuBar), !failed.contains(menuBar) { menuBarAuto = true }
                    // 没移除成功的（Claude 套餐还原不了状态栏设置）：勾回去、留在这一页，并说明原因
                    if !failed.isEmpty {
                        picked.formUnion(failed)
                        let a = NSAlert()
                        a.messageText = L("ob.notRemoved", failed.map(ProviderRegistry.displayName).joined(separator: L("common.listSep")))
                        a.informativeText = failed.compactMap { model.reloginNotes[$0]?.text }.joined(separator: "\n")
                        a.runModal()
                        return
                    }
                }
                step = flow.pending.isEmpty ? .done : .menubar
            }
        }
    }

    /// 已添加平台此刻的连接状态（只决定勾的颜色和副标题，不影响连接队列）
    func pickState(_ id: ProviderID) -> AccountState? {
        if let preview { return preview.states?[id] ?? (preview.added.contains(id) ? .ok : nil) }
        return UsageModel.accountState(for: model.usageStore?.platforms.first { $0.id == id })
    }

    var menubar: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(L("set.showWhich"), L("ob.showWhichNote"))
            SettingsGroup(title: L("set.showWhich"), p: p) {
                Button { menuBarAuto = true } label: {
                    SettingsRow(label: L("ob.currentUseRec"), first: true, p: p) {
                        if menuBarAuto { Image(systemName: "checkmark").foregroundColor(Accent.blue).accessibilityHidden(true) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(menuBarAuto ? .isSelected : [])
                ForEach(allPicked, id: \.self) { id in
                    Button { menuBarAuto = false; menuBar = id } label: {
                        SettingsRow(label: ProviderRegistry.displayName(id), p: p) {
                            if !menuBarAuto && chosenMenuBar == id { Image(systemName: "checkmark").foregroundColor(Accent.blue).accessibilityHidden(true) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(!menuBarAuto && chosenMenuBar == id ? .isSelected : [])
                }
            }
            next { menuBarConfirmed = true; flow.startLogin(); resetPlatform(); step = .login }
        }
    }

    @ViewBuilder var login: some View {
        switch current {
        case nil: Color.clear.onAppear { advance() }   // 队列已空：走 advance 收尾（含菜单栏写回），不在登录步骤里画完成页
        case .deepseek: loginDeepSeek
        case .siliconflow: loginSiliconFlow
        case .kimi: loginKimi
        case .openrouter: loginOpenRouter
        case .packyapi: loginPackyAPI
        case .codexPlan, .geminiPlan: loginPlan
        case .claudePlan: loginClaudePlan
        }
    }
}
