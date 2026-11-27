import AppKit
import SwiftUI

// ---------------------------------------------------------------- 首次引导：Claude 套餐的几页（选来源、桌面 App、终端版钩子）

extension OnboardingView {
    /// Claude 套餐：先选额度来源（设置里的「添加」也走这一页）。
    /// 桌面 App：不改任何文件，直接添加；终端版：先说明要改什么，用户点「安装」才装状态栏钩子
    @ViewBuilder var loginClaudePlan: some View {
        let inst = model.claudeInstaller
        if claudeChoice == nil {
            claudeChooseSource
        } else if claudeChoice == .desktop {
            claudeDesktopStep
        } else if claudeChoice == .web {
            claudeWebStep
        } else if let snippet = claudeSnippet {
            VStack(alignment: .leading, spacing: 10) {
                title(L("ob.claude.notInstalled"), ClaudeHookCopy.unparseable)
                codeBox(snippet)          // 复制按钮在框里
                // 手动这条路没有记原命令，钩子没法转发：要说清楚原来的状态栏会被替换
                LT("ob.claude.manualNote")
                    .font(.system(size: 11)).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack {
                    Button(L("ob.later")) { advance() }.buttonStyle(.plain).foregroundColor(p.sub).font(.system(size: 12)).disabled(busy)
                    Spacer()
                    Button(L("ob.claude.manualDone")) {
                        busy = true
                        Task { @MainActor in
                            logLine("用户已手动加好 Claude Code 状态栏钩子")
                            await model.addPlanPlatform(.claudePlan)
                            connected.insert(.claudePlan)
                            // 手动加的钩子同样只在终端版里运行：也要进「在终端里启动」这一步
                            model.setClaudeSource(.terminal)
                            busy = false
                            claudeSnippet = nil
                            claudeInstalled = true
                        }
                    }.keyboardShortcut(.defaultAction).disabled(busy)
                }
            }
        } else if claudeInstalled {
            claudeTerminalStep
        } else {
            VStack(alignment: .leading, spacing: 12) {
                title(L("ob.claude.addTitle"), L("ob.claude.hookIntro"))
                VStack(alignment: .leading, spacing: 5) {
                    sectionLabel(L("ob.claude.changes"))
                    bullet(L("ob.claude.changeOnly"))
                    codeBox((inst.hookURL.path as NSString).abbreviatingWithTildeInPath)
                    bullet(L("ob.claude.changeDir"))
                    bullet(L("ob.claude.changeNothingElse"))
                }
                VStack(alignment: .leading, spacing: 5) {
                    sectionLabel(L("ob.claude.undo"))
                    bullet(L("ob.claude.backup"))
                    codeBox(L("ob.claude.backupFile"))
                    bullet(L("ob.claude.restore"))
                }
                if !message.isEmpty {
                    Text(message).font(.system(size: 12)).foregroundColor(p.warnText).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack {
                    // 从「选来源」页进来的可以返回重选；从设置的「改用终端版」进来的直接取消
                    Button(presetClaudeChoice == nil ? L("ob.back") : L("ob.cancel")) {
                        if presetClaudeChoice == nil { message = ""; claudeChoice = nil }
                        else { Hud.windows["onboarding"]?.performClose(nil) }
                    }.buttonStyle(.plain).foregroundColor(p.sub).font(.system(size: 12)).disabled(busy)
                    Spacer()
                    // 真机 10-17：用户把上面的路径复制给 Claude 让它自己改，其实点按钮就会自动改好（窗口定高，放在按钮旁边不占行）
                    if model.claudeHookState != .installed && !busy {
                        LT("ob.claude.autoFix").font(.system(size: 11.5, weight: .medium)).foregroundColor(Accent.blue)
                            .lineLimit(1)
                    }
                    Button(ClaudeStatusLineInstaller.confirmButtonTitle(state: model.claudeHookState, busy: busy)) {
                        busy = true; message = ""
                        Task { @MainActor in
                            do {
                                switch try await model.installClaudeHook() {
                                case .installed, .alreadyInstalled:
                                    connected.insert(.claudePlan)
                                    busy = false
                                    claudeInstalled = true
                                case .unparseable(let s):
                                    busy = false
                                    claudeSnippet = s
                                }
                            } catch {
                                busy = false
                                message = L("ob.installFailed", error.localizedDescription)
                            }
                        }
                    }.keyboardShortcut(.defaultAction).disabled(busy)
                }
            }
        }
    }

    /// 选额度来源：两种只用一种，之后可以在设置里切换
    var claudeChooseSource: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(L("ob.claude.addTitle"), L("ob.claude.whereIntro"))
            // 三种来源（用户 11/6）：登录 claude.ai 放第一个、推荐（不用装 Claude Code）
            SettingsGroup(title: L("ob.claude.source"), p: p) {
                sourceRow(.web, L("ob.claude.srcWeb"), L("ob.claude.srcWebDetail"), first: true)
                sourceRow(.desktop, L("ob.claude.srcDesktop"), L("ob.claude.srcDesktopDetail"))
                sourceRow(.terminal, L("ob.claude.srcTerminal"),
                          L("ob.claude.srcTerminalDetail"))
            }
            Spacer(minLength: 0)
            HStack {
                Button(L("ob.later")) { advance() }.buttonStyle(.plain).foregroundColor(p.sub).font(.system(size: 12))
                Spacer()
                Button(L("ob.next")) {
                    claudeChoice = claudePick
                    if claudePick == .desktop { addDesktop() }
                }.keyboardShortcut(.defaultAction)
            }
        }
    }

    func sourceRow(_ src: ClaudePlanSource, _ name: String, _ detail: String, first: Bool = false) -> some View {
        let on = claudePick == src
        return VStack(spacing: 0) {
            if !first { Hairline(p: p).padding(.leading, 12) }
            // 真按钮：读屏能按、键盘能 Tab 到；选中状态由 isSelected 读，圆点图标不单独念
            Button { claudePick = src } label: { HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(on ? Accent.blue : p.sub).font(.system(size: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 12.5, weight: .medium)).foregroundColor(p.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.system(size: 11)).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    /// 「用本机 Claude Code 查」：不改任何文件，记下来源后直接添加；再查一次命令行，按结果决定结果页怎么说
    func addDesktop() {
        guard preview == nil else { return }
        busy = true
        Task { @MainActor in
            await model.addClaudeDesktop()
            connected.insert(.claudePlan)
            await checkClaudeCLI()
            claudeDesktopAdded = true
        }
    }

    /// 查一次命令行（和桌面 App 的旧记录），定下结果页的情况；查到了顺便让面板马上刷新
    func checkClaudeCLI() async {
        busy = true
        let cli = await ClaudeCLIUsage.standard(now: Date())
        var desktop = false
        if case .quota = ClaudeAppUsageSource.read(ClaudeAppUsageSource.standardURL, now: Date()) { desktop = true }
        let r = ClaudeDesktopResult.of(cli: cli, desktopHasData: desktop)
        claudeCLIResult = r
        claudeDesktopViaCLI = r == .gotCLI
        claudeDesktopHasData = r == .gotCLI || r == .gotDesktop
        logLine("Claude Code 命令行检查：\(r == .gotCLI ? "读到额度" : r == .needsLogin ? "没登录" : r == .notInstalled ? "没装" : "没查到")")
        if r == .gotCLI { await model.usageStore?.refresh(.claudePlan) }
        busy = false
    }

    /// 「用本机 Claude Code 查」的结果页（proposal-claude-source-copy 乙）：查到了说已添加；
    /// 没登录给「打开终端登录」「重新检查」；没装给安装说明和「重新检查」，并提示可以返回改用登录 claude.ai
    var claudeDesktopStep: some View {
        let r = claudeCLIResult ?? (claudeDesktopViaCLI ? .gotCLI : claudeDesktopHasData ? .gotDesktop : .notInstalled)
        return VStack(alignment: .leading, spacing: 12) {
            switch r {
            case .gotCLI, .gotDesktop:
                title(claudeDesktopAdded ? L("ob.claude.added") : L("ob.adding"),
                      r == .gotCLI ? L("ob.claude.gotViaCLI") : L("ob.claude.gotDesktop"))
                VStack(alignment: .leading, spacing: 5) {
                    bullet(L("ob.claude.noFilesChanged"))
                    bullet(L("ob.claude.switchHint"))
                }
            case .needsLogin:
                title(L("ob.claude.cliNeedsLogin"), L("ob.claude.cliNeedsLoginNote"))
                HStack(spacing: 10) {
                    Button { openClaudeLoginTerminal() } label: { Label(L("ob.claude.cliOpenLogin"), systemImage: "terminal") }
                    recheckButton
                }
            case .notInstalled:
                title(L("ob.claude.cliMissing"), L("ob.claude.cliMissingNote"))
                HStack(spacing: 10) {
                    Button(L("ob.claude.installGuide")) {
                        NSWorkspace.shared.open(URL(string: ClaudeStatusLineInstaller.installGuideURL)!)
                    }
                    recheckButton
                }
            case .failed(let why):
                title(L("ob.claude.cliFailedTitle"), why)
                recheckButton
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundColor(p.warnText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                // 没查到时可以返回改选来源（如改用登录 claude.ai）；从设置的「改用 …」进来的没有选来源页
                if r != .gotCLI && r != .gotDesktop && presetClaudeChoice == nil {
                    Button(L("ob.back")) { message = ""; claudeChoice = nil; claudeCLIResult = nil }
                        .buttonStyle(.plain).foregroundColor(p.sub).font(.system(size: 12)).disabled(busy)
                }
                Spacer()
                Button(OnboardingPlan.stepButton(isLast: isLast)) { advance() }.keyboardShortcut(.defaultAction)
                    .disabled(!claudeDesktopAdded || busy)
            }
        }
    }

    var recheckButton: some View {
        Button(busy ? L("ob.checking") : L("ob.claude.cliRecheck")) {
            guard preview == nil else { return }
            Task { @MainActor in await checkClaudeCLI() }
        }.disabled(busy)
    }

    /// 打开终端并启动 claude（同终端钩子那一步的启动脚本），用户在里面输入 /login
    func openClaudeLoginTerminal() {
        guard preview == nil else { return }
        do {
            let url = try model.claudeInstaller.writeTerminalLauncher()
            NSWorkspace.shared.open(url)
            logLine("已打开终端启动 Claude Code（登录用）")
        } catch {
            message = L("ob.terminalFailed", error.localizedDescription)
        }
    }

    /// 默认浏览器登录后粘贴 sessionKey；内置登录窗作为备用。验证并保存后才切换来源。
    var claudeWebStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if claudeWebDone {
                title(L("ob.claude.added"), L("ob.claude.webGot"))
                VStack(alignment: .leading, spacing: 5) {
                    bullet(L("ob.claude.webStored"))
                    bullet(L("ob.claude.switchHint"))
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        title(L("ob.claude.webTitle"), L("ob.claude.webIntro"))
                        Button {
                            guard preview == nil else { return }
                            NSWorkspace.shared.open(ClaudeWebUsage.loginURL)
                        } label: {
                            Label(L("ob.claude.webBrowser"), systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }.controlSize(.large).disabled(busy)
                        ForEach(["ob.claude.webStep1", "ob.claude.webStep2", "ob.claude.webSafari", "ob.claude.webStep3"], id: \.self) { key in
                            Text(L(key)).font(.system(size: 12)).foregroundColor(p.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SecureField(L("ob.claude.webPaste"), text: $claudeSessionInput)
                            .textFieldStyle(.roundedBorder).disabled(busy)
                            .onSubmit { saveClaudeSession() }
                        if !message.isEmpty {
                            Text(message).font(.system(size: 12)).foregroundColor(p.warnText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button(busy ? L("ob.checking") : L("ob.claude.webSave")) {
                            saveClaudeSession()
                        }.disabled(busy)
                        Text(L("ob.claude.webStored")).font(.system(size: 11)).foregroundColor(p.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("ob.claude.webEmbedded")) {
                            guard preview == nil else { return }
                            busy = true; message = ""
                            model.openWebLogin(.claudePlan, onDone: { ok, msg in
                                busy = false
                                if ok {
                                    claudeSessionInput = ""
                                    connected.insert(.claudePlan); claudeWebDone = true
                                } else { message = msg }
                            }, onCancel: { busy = false }, onPersisted: { claudeSessionInput = "" })
                        }.buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Accent.blue).disabled(busy)
                        Text(L("ob.claude.webGoogle")).font(.system(size: 11)).foregroundColor(p.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            HStack {
                if !claudeWebDone {
                    // 登录窗开着时不让返回：免得改选别的来源后又在登录窗里登录成功、来源被翻回网页登录（审核建议）
                    Button(presetClaudeChoice == nil ? L("ob.back") : L("ob.cancel")) {
                        claudeSessionInput = ""
                        if presetClaudeChoice == nil { message = ""; claudeChoice = nil }
                        else { Hud.windows["onboarding"]?.performClose(nil) }
                    }.buttonStyle(.plain).foregroundColor(p.sub).font(.system(size: 12)).disabled(busy)
                }
                Spacer()
                Button(OnboardingPlan.stepButton(isLast: isLast)) { advance() }.keyboardShortcut(.defaultAction)
                    .disabled(!claudeWebDone)
            }
        }
    }

    func saveClaudeSession() {
        guard preview == nil, !busy else { return }
        busy = true; message = ""
        let attempt = model.beginClaudeLogin()
        Task { @MainActor in
            await model.saveClaudeSession(claudeSessionInput, attempt: attempt,
                                          onPersisted: { claudeSessionInput = "" }, onDone: { ok, msg in
                busy = false
                if ok {
                    connected.insert(.claudePlan); claudeWebDone = true
                } else { message = msg }
            })
        }
    }

    /// 装好以后：状态栏钩子只在终端里的 Claude Code 中运行（桌面 App 不运行），
    /// 给一键打开终端，或复制命令自己粘贴
    var claudeTerminalStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(L("ob.claude.oneMoreStep"), L("ob.claude.oneMoreStepNote"))
            Button {
                do {
                    let url = try model.claudeInstaller.writeTerminalLauncher()
                    NSWorkspace.shared.open(url)
                    logLine("已打开终端启动 Claude Code")
                } catch {
                    message = L("ob.terminalFailed", error.localizedDescription)
                }
            } label: {
                Label(L("ob.claude.openTerminal"), systemImage: "terminal")
                    .font(.system(size: 12.5, weight: .medium)).frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            VStack(alignment: .leading, spacing: 6) {
                LT("ob.claude.orCopy")
                    .font(.system(size: 12)).foregroundColor(p.text).fixedSize(horizontal: false, vertical: true)
                codeBox(ClaudeStatusLineInstaller.terminalScript)
            }
            LT("ob.claude.terminalOnly")
                .font(.system(size: 11)).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                LT("ob.claude.notInstalledQ").font(.system(size: 11)).foregroundColor(p.sub)
                // 用按钮而不是 Link：离屏渲染画不出 Link
                Button(L("ob.claude.installGuide")) {
                    NSWorkspace.shared.open(URL(string: ClaudeStatusLineInstaller.installGuideURL)!)
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Accent.blue)
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundColor(p.warnText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(OnboardingPlan.stepButton(isLast: isLast)) { advance() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    func sectionLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundColor(p.text)
    }

    func bullet(_ t: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").font(.system(size: 12)).foregroundColor(p.sub)
            Text(t).font(.system(size: 12)).foregroundColor(p.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 等宽、可选中的一段路径或配置
    /// 代码框：右侧一键复制（复制后变成「已复制」）
    func codeBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).font(.system(size: 11, design: .monospaced)).foregroundColor(p.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copiedBox = text
            } label: {
                Label(copiedBox == text ? L("set.copied") : L("set.copy"), systemImage: copiedBox == text ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11)).labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain).foregroundColor(copiedBox == text ? p.sub : Accent.blue)
            .accessibilityLabel(copiedBox == text ? L("set.copied") : L("ob.copyCommand"))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(p.cardAlt))
    }
}
