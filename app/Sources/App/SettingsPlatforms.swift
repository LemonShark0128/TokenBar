import AppKit
import Combine
import SwiftUI

// ---------------------------------------------------------------- 设置「平台」页：账号行、添加平台

extension SettingsView {
    // MARK: 平台页

    func urgentButton(_ action: AccountAction, _ id: ProviderID) -> some View {
        Button { perform(action.kind, id) } label: {
            Text(action.title).font(.system(size: 11)).foregroundColor(Accent.orange)
                .fixedSize().padding(.vertical, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ProviderRegistry.displayName(id)) \(action.title)")
    }

    func accountRow(_ id: ProviderID, first: Bool, _ c: Ctx) -> some View {
        let st = c.states[id] ?? .notAdded
        let name = ProviderRegistry.displayName(id)
        let hookGone = id == .claudePlan && model.claudeHookGone
        let snap = c.inp.platforms.first { $0.id == id }?.snapshot
        let reading = AccountReading.from(balance: snap?.balance, quota: snap?.quota, meter: ProviderRegistry.meter(id),
                                          now: model.fixedNow ?? Date())
        let kind = agentKind(id)
        let custom = kind.flatMap { (input?.customDirs ?? AgentDirs.custom(.standard))[$0] }
        let customPath = custom.map {
            AgentDirs.displayPath(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath),
                                  home: URL(fileURLWithPath: NSHomeDirectory()))
        }
        let detail = SettingsLayout.accountDetail(id, state: st, reading: reading, stale: hookGone, claudeSource: model.claudeSource, customDir: customPath)
        let urgent = SettingsLayout.urgentAction(id, state: st, hookGone: hookGone)
        let actions = SettingsLayout.menuActions(id, state: st, isMain: c.main == id,
                                                 claudeSource: model.claudeSource, hookGone: hookGone, customDir: custom != nil)
        let items: () -> [PopMenu.Item] = {
            actions.map { a in
                PopMenu.Item(title: a.title, destructive: a.destructive, separatorBefore: a.destructive) { perform(a.kind, id) }
            }
        }
        return VStack(spacing: 0) {
            if !first { Hairline(p: p).padding(.leading, 12) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 12.5, weight: .medium)).foregroundColor(p.text).lineLimit(1).fixedSize()
                    if c.main == id { MainBadge() }
                    Spacer(minLength: 8)
                    if let urgent { urgentButton(urgent, id) }
                    MoreButton(title: name, p: p, items: items)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Circle().fill(hookGone ? Accent.orange : tone(st.tone)).frame(width: 7, height: 7)
                        .alignmentGuide(.firstTextBaseline) { $0.height - 0.5 }
                    (Text(hookGone ? ClaudeHookCopy.hookGone : st.label(for: id))
                        .foregroundColor(hookGone || st.tone == .warn ? Accent.orange : p.sub)
                     + Text(detail.map { " · \($0)" } ?? "").foregroundColor(p.sub))
                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .contain)
                if let note = model.reloginNotes[id] {
                    Text(note.text).font(.system(size: 11))
                        .foregroundColor(note.isError ? Accent.orange : Accent.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7).frame(minHeight: 36)
        }
    }

    func perform(_ kind: AccountAction.Kind, _ id: ProviderID) {
        switch kind {
        case .setMain: model.usageStore?.pinMain(id); model.objectWillChange.send()
        case .apiKey: model.openOnboarding(at: .login, platform: id)
        case .console, .webRelogin: webRelogin(id)
        case .reinstallHook: model.reinstallClaudeHook()
        case .switchClaudeSource: model.switchClaudeSource()
        case .dataDir: chooseDataDir(id)
        case .resetDataDir:
            guard let kind = agentKind(id) else { return }
            AgentDirs.setCustom(kind, nil, .standard)
            refreshDataDir(id)
        case .remove: model.removeAccount(id)
        }
    }

    private func agentKind(_ id: ProviderID) -> AgentDirKind? {
        switch id {
        case .codexPlan: return .codex
        case .claudePlan: return .claude
        default: return nil
        }
    }

    private func chooseDataDir(_ id: ProviderID) {
        guard let kind = agentKind(id) else { return }
        let dirs = AgentDirs.current
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = kind == .codex ? dirs.codexHome : dirs.claudeConfig
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let reason = AgentDirs.validate(kind, url) {
            model.reloginNotes[id] = ReloginNote(text: reason, isError: true)
            return
        }
        AgentDirs.setCustom(kind, url, .standard)
        refreshDataDir(id)
    }

    private func refreshDataDir(_ id: ProviderID) {
        model.reloginNotes[id] = nil
        if id == .claudePlan { model.refreshClaudeHookState() }
        model.objectWillChange.send()
        model.reloadRunningTasks()
        Task { @MainActor in await model.usageStore?.refresh(id) }
    }

    /// 网页重新登录：结果（含验证没通过、存钥匙串失败）写在账号行下
    func webRelogin(_ id: ProviderID) {
        model.reloginNotes[id] = nil
        model.openWebLogin(id) { ok, msg in
            model.reloginNotes[id] = ReloginNote.make(provider: id, ok: ok, message: msg)
        }
    }

    /// 套餐平台不需要登录：直接添加；Claude 套餐先选额度来源（桌面 App / 终端版）；其余走登录页（与引导同一页）
    func add(_ id: ProviderID) {
        if ProviderRegistry.meter(id) == .quota && id != .claudePlan {
            addingPlan = id
            Task { @MainActor in
                await model.addPlanPlatform(id)
                addingPlan = nil
            }
        } else { model.openOnboarding(at: .login, platform: id) }
    }

    @ViewBuilder
    func addRow(first: Bool, _ c: Ctx) -> some View {
        let addable = SettingsLayout.addable(added: c.added)
        // 移除后没能还原的说明（如 Claude 套餐的状态栏设置）：平台已不在列表里，说明仍要看得到
        ForEach(addable.filter { model.reloginNotes[$0] != nil }, id: \.self) { id in
            VStack(spacing: 0) {
                Hairline(p: p).padding(.leading, 12)
                let note = model.reloginNotes[id]!
                Text("\(ProviderRegistry.displayName(id))：\(note.text)").font(.system(size: 11))
                    .foregroundColor(note.isError ? Accent.orange : Accent.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        VStack(spacing: 0) {
            if !first || addable.contains(where: { model.reloginNotes[$0] != nil }) { Hairline(p: p).padding(.leading, 12) }
            Button {
                PopMenu.show(addable.map { id in PopMenu.Item(title: ProviderRegistry.displayName(id)) { add(id) } })
            } label: {
                HStack(spacing: 6) {
                    if let adding = addingPlan {
                        ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 11, height: 11)
                        Text(SettingsLayout.addingText(adding)).font(.system(size: 12.5))
                    } else {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        LT("panel.addPlatform").font(.system(size: 12.5))
                    }
                    Spacer()
                }
                .foregroundColor(addingPlan == nil ? Accent.blue : p.sub)
                .padding(.horizontal, 12).frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(addingPlan != nil)
            .accessibilityLabel(addingPlan.map(SettingsLayout.addingText) ?? L("panel.addPlatform"))
        }
    }
}
