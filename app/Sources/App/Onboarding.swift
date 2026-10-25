import AppKit
import Combine
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
    /// 已添加平台的连接状态（选平台页的勾选颜色）；不给时已添加的都算已连接
    var states: [ProviderID: AccountState]?
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
    @State var message = ""
    @State var verified = false
    @State var busy = false
    /// Claude 套餐安装：settings.json 解析不了时显示的手动片段
    @State var claudeSnippet: String?
    @State var claudeInstalled = false
    /// Claude 套餐的来源：nil = 还没选（显示「选来源」页）；presetClaudeChoice 不为 nil 时跳过选择
    @State var claudeChoice: ClaudePlanSource?
    /// 「选来源」页当前点着的那一项（默认桌面 App）
    @State var claudePick: ClaudePlanSource = .desktop
    @State var claudeDesktopAdded = false
    @State var claudeDesktopHasData = false
    @State var claudeDesktopViaCLI = false
    let presetClaudeChoice: ClaudePlanSource?
    /// 刚复制过的代码框内容（那个框的按钮显示「已复制」）
    @State var copiedBox: String?
    /// 在选平台页移除过平台：done 页不再用（异步还没更新的）needsSetup 判断有没有平台
    @State var removedSome = false
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
        _step = State(initialValue: initialStep)
        // 只在第一次 init 时生效（@State 的初始值），之后的 init 读到的新值会被丢掉
        let added = preview?.added
            ?? Set(ProviderRegistry.all.filter { model.usageStore?.isAdded($0) == true })
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
            case .pick: pick
            case .menubar: menubar
            case .login: login
            case .done: done
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(width: 420, height: 372, alignment: .topLeading)
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
        apiKey = ""; message = ""; verified = false; busy = false
        claudeSnippet = nil; claudeInstalled = false; copiedBox = nil
        claudeChoice = presetClaudeChoice; claudePick = .desktop; claudeDesktopAdded = false; claudeDesktopHasData = false; claudeDesktopViaCLI = false
    }

    /// 当前平台办完（或跳过）：下一个平台，没有了就收尾
    func advance() {
        resetPlatform()
        if flow.advance() { step = .login; return }
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

    static var pickDetail: [ProviderID: String] { [
        .deepseek: L("ob.pick.deepseek"),
        .siliconflow: L("ob.pick.siliconflow"),
        .codexPlan: L("ob.pick.codex"),
        .claudePlan: L("ob.pick.claude"),
    ] }

    var pick: some View {
        // 4 个平台：标题带一句说明，行距放松，填满同一高度的窗口
        VStack(alignment: .leading, spacing: 12) {
            title(L("ob.pickTitle"), added.isEmpty ? L("ob.pickNote")
                                           : L("ob.pickNoteAdded"))
            SettingsGroup(title: L("page.platform"), p: p) {
                ForEach(Array(ProviderRegistry.all.enumerated()), id: \.element) { i, id in
                    let isAdded = added.contains(id)
                    let on = picked.contains(id)
                    let st = pickState(id)
                    pickRow(ProviderRegistry.displayName(id),
                            isAdded ? OnboardingPlan.addedDetail(on: on, state: st) : (Self.pickDetail[id] ?? ""),
                            check: OnboardingPlan.pickCheck(on: on, added: isAdded, state: st), first: i == 0) {
                        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
                    }
                }
            }
            next(only == nil ? OnboardingPlan.pickButton(picked: picked, added: added) : L("ob.next")) {
                // 取消勾选的已添加平台：先确认，确认后才移除；取消就留在这一页
                let removing = only == nil ? OnboardingPlan.toRemove(picked: picked, added: added) : []
                if preview == nil, !removing.isEmpty {
                    guard model.confirmRemove(removing) else { return }
                    let failed = removing.filter { !model.performRemove($0) }
                    connected.subtract(removing.filter { !failed.contains($0) })
                    removedSome = removedSome || failed.count < removing.count
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

    /// 勾选框：已连接的平台绿勾、新勾的蓝勾、已添加但没连上的灰勾；已添加的可以取消勾选，取消等于移除
    func pickRow(_ name: String, _ detail: String, check: OnboardingPlan.PickCheck, first: Bool = false,
                         toggle: @escaping () -> Void) -> some View {
        let on = check != .off
        return VStack(spacing: 0) {
            if !first { Hairline(p: p).padding(.leading, 12) }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundColor(check == .connected ? Accent.green : (check == .new ? Accent.blue : p.sub))
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 12.5, weight: .medium)).foregroundColor(p.text)
                    Text(detail).font(.system(size: 11)).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    var menubar: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(L("set.showWhich"), L("ob.showWhichNote"))
            SettingsGroup(title: L("set.showWhich"), p: p) {
                SettingsRow(label: L("ob.currentUseRec"), first: true, p: p) {
                    if menuBarAuto { Image(systemName: "checkmark").foregroundColor(Accent.blue) }
                }
                .contentShape(Rectangle())
                .onTapGesture { menuBarAuto = true }
                .accessibilityAddTraits(menuBarAuto ? .isSelected : [])
                ForEach(allPicked, id: \.self) { id in
                    SettingsRow(label: ProviderRegistry.displayName(id), p: p) {
                        if !menuBarAuto && chosenMenuBar == id { Image(systemName: "checkmark").foregroundColor(Accent.blue) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { menuBarAuto = false; menuBar = id }
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
        case .codexPlan: loginPlan
        case .claudePlan: loginClaudePlan
        }
    }
}
