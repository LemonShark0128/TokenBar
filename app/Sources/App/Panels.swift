import AppKit
import Combine
import SwiftUI
import UserNotifications

// ---------------------------------------------------------------- 面板 / 小组件

struct PanelView: View {
    @ObservedObject var model: UsageModel
    let p: Palette
    @Namespace private var switchNS
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let style = SwitchMotion.style(reduceMotion: reduceMotion)
        let mainMatch = SwitchMatch(provider: model.mainID, ns: switchNS, style: style)
        VStack(alignment: .leading, spacing: PanelLayout.sectionGap) {
            HStack(spacing: 8) {
                Text(model.mainName).font(.system(size: 13, weight: .semibold)).foregroundColor(p.text)
                    .switchGeometry(mainMatch, "name")
                FreshDot(model: model, p: p)
                // 正在轮流：一排小圆点，当前那个实心（用户 10-19：让人知道面板为什么会自己换）
                if let rotation = model.usageStore?.menuBarRotation, rotation.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(rotation, id: \.self) { id in
                            Circle().fill(id == model.mainID ? p.sub : Color.clear)
                                .overlay(Circle().strokeBorder(p.sub, lineWidth: 1))
                                .frame(width: 5, height: 5)
                        }
                    }
                    .help(L("panel.rotating", rotation.map(ProviderRegistry.displayName).joined(separator: L("common.listSep"))))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("panel.rotating", rotation.map(ProviderRegistry.displayName).joined(separator: L("common.listSep"))))
                }
                if model.updating { ProgressView().controlSize(.mini).scaleEffect(0.6).accessibilityLabel(L("panel.refreshing")) }
                // 手动固定了主平台（或关了自动切换）：点一下恢复自动；只有一个平台时没有可切的，不显示
                if model.mainPinned && model.data?.sides.isEmpty == false {
                    Button { model.usageStore?.setAutoMain(true) } label: {
                        LT("panel.pinned").font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .overlay(Capsule().strokeBorder(p.sub.opacity(0.6), lineWidth: 0.8))
                    }
                    .buttonStyle(.plain).foregroundColor(p.sub)
                    .help(L("panel.pinnedHelp", model.mainName))
                    .accessibilityLabel(L("panel.pinnedA11y", model.mainName))
                    .accessibilityHint(L("panel.unpinHint"))
                }
                Spacer()
                HStack(spacing: 14) {
                    Button { model.fetch() } label: { Image(systemName: "arrow.clockwise") }
                        .help(L("panel.refreshNow"))
                        .accessibilityLabel(L("panel.refreshNow"))
                    Button {
                        model.onClosePanel?()
                        if !model.widgetVisible { model.toggleWidget() }
                    } label: { Image(systemName: "pip.exit") }
                        .help(L("panel.popOutHelp"))
                        .accessibilityLabel(L("panel.popOut"))
                    Button { model.openSettings() } label: { Image(systemName: "gearshape") }
                        .help(L("panel.settingsHelp"))
                        .accessibilityLabel(L("panel.settings"))
                    Button { model.onClosePanel?() } label: { Image(systemName: "xmark") }
                        .help(L("panel.closeHelp"))
                        .accessibilityLabel(L("panel.close"))
                        .accessibilityHint(L("panel.closeHint"))
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(p.sub)
            }

            if let banner = model.visibleBanner {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(riskTint(banner.severity, ok: Accent.orange))
                        .accessibilityHidden(true)
                    // 「预计可用时间：X，下次重置：HH:mm」一行放不下：最多折两行，不截断
                    Text(banner.text).font(.system(size: 12)).foregroundColor(p.text)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(L("panel.alertA11y", A11yText.speak(banner.text)))
                    Spacer(minLength: 0)
                    Button(L("panel.view")) {
                        if let id = ProviderID(rawValue: banner.id) { model.usageStore?.pinMain(id) }
                    }.buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Accent.blue).fixedSize()
                    .accessibilityLabel(L("panel.viewA11y"))
                    .accessibilityHint(L("panel.viewHint"))
                    Button { model.dismissBanner() } label: {
                        Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(p.sub)
                    }.buttonStyle(.plain).help(L("panel.dismissAlert"))
                    .accessibilityLabel(L("panel.dismissAlert"))
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(riskTint(banner.severity, ok: Accent.orange).opacity(0.14)))
                .transition(.opacity)
            }

            if let notice = model.switchNotice {
                Text(notice).font(.system(size: 11.5)).foregroundColor(p.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, -8)
                    .transition(.opacity)
            }

            if let d = model.data, d.balance.isQuota {
                // 套餐平台：表盘是已用百分比，金额区块换成窗口列表
                QuotaMain(model: model, d: d, p: p, match: mainMatch)
                sidesAndAdd(d, style: style)
            } else if let d = model.data {
                let (cap, spike) = burnCaption(d, fuelFull: model.fuelFullCny)
                FuelGauge(level: model.fuelLevel, balance: fmtMoney(d.balance.cny, d.balance.currency), caption: cap,
                          captionColor: spike ? Accent.orange : nil, chip: d.runway,
                          p: p,
                          a11yLabel: model.gaugeA11y(d), match: mainMatch)
                    .frame(maxWidth: .infinity)
                if costSourceTag(d.today.source) == "离线" {
                    // 冷启动断网：只有最后一次采样的余额，花费一概不显示（不是 ¥0.00）
                    LT("panel.offlineNote", model.mainName)
                        .font(.system(size: 11.5)).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(A11yText.offline(provider: model.mainName) + L("panel.offlineA11ySuffix"))
                } else if costSourceTag(d.today.source) == "余额" {
                    // 没登录控制台：花费看不到，不能写成 ¥0.00（看不到 ≠ 没花）
                    BalanceOnlyCallout(name: model.mainName, expired: model.mainState?.status == .consoleLoginNeeded,
                                       problem: model.mainState?.snapshot?.consoleProblem, p: p) {
                        model.openConsoleLogin()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        StatRow(items: [(L("panel.today"), fmtMoney(d.today.costCny, d.balance.currency)),
                                        (L("panel.month"), fmtMoney(d.month.costCny, d.balance.currency)),
                                        (L("panel.cacheHit"), overallHitRate(d.models))], p: p)
                            .help(costSourceTag(d.today.source) == "账单" ? L("panel.billHelp") : "")
                        SourceTag(source: d.today.source, p: p)
                    }
                    TrendStrip(chart: d.tokenChart(main: model.mainID), days: d.trend7, onPick: { model.openDetail($0) },
                               p: p, incomplete: d.trendIncomplete, picked: model.trendPick, onSelect: model.pickTrendDay)
                }
                sidesAndAdd(d, style: style)
                if !d.models.isEmpty {        // 只有余额时没有明细可看，整行不显示
                    Hairline(p: p)
                    Button { model.detailOpen.toggle(); model.onRefit?() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(model.detailOpen ? 90 : 0))
                                .accessibilityHidden(true)
                            LT("panel.tokenDetails").font(.system(size: 12))
                            Spacer()
                            if let m = model.currentModel {
                                LT("panel.modelHitRate", m.label, AppDataMapping.hitRateText(hit: m.cacheHit, miss: m.cacheMiss, rate: m.hitRate))
                                    .font(.num(11, .regular))
                            }
                        }
                        .foregroundColor(p.sub).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityValue(model.detailOpen ? L("panel.expanded") : L("panel.collapsed"))
                    if model.detailOpen {
                        TokenDetailCard(models: d.models, picked: $model.selectedModel, p: p)
                    }
                }
            } else if model.needsSetup {
                VStack(alignment: .leading, spacing: 8) {
                    LT("panel.addFirst").font(.system(size: 13, weight: .semibold)).foregroundColor(p.text)
                    LT("panel.addFirstNote")
                        .font(.system(size: 11.5)).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true)
                    Button(L("panel.addPlatform")) { model.openOnboarding(at: .pick) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Accent.blue)
                }
                .padding(.vertical, 20)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(StatusPresenter.offlineTitle(model.mainID)).font(.system(size: 13, weight: .semibold)).foregroundColor(p.text)
                    Text(model.error ?? (ProviderRegistry.meter(model.mainID) == .quota ? L("panel.retryLater") : L("panel.checkNetwork"))).font(.system(size: 11.5)).foregroundColor(p.warnText)
                    Button(L("panel.retry")) { model.fetch() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Accent.blue)
                }
                .padding(.vertical, 20)
            }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 16)
        // 减弱动态效果：主平台一换，整块内容按新身份重建并淡入淡出（不配对、不滑动）；否则身份不变，走配对动画
        .id(style == .fade ? model.mainID.rawValue : "panel")
        .transition(.opacity)
        .animation(style == .fade ? .easeInOut(duration: 0.25)
                   : .spring(response: SwitchMotion.springResponse, dampingFraction: SwitchMotion.springDamping),
                   value: model.mainID)
    }

    /// 辅助监控区：每个平台一行，点一行设为主平台；标题右侧是今日合计。末尾是「添加/移除平台」（打开选平台页）
    @ViewBuilder
    private func sidesAndAdd(_ d: AppData, style: SwitchMotion.Style) -> some View {
        if !model.runningTasks.isEmpty {
            Hairline(p: p)
            RunningTasksSection(tasks: model.runningTasks, fixedNow: model.fixedNow, p: p, compact: false)
        }
        if !d.sides.isEmpty {
            Hairline(p: p)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    SectionTitle(text: L("panel.otherPlatforms"), p: p)
                    Spacer()
                    if d.sidesByRisk {
                        LT("panel.currentLeft").font(.system(size: 11)).foregroundColor(p.sub)
                    } else if let t = d.totalTodayCny {
                        LT("panel.todayTotal", d.totalIsApprox ? "≈" : "", fmtCNY(t))
                            .font(.num(11, .regular)).foregroundColor(p.sub)
                    }
                }
                ForEach(d.sides) { sd in
                    Button { if let id = ProviderID(rawValue: sd.id) { model.usageStore?.pinMain(id) } } label: {
                        SideRow(side: sd, level: model.fuelLevel(of: sd), p: p,
                                match: ProviderID(rawValue: sd.id).map { SwitchMatch(provider: $0, ns: switchNS, style: style) })
                    }.buttonStyle(.plain)
                    .help(L("panel.clickToPin"))
                    .accessibilityHint(L("action.pinIt"))
                }
            }
        }
        Hairline(p: p)
        Button { model.openOnboarding(at: .pick) } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle").font(.system(size: 13)).accessibilityHidden(true)
                Text(PanelLayout.addRemoveTitle).font(.system(size: 12))
                Spacer()
            }
            .foregroundColor(Accent.blue).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// 套餐平台作主平台的主区：表盘读已用百分比（最紧的窗口），下面是另一个窗口、窗口列表和最近一次使用。
/// 还没有额度数据时只写一句说明，不画 0%
struct QuotaMain: View {
    @ObservedObject var model: UsageModel
    let d: AppData
    let p: Palette
    var match: SwitchMatch? = nil
    var body: some View {
        if let q = d.quota, let r = q.remainingPercent {
            FuelGauge(level: model.fuelLevel, balance: q.exhausted?.gaugeValue ?? L("panel.used", quotaUsedPercent(remaining: r)), caption: q.headline ?? "", chip: d.runway, p: p,
                      a11yLabel: model.gaugeA11y(d), match: match, dimmed: q.stale, quota: true, overline: q.exhausted?.gaugeOverline)
                .frame(maxWidth: .infinity)
            hookGone
            QuotaWindowList(rows: q.rows, p: p, dimmed: q.stale)
            if let note = q.staleNote {
                Text(note).font(.system(size: 11, weight: .semibold)).foregroundColor(p.warnText)
            }
            if let l = q.lastUsed {
                Text(l).font(.system(size: 11)).foregroundColor(p.sub)
            }
            localTrend
        } else {
            Text(d.quota?.note ?? L("codex.noDataNote")).font(.system(size: 12)).foregroundColor(p.sub)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 20)
                .accessibilityLabel(A11yText.quotaNoData(provider: model.mainName, note: d.quota?.note))
            hookGone
        }
    }

    /// 套餐平台作主平台：有本机日志或其他平台的用量时，也画「近 7 天 token」合并图（点柱子看那天各模型，没有「明细 ›」）
    @ViewBuilder private var localTrend: some View {
        let chart = d.tokenChart(main: model.mainID)
        if !chart.isEmpty {
            TrendStrip(chart: chart, days: [], onPick: { _ in }, p: p, picked: model.trendPick, onSelect: model.pickTrendDay)
        }
    }

    /// Claude 套餐的状态栏钩子被换掉了：额度不会再更新，给「重装」
    @ViewBuilder private var hookGone: some View {
        if model.mainID == .claudePlan && model.claudeHookGone {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundColor(Accent.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ClaudeHookCopy.hookGone).font(.system(size: 12.5, weight: .medium)).foregroundColor(p.text)
                    LT("panel.hookGoneNote").font(.system(size: 11)).foregroundColor(p.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { model.reinstallClaudeHook() } label: {
                    LT("panel.reinstall").font(.system(size: 12, weight: .medium))
                }.buttonStyle(.plain).foregroundColor(Accent.blue)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.cardAlt))
        }
    }
}

/// 今天所有模型合计的缓存命中率
func overallHitRate(_ ms: [AppData.ModelUse]) -> String {
    let hit = ms.reduce(0) { $0 + $1.cacheHit }
    let all = ms.reduce(0) { $0 + $1.cacheHit + $1.cacheMiss }
    return all > 0 ? String(format: "%.1f%%", Double(hit) * 100 / Double(all)) : "—"
}

/// 小组件（精简）：两页 —— 余额（油量表 + 今日/本月）和今日 Token，在标题行点切换。
/// 两页同高，切换时窗口不跳；记住上次看的那一页。
struct WidgetView: View {
    @ObservedObject var model: UsageModel
    static let pageHeight: CGFloat = 222
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = Palette.of(model.dark)
        // 套餐平台没有 token 数据：不显示「余额 / Token」切换，始终是余额页
        let isPlan = ProviderRegistry.meter(model.mainID) == .quota
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // 多平台时点后面写当前主平台（新鲜度挪到悬停提示里），切换主平台后看得出是哪个；
                // 点平台名弹出平台列表，选中即设为主平台（与面板里点辅助行相同）
                let title = AppDataMapping.widgetTitle(mainName: model.mainName, otherCount: model.data?.sides.count ?? 0)
                if title != nil {
                    Button { popUpPlatformMenu(model) } label: {
                        HStack(spacing: 3) {
                            FreshDot(model: model, p: p, title: title)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundColor(p.sub)
                                .accessibilityHidden(true)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(L("panel.pickToPin"))
                } else {
                    FreshDot(model: model, p: p, title: nil)
                }
                Spacer()
                // 隐藏但占位：表盘位置和按量付费平台一致
                SegmentPicker(items: [("balance", L("widget.balance")), ("tokens", "Token")], selected: model.widgetPage, p: p) {
                    model.widgetPage = $0
                }
                .fixedSize()        // 多平台标题行放不下时挤的是状态文字，不是切换器
                .opacity(isPlan ? 0 : 1).allowsHitTesting(!isPlan).accessibilityHidden(isPlan)
                Button { model.fetch() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundColor(p.sub)
                    .help(L("panel.refreshNow"))
                    .accessibilityLabel(L("panel.refreshNow"))
                // 和面板里的「弹出成小组件」成对：收起小组件、回到面板
                Button { model.returnToPanel() } label: { Image(systemName: "pip.enter") }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundColor(p.sub)
                    .help(L("widget.backToPanel"))
                    .accessibilityLabel(L("widget.backToPanel"))
            }
            Group {
                if let d = model.data {
                    if model.widgetPage == "tokens" && !isPlan {
                        if d.models.isEmpty && model.mainID != .deepseek {
                            // 该平台没有按模型的明细；DeepSeek 登录控制台后才有明细，保持原来的 Token 页
                            LT("widget.noModelDetails").font(.system(size: 11.5)).foregroundColor(p.sub)
                        } else {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(cnCount(d.today.tokens)).font(.num(26, .semibold)).foregroundColor(p.text)
                                LT("widget.todayTokens").font(.system(size: 11.5)).foregroundColor(p.sub)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(A11yText.todayTokens(d.today.tokens))
                            ModelShare(models: d.models, compact: true, currency: d.balance.currency, p: p)
                            TokenDetailCard(models: d.models, picked: $model.selectedModel, p: p)
                        }
                        }
                    } else if d.balance.isQuota {
                        // 套餐平台：表盘写已用百分比，说明是最紧窗口的重置时间
                        VStack(alignment: .leading, spacing: 8) {
                            if let q = d.quota, let r = q.remainingPercent {
                                FuelGauge(level: model.fuelLevel, balance: q.exhausted?.gaugeValue ?? L("panel.used", quotaUsedPercent(remaining: r)), caption: d.runway?.short ?? q.headlineCompact ?? q.headline ?? "",
                                          diameter: 172, big: 27, p: p, a11yLabel: model.gaugeA11y(d), dimmed: q.stale, quota: true, overline: q.exhausted?.gaugeOverline)
                                    .frame(maxWidth: .infinity)
                                QuotaStatRow(rows: Array(q.rows.prefix(2)), p: p, dimmed: q.stale)
                                if let note = q.staleNote {
                                    Text(note).font(.system(size: 11, weight: .semibold)).foregroundColor(p.warnText)
                                }
                                QuotaSourceLine(plan: q.plan, lastUsed: q.lastUsed, p: p)
                            } else {
                                Text(d.quota?.note ?? L("codex.noDataNote")).font(.system(size: 11.5)).foregroundColor(p.sub)
                                    .accessibilityLabel(A11yText.quotaNoData(provider: model.mainName, note: d.quota?.note))
                            }
                        }
                        .id(model.mainID)
                        .transition(SwitchMotion.style(reduceMotion: reduceMotion) == .fade
                                    ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            let (cap, spike) = burnCaption(d, fuelFull: model.fuelFullCny)
                            FuelGauge(level: model.fuelLevel, balance: fmtMoney(d.balance.cny, d.balance.currency), caption: d.runway?.short ?? cap,
                                      captionColor: spike ? Accent.orange : nil,
                                      diameter: 172, big: 27, p: p, a11yLabel: model.gaugeA11y(d))
                                .frame(maxWidth: .infinity)
                            if costSourceTag(d.today.source) == "余额" {
                                SourceTag(source: d.today.source, p: p)
                            } else {
                                StatRow(items: [(L("panel.today"), fmtMoney(d.today.costCny, d.balance.currency)),
                                                (L("panel.month"), fmtMoney(d.month.costCny, d.balance.currency))], p: p)
                                SourceTag(source: d.today.source, p: p)
                            }
                        }
                        // 小组件只有主平台一块：换主平台时整页过渡（减弱动态效果时只淡入淡出）
                        .id(model.mainID)
                        .transition(SwitchMotion.style(reduceMotion: reduceMotion) == .fade
                                    ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                    }
                } else {
                    Text(model.error ?? (model.needsSetup ? L("a11y.noPlatforms") : L("status.connecting", model.mainName))).font(.system(size: 11.5)).foregroundColor(p.sub)
                }
            }
            .frame(height: WidgetView.pageHeight, alignment: .top)
            .animation(reduceMotion ? .easeInOut(duration: 0.25)
                       : .spring(response: SwitchMotion.springResponse, dampingFraction: SwitchMotion.springDamping),
                       value: model.mainID)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
    }
}

/// 小组件里套餐平台的两栏（对应按量付费的「今日 / 本月」）：窗口名、已用百分比、重置时间
struct QuotaStatRow: View {
    let rows: [AppData.QuotaRow]
    let p: Palette
    var dimmed: Bool = false
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name).font(.system(size: 11)).foregroundColor(p.sub)
                    Text(r.isReset ? L("quota.windowResetShort") : L("panel.usedPct", Int(r.usedPercent.rounded()))).font(.num(17, .semibold))
                        .foregroundColor(dimmed ? p.sub.opacity(0.5) : p.text).lineLimit(1).minimumScaleFactor(0.7)
                    if let reset = r.resetShort {
                        Text(reset).font(.system(size: 10.5)).foregroundColor(p.sub).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 只有一个窗口时靠左，右半边留空
            if rows.count == 1 { Spacer().frame(maxWidth: .infinity) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rows.map(A11yText.quotaWindow).joined(separator: L("panel.a11yListSep")) + (dimmed ? L("panel.noData") : ""))
    }
}

/// 套餐平台的来源行，样式同「● 平台账单口径」：「Plus 套餐 · 最近一次使用：12 分钟前」
struct QuotaSourceLine: View {
    let plan: String?
    let lastUsed: String?
    let p: Palette
    var body: some View {
        let text = [plan, lastUsed].compactMap { $0 }.joined(separator: " · ")
        if !text.isEmpty {
            HStack(spacing: 4) {
                Circle().fill(p.sub).frame(width: 5, height: 5)
                Text(text).font(.system(size: 10.5)).foregroundColor(p.sub).lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(A11yText.speak(text))
        }
    }
}

struct RootView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        let p = Palette.of(model.dark)
        Group {
            if kRendering {
                // ImageRenderer 不渲染 ScrollView 里的内容 → 自检时直接平铺（否则 panel-*.png 是空白）
                PanelView(model: model, p: p).frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView { PanelView(model: model, p: p) }.scrollIndicators(.never)
            }
        }
        .frame(width: kPanelWidth, height: kRendering ? 820 : model.panelHeight)
        .background(Backdrop(p: p))
        .onAppear { model.fetch() }
    }
}

/// 只有余额时，替代「今日/本月/趋势」的位置：说明为什么看不到花费，并给出登录入口
struct BalanceOnlyCallout: View {
    let name: String
    let expired: Bool
    /// 控制台登录有效但取不到花费的原因（如认不出这把 Key）
    var problem: String? = nil
    let p: Palette
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 原来是字面量（闭包和三目里），走的是本地化排版（见 LT）
            Text("\(problem.map { L("panel.noSpend", $0) } ?? (expired ? L("panel.consoleExpired", name) : L("panel.loginConsoleFor", name)))")
                .font(.system(size: 12.5, weight: .medium)).foregroundColor(p.text)
            // 原来是几个字面量的三目，走的是本地化排版（见 LT）
            Text("\(problem != nil ? L("panel.balanceSameAccount", name) : expired ? L("panel.balanceReloginNote") : L("panel.consoleOptional"))")
                .font(.system(size: 11)).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                Text(expired ? L("action.reloginConsole") : L("action.loginConsole")).font(.system(size: 12, weight: .medium))
            }.buttonStyle(.plain).foregroundColor(Accent.blue)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.cardAlt))
    }
}

/// 小组件标题的平台列表（NSMenu 弹在鼠标处）：选中别的平台就设为主平台
@MainActor func popUpPlatformMenu(_ model: UsageModel) {
    guard let ev = NSApp.currentEvent, let view = ev.window?.contentView else { return }
    let items = AppDataMapping.widgetPlatformMenu(mainID: model.mainID.rawValue, mainName: model.mainName,
                                                  sides: model.data?.sides ?? [])
    guard !items.isEmpty else { return }
    let menu = NSMenu()
    menu.autoenablesItems = false
    for it in items {
        let mi = BlockMenuItem(title: it.title) {
            guard let id = ProviderID(rawValue: it.id) else { return }
            logLine("小组件切换主平台：\(it.title)")
            model.usageStore?.pinMain(id)
        }
        mi.state = it.isMain ? .on : .off
        mi.isEnabled = !it.isMain
        menu.addItem(mi)
    }
    NSMenu.popUpContextMenu(menu, with: ev, for: view)
}

/// 带闭包的菜单项
final class BlockMenuItem: NSMenuItem {
    private let block: () -> Void
    init(title: String, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { block() }
}
