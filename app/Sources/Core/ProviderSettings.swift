import Foundation

/// 各平台设置：汇率、低油量预警线（存 UserDefaults）。
/// 已删平台留下的 budget.claude、lowAlert.openai 等旧键不读也不删，无害
struct ProviderSettings: Equatable {
    var usdToCny: Decimal = Decimal(string: "7.1")!
    var lowAlerts: [ProviderID: Decimal] = [:]
    /// 每小时花费超过多少提醒（按量付费平台；键不存在 = 关，用户 2026-10-17 定默认关）
    var hourlyAlerts: [ProviderID: Decimal] = [:]
    /// 套餐重置前会用完时提醒（默认开）
    var quotaRunoutAlert = true

    static let usdToCnyKey = "usdToCny"
    static let quotaRunoutAlertKey = "quotaRunoutAlert"
    static func lowAlertKey(_ id: ProviderID) -> String { "lowAlert.\(id.rawValue)" }
    static func hourlyAlertKey(_ id: ProviderID) -> String { "hourlyAlert.\(id.rawValue)" }

    private static func decimal(_ d: UserDefaults, _ key: String) -> Decimal? {
        if let s = d.string(forKey: key) { return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) }
        return nil
    }

    static func load(_ d: UserDefaults) -> ProviderSettings {
        var s = ProviderSettings()
        if let r = decimal(d, usdToCnyKey), r > 0 { s.usdToCny = r }
        for id in ProviderID.allCases {
            if let a = decimal(d, lowAlertKey(id)), a > 0 { s.lowAlerts[id] = a }
        }
        for id in ProviderID.allCases where ProviderRegistry.meter(id) == .money {
            if let a = decimal(d, hourlyAlertKey(id)), a > 0 { s.hourlyAlerts[id] = a }
        }
        if d.object(forKey: quotaRunoutAlertKey) != nil { s.quotaRunoutAlert = d.bool(forKey: quotaRunoutAlertKey) }
        // 套餐平台预警线按百分比，键不存在时默认 10
        for id in ProviderID.allCases where ProviderRegistry.meter(id) == .quota && d.object(forKey: lowAlertKey(id)) == nil {
            s.lowAlerts[id] = 10
        }
        // DeepSeek 预警线：首次从旧的全局 balanceAlertCny 迁移
        // 键已存在（含显式关闭的 "0"）就不再迁移，用户清掉预警后不会被旧值复活
        if d.object(forKey: lowAlertKey(.deepseek)) == nil, d.object(forKey: "balanceAlertCny") != nil {
            let old = d.double(forKey: "balanceAlertCny")
            if old > 0, let v = Decimal(string: String(old), locale: Locale(identifier: "en_US_POSIX")) {
                s.lowAlerts[.deepseek] = v
            }
        }
        return s
    }

    func save(_ d: UserDefaults) {
        d.set("\(usdToCny)", forKey: Self.usdToCnyKey)
        for id in ProviderID.allCases {
            if let a = lowAlerts[id] { d.set("\(a)", forKey: Self.lowAlertKey(id)) }
            // DeepSeek 与套餐平台清掉预警线时存 "0"（显式关闭），否则下次 load 会从旧 balanceAlertCny 再迁移回来
            else if id == .deepseek || ProviderRegistry.meter(id) == .quota { d.set("0", forKey: Self.lowAlertKey(id)) }
            else { d.removeObject(forKey: Self.lowAlertKey(id)) }
            if let h = hourlyAlerts[id], h > 0 { d.set("\(h)", forKey: Self.hourlyAlertKey(id)) }
            else { d.removeObject(forKey: Self.hourlyAlertKey(id)) }
        }
        d.set(quotaRunoutAlert, forKey: Self.quotaRunoutAlertKey)
    }
}
