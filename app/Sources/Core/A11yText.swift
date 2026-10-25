import Foundation

/// VoiceOver 朗读文案：油量表、菜单栏按钮。与界面上看到的说法一致（续航规则与油量表下方的说明共用）
enum A11yText {
    /// 续航：不到 1 天按小时说，满 100 天说「可用很久」
    static func runway(_ days: Double) -> String {
        days < 1 ? L("a11y.runwayHours", String(format: "%.0f", days * 24))
            : days >= 100 ? L("a11y.runwayLong") : L("a11y.runwayDays", String(format: "%.0f", days))
    }

    private static func yuan(_ v: Double, _ cur: Currency = .cny) -> String {
        L(cur == .usd ? "a11y.dollars" : "a11y.yuan", String(format: "%.2f", v))
    }

    /// 如「DeepSeek 余额 55.95 元，约可用 5 天」
    static func gauge(provider: String, balanceCny: Double?, runwayDays: Double?,
                      currency: Currency = .cny) -> String {
        guard let b = balanceCny, b.isFinite else { return L("a11y.balanceUnknown", provider) }
        var parts = [L("a11y.balance", provider, yuan(b, currency))]
        if let d = runwayDays { parts.append(runway(d)) }
        return parts.joined(separator: L("a11y.sep"))
    }

    /// 套餐版，如「Codex 套餐 已用 41%，5 小时窗口 2 小时 13 分后重置」
    static func quotaGauge(provider: String, remainingPercent: Double?, reset: String?, exhausted: QuotaExhausted? = nil) -> String {
        if let exhausted { return "\(provider) \(exhausted.a11y)" }
        guard let r = remainingPercent, r.isFinite else { return L("a11y.usedUnknown", provider) }
        var parts = [L("a11y.used", provider, quotaUsedPercent(remaining: r))]
        if let reset { parts.append(reset) }
        return parts.joined(separator: L("a11y.sep"))
    }

    /// 菜单栏按钮的 label：固定是名字，读数放在 value 里（VoiceOver 读「Token Bar，<value>，按钮」）
    static var menuBarLabel: String { AppName.display }

    /// 菜单栏按钮的 value（套餐平台）：如「Claude 套餐 当前会话已用 23%，剩余 77%，2 小时 13 分后重置」
    static func menuBarQuotaValue(provider: String, reading: AppData.MenuQuota?, low: Bool, dim: Bool) -> String {
        var parts: [String] = []
        if let e = reading?.exhausted {
            parts.append("\(provider) \(e.a11y)")
        } else {
            parts.append(MenuBarText.quotaUsedText(provider: provider, reading: reading))
            if let u = reading?.usedPercent, u.isFinite { parts.append(remaining(100 - u)) }
            if let t = reading?.tighter { parts.append(t) }
            if let r = reading?.reset { parts.append(r) }
        }
        if low { parts.append(L("a11y.belowLine")) }
        if dim { parts.append(L("a11y.notLatest")) }
        return parts.joined(separator: L("a11y.sep"))
    }

    /// 菜单栏按钮的 value（按量付费）：图标和数字读不出来，用一句话说清余额、续航和异常
    static func menuBarValue(provider: String, needsSetup: Bool, balanceCny: Double?, runwayDays: Double?,
                        todayCny: Double?, showsTodayCost: Bool, low: Bool, spike: Bool, dim: Bool,
                        currency: Currency = .cny) -> String {
        if needsSetup { return L("a11y.noPlatforms") }
        guard balanceCny != nil || todayCny != nil else { return L("a11y.connecting", provider) }
        var parts = [gauge(provider: provider, balanceCny: balanceCny, runwayDays: runwayDays,
                                                           currency: currency)]
        if showsTodayCost, let t = todayCny { parts.append(L("a11y.todayCost", yuan(t, currency))) }
        if low { parts.append(L("a11y.belowLine")) }
        if spike { parts.append(L("a11y.spiking")) }
        if dim { parts.append(L("a11y.notLatest")) }
        return parts.joined(separator: L("a11y.sep"))
    }
}
