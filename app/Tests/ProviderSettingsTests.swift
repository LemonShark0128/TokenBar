import Foundation

@MainActor
func registerProviderSettingsTests() {
    test("settingsMigrateDeepSeekAlert") {
        let d = freshDefaults()
        d.set(10.0, forKey: "balanceAlertCny")
        try checkEqual(ProviderSettings.load(d).lowAlerts[.deepseek], 10)
        d.set("5", forKey: "lowAlert.deepseek")
        try checkEqual(ProviderSettings.load(d).lowAlerts[.deepseek], 5)
    }
    test("settingsRoundTrip") {
        let d = freshDefaults()
        var s = ProviderSettings()
        s.usdToCny = Decimal(string: "7.25")!
        s.lowAlerts[.siliconflow] = 5
        s.save(d)
        try checkEqual(ProviderSettings.load(d), s)
        try checkEqual(ProviderSettings.load(freshDefaults()).usdToCny, Decimal(string: "7.1")!)
    }
    test("settingsClearedAlertStaysCleared") {
        let d = freshDefaults()
        d.set(10.0, forKey: "balanceAlertCny")
        var s = ProviderSettings.load(d)
        try checkEqual(s.lowAlerts[.deepseek], 10)
        s.lowAlerts[.deepseek] = nil
        s.save(d)
        try check(ProviderSettings.load(d).lowAlerts[.deepseek] == nil, "清掉后不应被旧值复活")
    }
}
