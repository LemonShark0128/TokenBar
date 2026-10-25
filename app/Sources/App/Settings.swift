import AppKit
import Combine
import SwiftUI
import UserNotifications

// ---------------------------------------------------------------- 设置窗：侧栏 + 平台 · 菜单栏与面板 · 提醒 · 通用

struct SettingsView: View {
    @ObservedObject var model: UsageModel
    let p: Palette
    /// 离屏渲染直接给账号数据；真 App 为 nil，从 model 取
    var input: AccountsInput?
    @State var diagnosticsCopied = false
    /// 设置里直接添加的套餐平台（首次读本机记录）还没完成：「＋ 添加平台」那一行变灰并写「正在添加 …」
    @State var addingPlan: ProviderID?

    struct Ctx {
        let inp: AccountsInput
        let states: [ProviderID: AccountState]
        let added: [ProviderID]
        /// 主平台（已添加时）
        let main: ProviderID?
    }

    struct LayoutKey: Equatable {
        let sections: [SettingsSection]
        let notes: [String]
        /// 油箱说明文字（换行数会随平台名、预警开关变）
        let tank: String
    }

    func ctx() -> Ctx {
        let inp = input ?? model.accountsInput
        var states: [ProviderID: AccountState] = [:]
        for id in ProviderRegistry.all { states[id] = UsageModel.accountState(for: inp.platforms.first { $0.id == id }) }
        let added = SettingsLayout.added(states)
        return Ctx(inp: inp, states: states, added: added, main: added.contains(inp.mainID) ? inp.mainID : nil)
    }

    var body: some View {
        let c = ctx()
        let custom = Set(c.added.filter { alertKey($0, c) == "custom" })
        let page = model.settingsPage
        let sections = SettingsLayout.sections(page, added: c.added, main: c.main, customOpen: custom)
        // 侧栏铺满整窗高度：右侧内容决定高度，侧栏画在左边的留空上
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: kSettingsSidebarWidth, height: 1)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, sec in
                    sectionView(sec, c)
                }
                if page == .general { generalFooter }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 230, alignment: .top)
        .overlay(alignment: .leading) {
            SettingsSidebar(selected: page, updated: model.data?.nowLocal ?? "—", p: p) { model.settingsPage = $0 }
        }
        // 换页、出现自定义输入框、重新登录说明等：窗口跟着内容重新定高（宽度不变）
        .onChange(of: LayoutKey(sections: sections, notes: model.reloginNotes.values.map(\.text).sorted(), tank: tankCaption)) { _, _ in
            DispatchQueue.main.async { Hud.refit("settings") }
        }
        // 下拉选中值、平台状态和读数变了也可能让说明折行：数据一变就重新量一次（高度没变时 refit 什么也不做）
        .onReceive(model.objectWillChange) { _ in
            DispatchQueue.main.async { Hud.refit("settings") }
        }
    }

    // MARK: 分组

    @ViewBuilder
    func sectionView(_ sec: SettingsSection, _ c: Ctx) -> some View {
        if sec.rows.first == .tank {
            tankGroup(extra: Array(sec.rows.dropFirst()), c)
        } else {
            SettingsGroup(title: sec.title, p: p) {
                ForEach(Array(sec.rows.enumerated()), id: \.offset) { i, row in
                    rowView(row, first: i == 0, c)
                }
            }
        }
    }

    var tankCaption: String {
        let isQuota = ProviderRegistry.meter(model.mainID) == .quota
        let on = model.balanceAlertCny > 0
        return isQuota
            ? (on ? L("set.tank.quotaOn", model.mainName) : L("set.tank.quotaOff", model.mainName))
            : (on ? L("set.tank.moneyOn", model.mainName) : L("set.tank.moneyOff"))
    }

    /// 最上面的余额进度条；extra 是并进同一张卡片的行（余额规格，第六批）
    func tankGroup(extra: [SettingsRowID], _ c: Ctx) -> some View {
        // 主平台是套餐平台：预警线是剩余百分比（满格 100%），没有「余额规格」
        let isQuota = ProviderRegistry.meter(model.mainID) == .quota
        return SettingsGroup(title: SettingsLayout.scaleTitle(main: model.mainID), p: p) {
            VStack(alignment: .leading, spacing: 8) {
                TankScale(balance: model.data?.balance.cny ?? 0, full: isQuota ? 100 : model.fuelFullCny,
                          alert: model.balanceAlertCny, currency: model.data?.balance.currency, percent: isQuota, p: p)
                Text(tankCaption)
                    .font(.system(size: 11)).foregroundColor(p.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            ForEach(Array(extra.enumerated()), id: \.offset) { _, row in
                rowView(row, first: false, c)
            }
        }
    }

    // MARK: 行

    @ViewBuilder
    func rowView(_ row: SettingsRowID, first: Bool, _ c: Ctx) -> some View {
        switch row {
        case .mainPlatform:
            SettingsRow(label: L("set.showWhich"), help: SettingsLayout.mainHelp(auto: c.inp.auto, main: c.inp.mainID),
                        first: first, p: p) {
                DropdownButton(title: L("set.showWhich"), options: SettingsLayout.mainOptions(added: c.added),
                               selected: SettingsLayout.mainSelection(auto: c.inp.auto, main: c.inp.mainID, added: c.added),
                               p: p) { k in model.chooseMain(k) }
            }
        case .account(let id):
            accountRow(id, first: first, c)
        case .addPlatform:
            addRow(first: first, c)
        case .launchAtLogin:
            SettingsRow(label: L("set.launchAtLogin"), help: L("set.launchAtLoginHelp"), first: first, p: p) {
                PillSwitch(on: model.launchAtLogin, title: L("set.launchAtLogin")) { model.toggleAutoStart() }
            }
        case .refreshInterval:
            SettingsRow(label: L("set.refresh"), help: L("set.refreshHelp"), first: first, p: p) {
                DropdownButton(title: L("set.refresh"), options: SettingsLayout.refreshOptions, selected: "\(model.refreshSeconds)",
                               fallback: SettingsLayout.refreshLabel(model.refreshSeconds), p: p) {
                    model.refreshSeconds = Int($0) ?? 120
                }
            }
        case .exchangeRate:
            ExchangeRateRow(live: model.usageStore != nil, p: p)
        case .updateCheck:
            SettingsRow(label: L("set.autoUpdate"),
                        help: UpdateCheck.caption(model.updateOutcome, available: model.availableUpdate),
                        first: first, p: p) {
                HStack(spacing: 10) {
                    if let r = model.availableUpdate {
                        Button(L("set.download")) { NSWorkspace.shared.open(r.url) }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Accent.blue)
                            .accessibilityLabel(L("set.openDownload", r.version))
                    } else {
                        Button(model.updateChecking ? L("set.checking") : L("set.checkNow")) { model.checkForUpdate(force: true) }
                            .buttonStyle(.plain).font(.system(size: 12))
                            .foregroundColor(model.updateChecking ? p.sub : Accent.blue)
                            .disabled(model.updateChecking)
                    }
                    PillSwitch(on: model.autoUpdateCheck, title: L("set.autoUpdate")) { model.autoUpdateCheck.toggle() }
                }
            }
        case .diagnostics:
            SettingsRow(label: L("set.diagnostics"), help: L("set.diagnosticsHelp"),
                        first: first, p: p) {
                Button(diagnosticsCopied ? L("set.copied") : L("set.copy")) {
                    model.copyDiagnostics()
                    diagnosticsCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { diagnosticsCopied = false }
                }
                .buttonStyle(.plain).font(.system(size: 12))
                .foregroundColor(diagnosticsCopied ? p.sub : Accent.blue)
                .accessibilityLabel(diagnosticsCopied ? L("set.diagnosticsCopied") : L("set.copyDiagnostics"))
            }
        case .menuBarMode:
            SettingsRow(label: L("set.menuBarShows"), help: L("set.menuBarShowsHelp"),
                        first: first, p: p) {
                DropdownButton(title: L("set.menuBarShows"), options: SettingsLayout.menuBarModeOptions, selected: model.mbMode, p: p) { model.mbMode = $0 }
            }
        case .theme:
            SettingsRow(label: L("set.appearance"), first: first, p: p) {
                DropdownButton(title: L("set.appearance"), options: SettingsLayout.themeOptions,
                               selected: model.themeMode == .light ? "light" : model.themeMode == .dark ? "dark" : "system",
                               p: p) { k in
                    model.themeMode = k == "light" ? .light : k == "dark" ? .dark : .system
                    logLine("主题切换为：\(model.themeLabel)")
                }
            }
        case .transparency:
            SettingsRow(label: L("set.transparency"), help: L("set.transparencyHelp"), first: first, p: p) { TransparencySlider(p: p) }
        case .widget:
            SettingsRow(label: L("set.widget"), help: L("set.widgetHelp"), first: first, p: p) {
                PillSwitch(on: model.widgetVisible, title: L("set.widget")) { WidgetController.shared.toggle(model) }
            }
        case .tank:
            EmptyView()          // 进度条整张卡片由 sectionView → tankGroup 画
        case .alertHeader(let quota):
            alertHeader(quota: quota)
        case .alert(let id):
            alertRow(id, first: first, c)
        case .alertCustom(let id):
            alertCustomRow(id, first: first, c)
        case .fuelFull:
            SettingsRow(label: L("set.fuelFull"), help: L("set.fuelFullHelp"), first: first, p: p) {
                DropdownButton(title: L("set.fuelFull"), options: SettingsLayout.fuelFullOptions, selected: "\(Int(model.fuelFullCny))", fallback: fmtMoney(model.fuelFullCny, model.data?.balance.currency, 0), p: p) {
                    model.fuelFullCny = Double($0) ?? model.fuelFullCny
                }
            }
        case .alertRepeat:
            SettingsRow(label: L("set.repeat"), help: L("set.repeatHelp"), first: first, p: p) {
                DropdownButton(title: L("set.repeat"), options: AlertRepeat.options, selected: "\(model.alertRepeatHours)",
                               fallback: AlertRepeat.label(model.alertRepeatHours), p: p) {
                    model.alertRepeatHours = Int($0) ?? AlertRepeat.defaultHours
                }
            }
        case .runoutAlert:
            let on = c.inp.settings.quotaRunoutAlert
            SettingsRow(label: L("set.runout"), help: L("set.runoutHelp"), first: first, p: p) {
                PillSwitch(on: on, title: L("set.runout")) {
                    model.updateProviderSettings { $0.quotaRunoutAlert = !on }
                }
            }
        case .spikeAlert:
            SettingsRow(label: L("set.spike"), help: L("set.spikeHelp"), first: first, p: p) {
                PillSwitch(on: model.spikeAlertsOn, title: L("set.spike")) { model.spikeAlertsOn.toggle() }
            }
        }
    }

    // MARK: 提醒页（其余代码在 SettingsAlerts.swift）

    /// 下拉列宽在表头和平台行之间共享，数值与列名都向右对齐。
    let alertColumnWidth: CGFloat = 90

    // MARK: 通用页底部

    var generalFooter: some View {
        HStack {
            Spacer()
            Button(L("set.quit")) { model.quitForReal() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Accent.red)
        }
        .padding(.horizontal, 4).padding(.top, 2)
    }

    func tone(_ t: AccountState.Tone) -> Color {
        switch t {
        case .good: return Accent.green
        case .neutral: return p.sub
        case .warn: return Accent.orange
        }
    }
}

extension UsageModel {
    /// 设置「复制诊断信息」：版本、macOS 版本、平台状态、最近 3 份崩溃报告（只列名字和时间）、最近 50 行日志，整份先打码再放进剪贴板
    @MainActor
    func copyDiagnostics() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
        AppLogger.shared.flush()        // 后台队列里还没写的几行也要带上
        let timeZone = TimeZone.autoupdatingCurrent
        let fmt = Diagnostics.dateFormatter(timeZone: timeZone)
        let writeFailures = WriteFailureLog.shared.recent().map { "[\(fmt.string(from: $0.at))] \($0.line)" }
        let text = Diagnostics.report(appVersion: version,
                                      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                      now: Date(), timeZone: timeZone,
                                      platforms: usageStore?.platforms ?? [], logLines: kLogFile.tail(50),
                                      crashReports: Diagnostics.crashReports(), writeFailures: writeFailures)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        logLine("已复制诊断信息到剪贴板")
    }
}
