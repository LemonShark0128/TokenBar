import AppKit
import Combine
import SwiftUI

// ---------------------------------------------------------------- 账号：Claude 套餐（来源切换、状态栏钩子安装和还原）

extension UsageModel {
    // MARK: Claude 套餐（状态栏钩子）

    /// Claude 套餐是否已添加
    @MainActor var claudePlanAdded: Bool {
        usageStore?.platforms.contains { $0.id == .claudePlan && $0.status != .notAdded } == true
    }

    /// 读一次状态栏钩子的状态和额度来源（打开面板、打开设置时）；没添加 Claude 套餐时不读 settings.json
    @MainActor
    func refreshClaudeHookState() {
        guard !kRendering, claudePlanAdded else { return }
        claudeHookState = claudeInstaller.state()
        let hook = claudeHookState
        claudeSource = ClaudePlanSource.load(.standard, hookInstalled: { hook == .installed })
    }

    /// 状态栏钩子被换掉了、而且额度正从终端读：要提示「重装」。桌面来源时钩子留不留都不影响
    var claudeHookGone: Bool { claudeSource == .terminal && claudeHookState == .replaced }

    /// 换额度来源：存起来，并立刻按新来源取一次
    @MainActor
    func setClaudeSource(_ s: ClaudePlanSource) {
        claudeSource = s
        guard !kRendering else { return }
        s.save(.standard)
        logLine(s == .desktop ? "已改用 Claude 桌面 App 来源" : "Claude 套餐改为读终端版 Claude Code 的状态栏钩子")
    }

    /// 添加 Claude 套餐（桌面来源）：不改任何文件，记下来源后直接添加
    @MainActor
    func addClaudeDesktop() async {
        setClaudeSource(.desktop)
        reloginNotes[.claudePlan] = nil
        await addPlanPlatform(.claudePlan)
    }

    /// 设置里的「改用 …」：终端 → 桌面时问要不要顺便还原 settings.json；桌面 → 终端走终端的确认页
    @MainActor
    func switchClaudeSource() {
        if claudeSource == .desktop {
            openOnboarding(at: .login, platform: .claudePlan, claudeChoice: .terminal)
            return
        }
        let a = NSAlert()
        a.messageText = L("claude.sw.title")
        a.informativeText = L("claude.sw.info")
        a.addButton(withTitle: L("claude.sw.switchRestore"))
        a.addButton(withTitle: L("claude.sw.switchKeep"))
        a.addButton(withTitle: L("ob.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        guard r != .alertThirdButtonReturn else { return }
        var note: ReloginNote?
        if r == .alertFirstButtonReturn {
            let res = restoreClaudeHook()
            guard res.ok else { return }      // 还原不了：原因已写在账号行下，来源不变
            note = res.note
        }
        setClaudeSource(.desktop)
        reloginNotes[.claudePlan] = note ?? ReloginNote(text: L("claude.sw.done"), isError: false)
        Task { @MainActor in await usageStore?.refresh(.claudePlan) }
    }

    /// 还原 settings.json 的状态栏设置（移除 Claude 套餐、改用桌面来源时共用）。
    /// ok = false：没能还原（原因写进 reloginNotes）；note：还原了但要告诉用户的事（如已被改过）
    @MainActor
    func restoreClaudeHook() -> (ok: Bool, note: ReloginNote?) {
        do {
            let r = try claudeInstaller.restore()
            var note: ReloginNote?
            if r == .changedByUser {
                note = ReloginNote(text: L("claude.sw.changedElsewhere"), isError: true)
                logLine("状态栏设置已被改过，没有还原")
            } else if r == .notInstalled, claudeInstaller.settingsStillReferenceHook() != false {
                // 没记录原设置，但 settings.json 解析不了或仍指向我们的钩子：没有还原，请用户手动删
                note = ReloginNote(text: L("claude.sw.restoreManual"), isError: true)
                logLine("状态栏设置没有还原（settings.json 解析不了或仍引用钩子）")
            } else {
                logLine("已还原 Claude Code 状态栏设置")
            }
            // 按实际情况记（已被改过、仍引用钩子时不是「没安装」）
            claudeHookState = claudeInstaller.state()
            return (true, note)
        } catch is ClaudeStatusLineInstaller.CorruptOriginalError {
            reloginNotes[.claudePlan] = ReloginNote(text: L("claude.sw.cantReadOriginal"),
                                                    isError: true)
            logLine("没能还原状态栏设置：记录的原设置读不出来")
            return (false, nil)
        } catch {
            reloginNotes[.claudePlan] = ReloginNote(text: L("claude.sw.restoreFailed", error.localizedDescription), isError: true)
            logLine("没能还原状态栏设置：\(error)")
            return (false, nil)
        }
    }

    /// 移除 Claude 套餐时要不要还原 settings.json：终端来源，或桌面来源但钩子还留着
    @MainActor var claudeRemoveRestoresHook: Bool {
        if kRendering { return claudeSource == .terminal }
        // claudeSource 只在打开面板 / 设置时同步，这里现读一次（从引导页移除时它可能还是默认值）
        let installer = claudeInstaller
        let source = ClaudePlanSource.load(.standard, hookInstalled: { installer.state() == .installed })
        return source == .terminal || installer.state() != .notInstalled
    }

    /// 安装（或重装）状态栏钩子：装上了或本来就是钩子 → 添加 Claude 套餐；
    /// settings.json 不是标准 JSON → 什么都不改、不添加，结果里带要手动粘贴的片段
    @MainActor
    func installClaudeHook() async throws -> ClaudeStatusLineInstaller.InstallResult {
        let r = try claudeInstaller.install()
        switch r {
        case .installed, .alreadyInstalled:
            logLine("Claude Code 状态栏钩子已安装")
            claudeHookState = .installed
            setClaudeSource(.terminal)
            reloginNotes[.claudePlan] = nil
            await addPlanPlatform(.claudePlan)
        case .unparseable:
            logLine("~/.claude/settings.json 不是标准 JSON，没有安装状态栏钩子")
        }
        return r
    }

    /// 设置和大油箱里的「重装」：结果写在账号行下；settings.json 解析不了时弹窗给出手动粘贴的片段
    @MainActor
    func reinstallClaudeHook() {
        Task { @MainActor in
            do {
                switch try await installClaudeHook() {
                case .installed, .alreadyInstalled:
                    reloginNotes[.claudePlan] = ReloginNote(text: L("claude.hookReinstalled"), isError: false)
                case .unparseable(let snippet):
                    showClaudeSnippet(snippet)
                }
            } catch {
                logLine("重装状态栏钩子失败：\(error)")
                reloginNotes[.claudePlan] = ReloginNote(text: L("claude.hookReinstallFailed", error.localizedDescription), isError: true)
            }
        }
    }

    @MainActor
    private func showClaudeSnippet(_ snippet: String) {
        let a = NSAlert()
        a.messageText = ClaudeHookCopy.unparseable
        a.informativeText = snippet
        a.addButton(withTitle: L("set.copy"))
        a.addButton(withTitle: L("ob.close"))
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snippet, forType: .string)
        }
    }
}
