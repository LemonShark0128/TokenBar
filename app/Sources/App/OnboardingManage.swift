import AppKit
import SwiftUI

/// 「添加 / 移除平台」（用户 11/6 选 proposal-pick-redesign 乙）：老用户从面板进来看管理页——
/// 已添加的平台写实时状态、右边「移除」（先确认）；可添加的平台写能看到什么、右边「添加」（直接进它的连接步骤，办完回到这页）。
/// 第一次打开（什么都没加）仍是勾选，改成分组 + 图标的样子（pickGrouped）
extension OnboardingView {
    func platformIcon(_ id: ProviderID) -> some View {
        Image(nsImage: PlatformGlyph.image(id, size: 16, tint: nil))
            .renderingMode(.template).foregroundColor(Color(nsColor: PlatformColor.color(id)))
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }

    /// 一行：图标、名字、灰色（或橙色）说明、右边的按钮或勾
    func platformLine<Trailing: View>(_ id: ProviderID, _ detail: String, warn: Bool = false, first: Bool,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(spacing: 0) {
            if !first { Hairline(p: p).padding(.leading, 42) }
            HStack(spacing: 10) {
                platformIcon(id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ProviderRegistry.displayName(id)).font(.system(size: 12.5, weight: .medium)).foregroundColor(p.text)
                    Text(detail).font(.system(size: 11)).foregroundColor(warn ? Accent.orange : p.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    /// 已添加平台的读数（余额 / 剩余百分比）；离屏预览用 preview.readings
    func reading(_ id: ProviderID) -> AccountReading? {
        if let preview { return preview.readings?[id] }
        let snap = model.usageStore?.platforms.first { $0.id == id }?.snapshot
        return AccountReading.from(snapshot: snap, meter: ProviderRegistry.meter(id), now: model.fixedNow ?? Date())
    }

    var manage: some View {
        let lists = OnboardingPlan.manageLists(added: connected)
        return VStack(alignment: .leading, spacing: 12) {
            title(L("ob.manageTitle"), L("ob.manageNote"))
            // 一组为空时不画空框，只写一行灰字（窗口定高，5 个都加了也要放得下底部按钮）
            if lists.added.isEmpty {
                emptyLine(L("ob.noneAdded"))
            } else {
                SettingsGroup(title: L("ob.addedCount", lists.added.count), p: p) {
                    ForEach(Array(lists.added.enumerated()), id: \.element) { i, id in
                        let s = OnboardingPlan.addedStatus(id, state: pickState(id), reading: reading(id))
                        platformLine(id, s.text, warn: s.warn, first: i == 0) {
                            // 暂时隐藏的平台（用户 11/6 选 proposal-hide-platform 乙）：多一个「显示」
                            if pickState(id) == .hidden {
                                Button(L("today.show")) { showOne(id) }
                                    .controlSize(.small)
                                    .accessibilityLabel(L("today.showA11y", ProviderRegistry.displayName(id)))
                            }
                            Button(L("ob.remove")) { removeOne(id) }
                                .controlSize(.small)
                                .accessibilityLabel(L("ob.removeA11y", ProviderRegistry.displayName(id)))
                        }
                    }
                }
            }
            if lists.addable.isEmpty {
                emptyLine(L("ob.allAdded", ProviderRegistry.all.count))
            } else {
                SettingsGroup(title: L("ob.addable"), p: p) {
                    ForEach(Array(lists.addable.enumerated()), id: \.element) { i, id in
                        platformLine(id, OnboardingPlan.shortGain(id), first: i == 0) {
                            Button(L("ob.add")) { addOne(id) }
                                .controlSize(.small)
                                .accessibilityLabel(L("ob.addA11y", ProviderRegistry.displayName(id)))
                        }
                    }
                }
            }
            next(L("ob.done")) {
                UserDefaults.standard.set(true, forKey: "onboardingDone")
                Hud.hide("onboarding")
            }
        }
    }

    func emptyLine(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundColor(p.sub).padding(.leading, 4)
    }

    /// 「添加」：只走这一个平台的连接步骤，办完（或跳过）回到管理页
    func addOne(_ id: ProviderID) {
        guard preview == nil else { return }
        flow = OnboardingFlow(added: connected, only: id)
        flow.startLogin()
        resetPlatform()
        manageAdding = true
        step = .login
    }

    /// 「显示」：隐藏着的平台显示回来、马上取一次数（预览里不动）
    func showOne(_ id: ProviderID) {
        guard preview == nil else { return }
        model.setPlatformHidden(id, false)
    }

    /// 「移除」：先确认；Claude 套餐还原不了状态栏设置时不移除，并说明原因
    func removeOne(_ id: ProviderID) {
        guard preview == nil, model.confirmRemove([id]) else { return }
        if model.performRemove(id) {
            connected.remove(id)
            removedSome = true
            // 移除的正好是固定显示的平台：UsageStore 会改回自动切换，这里的「固定」也跟着改
            if !menuBarAuto, menuBar == id { menuBarAuto = true }
        } else {
            let a = NSAlert()
            a.messageText = L("ob.notRemoved", ProviderRegistry.displayName(id))
            a.informativeText = model.reloginNotes[id]?.text ?? ""
            a.runModal()
        }
    }

    /// 第一次打开的勾选列表：按量付费 / 套餐两组，每行图标 + 能看到什么，右边圆形勾
    var pickGroups: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(OnboardingPlan.groups, id: \.title) { g in
                SettingsGroup(title: g.title, p: p) {
                    ForEach(Array(g.ids.enumerated()), id: \.element) { i, id in
                        let isAdded = added.contains(id)
                        let on = picked.contains(id)
                        let st = pickState(id)
                        let check = OnboardingPlan.pickCheck(on: on, added: isAdded, state: st)
                        Button {
                            if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
                        } label: {
                            platformLine(id, isAdded ? OnboardingPlan.addedDetail(on: on, state: st, id: id) : OnboardingPlan.shortGain(id),
                                         first: i == 0) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundColor(check == .connected ? Accent.green : (check == .new ? Accent.blue : p.sub.opacity(on ? 1 : 0.6)))
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
    }
}
