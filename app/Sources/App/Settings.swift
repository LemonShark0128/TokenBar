import AppKit
import Combine
import SwiftUI

// ---------------------------------------------------------------- 设置窗：侧栏 + 显示 · 提醒 · 平台 · 通用

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
    }

    func ctx() -> Ctx {
        let inp = input ?? model.accountsInput
        let (states, added) = UsageModel.accountStates(inp)
        return Ctx(inp: inp, states: states, added: added, main: added.contains(inp.mainID) ? inp.mainID : nil)
    }

    var body: some View {
        let c = ctx()
        let custom = Set(c.added.filter { alertKey($0, c) == "custom" })
        let page = model.settingsPage
        let sections = SettingsLayout.sections(page, added: c.added, main: c.main, customOpen: custom, style: model.mbStyle)
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
        .onChange(of: LayoutKey(sections: sections, notes: model.reloginNotes.values.map(\.text).sorted())) { _, _ in
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
        SettingsGroup(title: sec.title, p: p) {
            ForEach(Array(sec.rows.enumerated()), id: \.offset) { i, row in
                rowView(row, first: i == 0, c)
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
                // 隐藏的平台不在「显示哪个平台」里（设置的平台列表里仍在，写「已隐藏 · 不刷新」）
                DropdownButton(title: L("set.showWhich"), options: SettingsLayout.mainOptions(added: SettingsLayout.shown(c.states)),
                               selected: SettingsLayout.mainSelection(auto: c.inp.auto, main: c.inp.mainID, added: SettingsLayout.shown(c.states)),
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
                    model.refreshSeconds = Int($0) ?? 60
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
        case .menuBarStyle:
            SettingsRow(label: L("mb.style"), first: first, p: p) {
                DropdownButton(title: L("mb.style"), options: SettingsLayout.menuBarStyleOptions,
                               selected: model.mbStyle, p: p) { model.mbStyle = $0 }
            }
        case .menuBarShowRunning:
            SettingsRow(label: L("mb.showRunning"), help: L("mb.showRunning.help"), first: first, p: p) {
                PillSwitch(on: model.mbShowRunning, title: L("mb.showRunning")) { model.mbShowRunning.toggle() }
            }
            if model.mbShowRunning {
                SettingsRow(label: L("mb.slots"), first: false, p: p) {
                    HStack(spacing: 2) {
                        ForEach(SettingsLayout.menuBarSlotOptions, id: \.key) { option in
                            Button { model.mbSlots = option.key } label: {
                                Text(option.label).font(.system(size: 12))
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(Capsule().fill(model.mbSlots == option.key ? Accent.blue.opacity(0.18) : Color.clear))
                            }.buttonStyle(.plain)
                            .accessibilityAddTraits(model.mbSlots == option.key ? .isSelected : [])
                        }
                    }.padding(2).background(Capsule().fill(p.track))
                }
            }
        case .menuBarMode:
            SettingsRow(label: L("set.menuBarShows"), help: L("set.menuBarShowsHelp"),
                        first: first, p: p) {
                DropdownButton(title: L("set.menuBarShows"), options: SettingsLayout.menuBarModeOptions, selected: model.mbMode, p: p) { model.mbMode = $0 }
            }
        case .panelHome:
            SettingsRow(label: L("today.setting"), first: first, p: p) {
                DropdownButton(title: L("today.setting"), options: SettingsLayout.panelHomeOptions,
                               selected: model.panelHome, p: p) { model.panelHome = $0 }
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
                PillSwitch(on: model.widgetVisible, title: L("set.widget")) { model.toggleWidget() }
            }
        case .alertStatus(let id):
            alertStatusRow(id, first: first, c)
        case .alert(let id):
            let keyLimit = c.inp.platforms.first { $0.id == id }?.snapshot?.balanceIsKeyLimit == true
            SettingsRow(label: SettingsLayout.alertLineLabel(id, keyLimit: keyLimit), first: first, p: p) {
                DropdownButton(title: L("set.alertLineFor", ProviderRegistry.displayName(id)),
                               options: SettingsLayout.alertOptions(quota: ProviderRegistry.meter(id) == .quota, symbol: symbol(id, c)),
                               selected: alertKey(id, c), p: p) { pickAlert($0, id) }
            }
        case .hourly(let id):
            SettingsRow(label: L("set.alert.hourlyOver"), help: L("set.alert.hourlyRowHelp"), first: first, p: p) {
                hourlyButton(id, c)
            }
        case .alertCustom(let id):
            alertCustomRow(id, first: first, c)
        case .fuelFull:
            let currency = SettingsLayout.gaugeScaleCurrency(added: c.added, actual: SettingsLayout.balanceCurrencies(c.inp.platforms))
            SettingsRow(label: L("set.fuelFull"), help: L("set.fuelFullHelp"), first: first, p: p) {
                DropdownButton(title: L("set.fuelFull"), options: SettingsLayout.fuelFullOptions(symbol: currencySymbol(currency)), selected: "\(Int(model.fuelFullCny))", fallback: fmtMoney(model.fuelFullCny, currency, 0), p: p) {
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
        case .recoveredAlert:
            let on = c.inp.settings.quotaRecoveredAlert
            SettingsRow(label: L("set.recovered"), help: L("set.recoveredHelp"), first: first, p: p) {
                PillSwitch(on: on, title: L("set.recovered")) {
                    model.updateProviderSettings { $0.quotaRecoveredAlert = !on }
                }
            }
        case .spikeAlert:
            SettingsRow(label: L("set.spike"), help: L("set.spikeHelp"), first: first, p: p) {
                PillSwitch(on: model.spikeAlertsOn, title: L("set.spike")) { model.spikeAlertsOn.toggle() }
            }
        case .quietHours:
            QuietHoursRow(live: input == nil && model.usageStore != nil && !kRendering,
                          first: first, p: p)
        }
    }

    // MARK: 通用页底部

    var generalFooter: some View {
        HStack {
            Spacer()
            Button(L("set.quit")) { model.quitForReal() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Color(nsColor: .systemRed))   // 破坏性操作用系统红，不用提醒色（用户 11-05）
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
