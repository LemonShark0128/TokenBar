import AppKit
import SwiftUI

struct QuietHoursRow: View {
    let live: Bool
    let first: Bool
    let p: Palette
    @State private var selected = "off"

    var body: some View {
        SettingsRow(label: L("set.quietHours"), help: L("set.quietHoursHelp"), first: first, p: p) {
            // 用同页自绘下拉（原生 Picker 离屏预览画不出来）
            DropdownButton(title: L("set.quietHours"),
                           options: [("off", L("set.quietHours.off")), ("22-7", "22:00–7:00"),
                                     ("23-8", "23:00–8:00"), ("0-8", "0:00–8:00")],
                           selected: selected, p: p) { value in
                selected = value
                if live { QuietHours.save(QuietHours.parse(value), .standard) }
            }
            .onAppear { if live { selected = QuietHours.load(.standard)?.value ?? "off" } }
        }
    }
}

// ---------------------------------------------------------------- 设置「提醒」页：平台读数、预警线、每小时花费

extension SettingsView {
    func alertStatusRow(_ id: ProviderID, first: Bool, _ c: Ctx) -> some View {
        let snapshot = c.inp.platforms.first { $0.id == id }?.snapshot
        let meter = ProviderRegistry.meter(id)
        let reading = AccountReading.from(snapshot: snapshot, meter: meter, now: model.fixedNow ?? Date())
        let stale = id == .claudePlan && model.claudeHookGone
        let statusReading = SettingsLayout.alertStatusReading(state: c.states[id] ?? .notAdded,
                                                              reading: reading, stale: stale)
        return VStack(spacing: 0) {
            if !first { Hairline(p: p).padding(.leading, 12) }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(statusReading?.text ?? (stale ? ClaudeHookCopy.hookGone : (c.states[id] ?? .notAdded).label(for: id)))
                        .font(.system(size: 12.5)).foregroundColor(p.text)
                    if c.main == id { MainBadge() }
                    Spacer(minLength: 0)
                }
                if let fraction = SettingsLayout.alertBarFraction(statusReading, fuelFull: model.fuelFullCny,
                                                                  scale: SettingsLayout.gaugeScaleCurrency(added: c.added,
                                                                                                           actual: SettingsLayout.balanceCurrencies(c.inp.platforms)),
                                                                  usdToCny: model.gaugeRate) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(p.track)
                            Capsule().fill(meter == .quota ? quotaTint(QuotaLevel.severity(remainingFraction: fraction)) : levelTint(fraction))
                                .frame(width: g.size.width * fraction)
                        }
                    }.frame(height: 4)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(minHeight: 36)
        }
    }

    func hourlyButton(_ id: ProviderID, _ c: Ctx) -> some View {
        let v = c.inp.settings.hourlyAlerts[id]
        let sym = symbol(id, c)
        return DropdownButton(title: L("set.hourlyFor", ProviderRegistry.displayName(id)),
                              options: SettingsLayout.hourlyOptions(symbol: sym), selected: SettingsLayout.hourlySelection(v),
                              fallback: v.map { "\(sym)\($0)" }, p: p) { k in
            let d = Decimal(string: k, locale: Locale(identifier: "en_US_POSIX"))
            model.updateProviderSettings { $0.hourlyAlerts[id] = (d ?? 0) > 0 ? d : nil }
        }
        .help(L("set.alert.hourlyHelp"))
    }

    /// 预警线只存在 ProviderSettings.lowAlerts 一处（所有平台同一套读写）；离屏渲染时正在显示的平台用给定值
    func alertValue(_ id: ProviderID, _ c: Ctx) -> Double {
        if id == c.main, let r = model.renderAlert { return r }
        return c.inp.settings.lowAlerts[id].map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
    }

    func alertKey(_ id: ProviderID, _ c: Ctx) -> String {
        SettingsLayout.alertSelection(value: alertValue(id, c), custom: model.alertCustomOpen.contains(id))
    }

    func symbol(_ id: ProviderID, _ c: Ctx) -> String {
        SettingsLayout.alertSymbol(id, main: c.main, mainCurrency: model.data?.balance.currency)
    }

    func pickAlert(_ k: String, _ id: ProviderID) {
        switch SettingsLayout.alertPick(k) {
        case .custom:
            model.alertCustomOpen.insert(id)
        case .set(let d):
            model.alertCustomOpen.remove(id)
            model.updateProviderSettings { $0.lowAlerts[id] = d }
        case .ignore: break
        }
    }

    func alertCustomRow(_ id: ProviderID, first: Bool, _ c: Ctx) -> some View {
        let isQuota = ProviderRegistry.meter(id) == .quota
        let v = alertValue(id, c)
        return SettingsRow(label: L("set.alert.customLabel"), first: first, p: p) {
            HStack(spacing: 4) {
                if !isQuota { Text(symbol(id, c)).font(.system(size: 12)).foregroundColor(p.sub) }
                AmountField(value: v > 0 ? Decimal(string: String(v), locale: Locale(identifier: "en_US_POSIX")) : nil,
                            placeholder: "8") { d in
                    guard case .set(let d) = SettingsLayout.customAlertInput(d, quota: isQuota, isMain: id == c.main) else { return }
                    // 正在输入：值变成 0 时输入框也要留着，不能整行消失
                    model.alertCustomOpen.insert(id)
                    model.updateProviderSettings { $0.lowAlerts[id] = d }
                }
                .id("alert-custom-\(id.rawValue)")
                if isQuota { Text("%").font(.system(size: 12)).foregroundColor(p.sub) }
            }
        }
    }
}
