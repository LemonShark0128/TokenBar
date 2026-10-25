import Foundation

/// 英文界面（第 16 条）：文案表完整、占位一致、源码里用到的 key 都在表里；英文下关键文案的样子
@MainActor
func registerL10nTests() {
    /// 临时切到英文跑一段，结束切回中文（其余测试都按中文断言）
    func english(_ body: () throws -> Void) rethrows {
        L10n.lang = .en
        defer { L10n.lang = .zh }
        try body()
    }

    test("l10nEveryKeyHasBothLanguages") {
        var seen = Set<String>()
        for e in L10n.entries {
            try check(!seen.contains(e.key), "重复 key：\(e.key)")
            seen.insert(e.key)
            try check(!e.key.isEmpty, "空 key")
            try check(!e.zh.isEmpty, "\(e.key) 没有中文")
            try check(!e.en.isEmpty, "\(e.key) 没有英文")
            try check(!e.en.contains(where: { ("\u{4e00}"..."\u{9fff}").contains($0) }), "\(e.key) 的英文里有汉字：\(e.en)")
        }
        try check(L10n.entries.count > 400, "条目太少：\(L10n.entries.count)")
    }

    test("l10nPlaceholdersMatch") {
        // 中文、英文用到的参数下标要一样（英文可以写成 {0|day|days}）
        func indices(_ s: String) -> Set<Int> {
            let r = try! NSRegularExpression(pattern: #"\{(\d+)(\|[^}]*)?\}"#)
            return Set(r.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
                Range($0.range(at: 1), in: s).flatMap { Int(s[$0]) }
            })
        }
        for e in L10n.entries {
            try checkEqual(indices(e.zh), indices(e.en), file: "\(e.key)")
        }
    }

    test("l10nKeysUsedInSourcesExist") {
        // 扫 Sources 里的 L("…") / LT("…")；拼出来的 key（带 \( ）跳过，下面单独查
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let r = try NSRegularExpression(pattern: #"\bLT?\("([^"\\]+)""#)
        var used = Set<String>()
        for dir in ["Core", "App"] {
            let d = src.appendingPathComponent(dir)
            for f in try FileManager.default.contentsOfDirectory(atPath: d.path) where f.hasSuffix(".swift") && !f.hasPrefix("L10nStrings") {
                let s = try String(contentsOf: d.appendingPathComponent(f), encoding: .utf8)
                for m in r.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                    if let k = Range(m.range(at: 1), in: s) { used.insert(String(s[k])) }
                }
            }
        }
        try check(used.count > 300, "扫到的 key 太少：\(used.count)")
        for k in used.sorted() { try check(L10n.table[k] != nil, "源码用到但表里没有：\(k)") }
        for v in ["reset", "restore"] {
            for k in ["done", "inMin", "inHours", "inHoursMin", "at"] { try check(L10n.table["quota.\(v).\(k)"] != nil, "quota.\(v).\(k)") }
        }
        for i in 0..<7 { try check(L10n.table["weekday.\(i)"] != nil, "weekday.\(i)") }
    }

    test("l10nDetectFollowsSystemLanguage") {
        try checkEqual(L10n.detect(["zh-Hans-CN", "en-US"]), .zh)
        try checkEqual(L10n.detect(["zh-Hant-TW"]), .zh)
        try checkEqual(L10n.detect(["zh_CN"]), .zh)
        try checkEqual(L10n.detect(["en-US", "zh-Hans"]), .en)
        try checkEqual(L10n.detect(["ja-JP"]), .en)
        try checkEqual(L10n.detect([]), .en)
    }

    test("l10nFillPlaceholdersAndPlurals") {
        try checkEqual(L10n.fill("{0} 分钟前", [5]), "5 分钟前")
        try checkEqual(L10n.fill("{1} before {0}", ["a", "b"]), "b before a")
        try checkEqual(L10n.fill("{0} {0|day|days}", [1]), "1 day")
        try checkEqual(L10n.fill("{0} {0|day|days}", [3]), "3 days")
        try checkEqual(L10n.fill("{0} {0|hour|hours}", ["1"]), "1 hour")
        try checkEqual(L10n.fill("已用 {0}%", [41]), "已用 41%")
        try checkEqual(L10n.fill("{5} 没这个参数", [1]), "{5} 没这个参数")
        try checkEqual(L10n.text("没有这个key", []), "没有这个key")
    }

    test("l10nChineseUnchanged") {
        // 中文就是原来界面上的字
        try checkEqual(StatusPresenter.errorText(.offline, name: "DeepSeek"), "连不上 DeepSeek，检查网络")
        try checkEqual(Runway.durationText(hours: 26), "1 天 2 小时")
        try checkEqual(ProviderRegistry.displayName(.claudePlan), "Claude 套餐")
        try checkEqual(cnCount(306_000_000), "3.06亿")
        try checkEqual(fmtMoney(1234.5, "CNY"), "¥1234.50")
    }

    test("providerLogNamesStayChineseInEnglish") {
        try english {
            try checkEqual(ProviderRegistry.logName(.deepseek), "DeepSeek")
            try checkEqual(ProviderRegistry.logName(.siliconflow), "硅基流动")
            try checkEqual(ProviderRegistry.logName(.claudePlan), "Claude 套餐")
            try checkEqual(ProviderRegistry.logName(.codexPlan), "Codex 套餐")
            try checkEqual(L10n.lang, .en)
            try checkEqual(ProviderRegistry.displayName(.claudePlan), "Claude Plan")
        }
    }

    test("l10nEnglishKeyTexts") {
        try english {
            try checkEqual(ProviderRegistry.displayName(.siliconflow), "SiliconFlow")
            try checkEqual(ProviderRegistry.displayName(.claudePlan), "Claude Plan")
            try checkEqual(StatusPresenter.errorText(.offline, name: "DeepSeek"), "Can't reach DeepSeek — check your network")
            try checkEqual(Runway.durationText(hours: 26), "1 day 2h")
            try checkEqual(Runway.durationText(hours: 120), "5 days")
            try checkEqual(Runway.durationText(hours: 0.5), "30 min")
            try checkEqual(Runway.durationText(hours: 3.5), "3h 30m")
            try checkEqual(L("side.loginExpiresInDays", 1), "Sign-in expires in 1 day")
            try checkEqual(L("side.loginExpiresInDays", 4), "Sign-in expires in 4 days")
            try checkEqual(SettingsPage.alerts.title, "Alerts")
            try checkEqual(SettingsLayout.menuBarModeOptions.map(\.1), ["Balance/usage", "Today's spend", "Icon only"])
            try checkEqual(SettingsLayout.refreshLabel(120), "2 min")
            try checkEqual(OnboardingPlan.removeConfirm([.deepseek, .codexPlan]).title, "Remove DeepSeek, Codex Plan?")
            try checkEqual(QuotaExhausted(clock: "08:00").text, "Next reset: 08:00")
            try checkEqual(QuotaExhausted(clock: nil).menuBarText, "Used up")
            try checkEqual(MenuBarText.title(mode: "balance", isQuota: true, balance: nil, today: nil, quotaUsed: 42,
                                             currency: nil), "42% used")
            try checkEqual(AlertRepeat.label(6), "Every 6 hours")
            try checkEqual(AlertRepeat.label(1), "Every 1 hour")
            try checkEqual(UpdateCheck.menuTitle(UpdateCheck.Release(version: "1.0.1", url: URL(string: "https://example.com")!)),
                           "Version 1.0.1 Available…")
        }
    }

    test("l10nEnglishFormats") {
        try english {
            // 金额照原币种，en_US 千位分组；token 用 K / M / B
            try checkEqual(fmtMoney(1234.5, "CNY"), "¥1,234.50")
            try checkEqual(fmtMoney(27.07, "USD"), "$27.07")
            try checkEqual(fmtCNY(6.27), "¥6.27")
            try checkEqual(cnCount(306_000_000), "306M")
            try checkEqual(cnCount(63_290_808), "63.3M")
            try checkEqual(cnCount(81_200), "81K")
            try checkEqual(cnCount(999), "999")
            try checkEqual(cnCount(1_500_000_000), "1.50B")
            // 日期：「10 月 18 日」→「October 18」；星期 Thu
            try checkEqual(A11yText.spokenDate(iso: "2026-10-18"), "October 18")
            try checkEqual(A11yText.count(123_456), "123.5 thousand")
            let now = Date(timeIntervalSince1970: 1_792_022_400)
            try checkEqual(QuotaText.lastUsed(now.addingTimeInterval(-12 * 60), now: now), "Last used 12 min ago")
            try checkEqual(QuotaText.lastUsed(now.addingTimeInterval(-20), now: now), "Just now")
            try checkEqual(QuotaText.lastUsedShort(now.addingTimeInterval(-86_400), now: now), "1 day ago")
            try checkEqual(QuotaText.resetText(now.addingTimeInterval(133 * 60), now: now, timeZone: TimeZone(secondsFromGMT: 28800)!),
                           "resets in 2h 13m")
            try checkEqual(A11yText.speak("¥12.34 · ≈$1.20"), "12.34 yuan, about 1.20 dollars")
        }
        // 切回中文后照旧
        try checkEqual(A11yText.spokenDate(iso: "2026-10-18"), "10 月 18 日")
    }
}
