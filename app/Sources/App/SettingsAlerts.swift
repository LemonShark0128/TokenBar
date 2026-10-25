import AppKit
import Combine
import SwiftUI

// ---------------------------------------------------------------- 设置「提醒」页：预警线、每小时花费（列宽 alertColumnWidth 是存储属性，留在 Settings.swift）

extension SettingsView {
    func alertHeader(quota: Bool) -> some View {
        HStack(spacing: 6) {
            LT("page.platform")
            Spacer(minLength: 10)
            Text(quota ? L("set.alert.remainingBelow") : L("set.alert.balanceBelow")).frame(width: alertColumnWidth, alignment: .trailing)
            if !quota { LT("set.alert.hourlyOver").frame(width: alertColumnWidth, alignment: .trailing) }
        }
        .font(.system(size: 11)).foregroundColor(p.sub)
        .padding(.horizontal, 12).frame(height: 26)
    }

    func alertRow(_ id: ProviderID, first: Bool, _ c: Ctx) -> some View {
        VStack(spacing: 0) {
            if !first { Hairline(p: p).padding(.leading, 12) }
            HStack(spacing: 6) {
                Text(ProviderRegistry.displayName(id)).font(.system(size: 12.5)).foregroundColor(p.text).lineLimit(1).fixedSize()
                if c.main == id { MainBadge() }
                Spacer(minLength: 10)
                DropdownButton(title: L("set.alertLineFor", ProviderRegistry.displayName(id)),
                               options: SettingsLayout.alertOptions(quota: ProviderRegistry.meter(id) == .quota, symbol: symbol(id, c)),
                               selected: alertKey(id, c), p: p) { pickAlert($0, id, c) }
                    .frame(width: alertColumnWidth, alignment: .trailing)
                if ProviderRegistry.meter(id) == .money {
                    hourlyButton(id, c).frame(width: alertColumnWidth, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12).frame(minHeight: 36)
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

    /// 主平台读写 balanceAlertCny（它是 lowAlerts[主平台] 的镜像），其他平台直接读写 lowAlerts
    func alertValue(_ id: ProviderID, _ c: Ctx) -> Double {
        if id == c.main { return model.balanceAlertCny }
        return c.inp.settings.lowAlerts[id].map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
    }

    func alertKey(_ id: ProviderID, _ c: Ctx) -> String {
        SettingsLayout.alertSelection(value: alertValue(id, c),
                                      custom: id == c.main ? model.balanceAlertCustom : model.alertCustomOpen.contains(id))
    }

    func symbol(_ id: ProviderID, _ c: Ctx) -> String {
        id == c.main ? currencySymbol(model.data?.balance.currency) : "¥"
    }

    func pickAlert(_ k: String, _ id: ProviderID, _ c: Ctx) {
        switch SettingsLayout.alertPick(k) {
        case .custom:
            if id == c.main { model.balanceAlertCustom = true } else { model.alertCustomOpen.insert(id) }
        case .set(let d):
            if id == c.main {
                model.balanceAlertCustom = false
                model.balanceAlertCny = d.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
            } else {
                model.alertCustomOpen.remove(id)
                model.updateProviderSettings { $0.lowAlerts[id] = d }
            }
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
                    if id == c.main {
                        if let d { model.balanceAlertCny = NSDecimalNumber(decimal: d).doubleValue }
                    } else {
                        // 正在输入：值变成 0 时输入框也要留着，不能整行消失
                        model.alertCustomOpen.insert(id)
                        model.updateProviderSettings { $0.lowAlerts[id] = d }
                    }
                }
                .id("alert-custom-\(id.rawValue)")
                if isQuota { Text("%").font(.system(size: 12)).foregroundColor(p.sub) }
            }
        }
    }
}
