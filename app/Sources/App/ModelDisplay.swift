import AppKit
import Combine
import SwiftUI
import UserNotifications

// ---------------------------------------------------------------- 状态：界面读数（菜单栏信号、油量、套餐行、朗读）

extension UsageModel {
    /// 菜单栏图标的信号：低于预警线变橙、花费飙升加橙点、数据不新鲜整体变灰
    var menuSignal: (low: Bool, spike: Bool, dim: Bool) {
        guard let d = data else { return (false, false, true) }
        // 任一辅助平台异常（凭据失效、连不上…）也让图标变橙，沿用「飙升」的橙色规则
        let sideBad = d.sides.contains { $0.needsAttention }
        let spiking = spikeAlertsOn && d.burn?.spike == true
        var low = balanceAlertCny > 0 && (d.balance.cny ?? .infinity) < balanceAlertCny
        // 菜单栏数字是另一个平台时：数字是否变橙只看它自己的预警线（没有油箱读数就不算低）；
        // 主平台低于预警线仍让图标变橙（算作异常，与辅助平台异常同一规则）
        if let mb = menuBarSide, mb.id != mainID.rawValue {
            let mainLow = low
            low = false
            // 套餐平台比剩余百分比（预警线也是百分比）
            if let id = ProviderID(rawValue: mb.id), let th = ProviderSettings.load(.standard).lowAlerts[id],
               let t = mb.isQuota ? mb.quotaRemaining : mb.tank {
                low = NSDecimalNumber(decimal: th).doubleValue > t
            }
            return (low, spiking || sideBad || mainLow, freshness.0 != .ok)
        }
        return (low, spiking || sideBad, freshness.0 != .ok)
    }

    /// 主平台 id 与显示名（没有主平台状态时按 DeepSeek）
    var mainID: ProviderID { mainState?.id ?? .deepseek }
    var mainName: String { ProviderRegistry.displayName(mainID) }

    /// 界面状态判断的输入：主平台状态 + 当前显示的数据 + 设置
    var statusInput: StatusPresenter.Input {
        StatusPresenter.Input(state: mainState, data: data, error: error, now: fixedNow ?? Date(), providerName: mainName)
    }

    /// 小组件 → 面板：关掉小组件（开关同步为关）并打开面板
    func returnToPanel() {
        logLine("小组件：回到面板")
        if widgetVisible { toggleWidget() }
        onOpenPanel?()
    }

    /// 数据健康：标题栏那颗点（判断在 Core 的 StatusPresenter）
    typealias Freshness = FreshnessLevel
    var freshness: (Freshness, String) { StatusPresenter.freshness(statusInput) }

    /// 油量表读数：可用余额 ÷ 满盘（0…1）
    var fuelLevel: Double {
        guard let bal = data?.balance.cny, bal.isFinite else { return 0 }
        // 套餐平台：输入保留剩余比例，表盘内部换算已用
        if data?.balance.isQuota == true { return max(0, min(1, bal / 100)) }
        return max(0, min(1, bal / max(1, fuelFullCny)))
    }

    /// 油量表的 VoiceOver 朗读
    func gaugeA11y(_ d: AppData) -> String {
        if d.balance.isQuota {
            return A11yText.quotaGauge(provider: mainName, remainingPercent: d.quota?.remainingPercent, reset: d.runway?.title ?? d.quota?.headline,
                                       exhausted: d.quota?.exhausted)
        }
        if let runway = d.runway {
            return A11yText.gauge(provider: mainName, balanceCny: d.balance.cny, runwayDays: nil,
                                  currency: d.balance.currency == "USD" ? .usd : .cny) + "，" + runway.title
        }
        return A11yText.gauge(provider: mainName, balanceCny: d.balance.cny, runwayDays: d.burn?.runwayDays,
                       currency: d.balance.currency == "USD" ? .usd : .cny)
    }

    /// 一行辅助平台 / 菜单栏平台的油量（0…1）
    func fuelLevel(of s: AppData.Side) -> Double {
        if s.isQuota { return s.quotaRemaining.map { max(0, min(1, $0 / 100)) } ?? 0 }
        guard let t = s.tank, t.isFinite else { return 0 }
        return max(0, min(1, t / max(1, fuelFullCny)))
    }

    /// 标题栏那颗点的套餐版：短写「12 分钟前」「刚刚」（完整的「最近一次使用」在油箱下方）；
    /// 还没有额度数据为「暂无数据」。不是套餐平台、或平台有异常时为 nil（沿用 freshness）
    var quotaFreshShort: (text: String, hasData: Bool)? {
        guard let st = mainState, ProviderRegistry.meter(st.id) == .quota, st.status == .ok else { return nil }
        guard let q = st.snapshot?.quota else { return (L("common.noData"), false) }
        return (QuotaText.lastUsedShort(q.observedAt, now: fixedNow ?? Date()), true)
    }

    /// 主平台是套餐平台时，它的一行数据（剩余百分比 + 紧凑的重置时间）；不是套餐平台为 nil
    var mainQuotaSide: AppData.Side? {
        guard let st = mainState, ProviderRegistry.meter(st.id) == .quota else { return nil }
        return AppDataMapping.side(st, now: fixedNow ?? Date(), timeZone: fixedTimeZone ?? .autoupdatingCurrent)
    }

    /// 菜单栏平台是套餐平台时的那一行（菜单栏平台就是主平台时现算）
    var menuBarQuotaSide: AppData.Side? {
        if let mb = menuBarSide { return mb.isQuota ? mb : nil }
        return mainQuotaSide
    }
}
