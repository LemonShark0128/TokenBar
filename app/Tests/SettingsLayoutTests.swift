import Foundation

/// 设置面板：侧栏四页（平台 · 菜单栏与面板 · 提醒 · 通用）的排布、「···」菜单、下拉选中值
@MainActor
func registerSettingsLayoutTests() {
    test("settingsAlertStatusReadingHidesUnavailableAndStaleSnapshots") {
        let readings: [AccountReading] = [.money(25, currency: "USD"), .session(59), .remaining(80)]
        for reading in readings {
            for state: AccountState in [.invalid, .offline, .connecting, .notAdded] {
                try checkEqual(SettingsLayout.alertStatusReading(state: state, reading: reading, stale: false), nil)
            }
            for state: AccountState in [.ok, .balanceOnly, .consoleExpired, .expiring(days: 3)] {
                try checkEqual(SettingsLayout.alertStatusReading(state: state, reading: reading, stale: false), reading)
                try checkEqual(SettingsLayout.alertStatusReading(state: state, reading: reading, stale: true), nil)
                try checkEqual(SettingsLayout.alertStatusReading(state: state, reading: nil, stale: false), nil)
            }
        }
    }
    test("settingsScaleCurrencyRequiresOneKnownCurrency") {
        try checkEqual(SettingsLayout.scaleCurrency([]), nil)
        try checkEqual(SettingsLayout.scaleCurrency([nil, nil]), nil)
        try checkEqual(SettingsLayout.scaleCurrency(["USD"]), "USD")
        try checkEqual(SettingsLayout.scaleCurrency([nil, "USD", "USD"]), "USD")
        try checkEqual(SettingsLayout.scaleCurrency(["CNY", nil, "CNY"]), "CNY")
        try checkEqual(SettingsLayout.scaleCurrency(["USD", "CNY", nil]), nil)
    }
    test("settingsPagesInOrder") {
        // 侧栏四个分类
        try checkEqual(SettingsPage.allCases.map(\.title), ["显示", "提醒", "平台", "通用"])
        try check(SettingsPage.allCases.allSatisfy { !$0.symbol.isEmpty })
    }
    test("settingsAddedPlatformsInUIOrder") {
        let states: [ProviderID: AccountState] = [.claudePlan: .ok, .deepseek: .invalid, .siliconflow: .notAdded]
        try checkEqual(SettingsLayout.added(states), [.deepseek, .claudePlan])
        try checkEqual(SettingsLayout.added([:]), [])
    }
    test("settingsAddPlatformRowOnlyWhenSomethingLeft") {
        try check(SettingsLayout.showsAddPlatform(added: []))
        try check(SettingsLayout.showsAddPlatform(added: [.deepseek, .siliconflow, .codexPlan]))
        try check(!SettingsLayout.showsAddPlatform(added: ProviderRegistry.all))
        try checkEqual(SettingsLayout.addable(added: [.deepseek, .codexPlan]), [.siliconflow, .kimi, .openrouter, .packyapi, .claudePlan, .geminiPlan])
    }
    test("settingsPlatformPageRows") {
        let s = SettingsLayout.sections(.platform, added: [.deepseek, .codexPlan], main: .deepseek, customOpen: [])
        try checkEqual(s.map(\.title), ["已添加的平台"])
        // 未添加的平台不逐个列出，末尾一行「＋ 添加平台」
        try checkEqual(s[0].rows, [.account(.deepseek), .account(.codexPlan), .addPlatform])
        let all = SettingsLayout.sections(.platform, added: ProviderRegistry.all, main: .deepseek, customOpen: [])
        try checkEqual(all[0].rows, ProviderRegistry.all.map { .account($0) })
    }
    test("settingsMenuBarPageRows") {
        let s = SettingsLayout.sections(.display, added: [.deepseek], main: .deepseek, customOpen: [])
        try checkEqual(s, [SettingsSection(title: "正在显示", rows: [.mainPlatform]),
                           SettingsSection(title: "菜单栏", rows: [.menuBarStyle, .menuBarShowRunning]),
                           SettingsSection(title: "面板与窗口", rows: [.panelHome, .theme, .transparency, .widget]),
                           SettingsSection(title: "余额刻度", rows: [.fuelFull])])
    }
    test("settingsMenuBarStylesMigrateToBars") {
        try checkEqual(SettingsLayout.menuBarStyleOptions.map(\.key), ["bars", "classic"])
        for stored in [nil, "bars", "detail", "compact", "unknown"] as [String?] {
            try checkEqual(SettingsLayout.menuBarStyle(stored), "bars")
        }
        try checkEqual(SettingsLayout.menuBarStyle("classic"), "classic")
        try checkEqual(SettingsLayout.menuBarStyleOptions.map(\.label), ["竖条", "经典"])
    }
    test("settingsRunningOnlyInBarsAndDefaultOn") {
        try check(SettingsLayout.menuBarShowRunning(nil))
        try check(!SettingsLayout.menuBarShowRunning(false))
        try check(SettingsLayout.menuBarShowRunning(true))
        let rows = SettingsLayout.sections(.display, added: [], main: nil, customOpen: [], style: "classic")[1].rows
        try checkEqual(rows, [.menuBarStyle, .menuBarMode])
    }
    test("settingsGeneralPageRowsWithoutAdvancedFold") {
        // 原来折叠在「高级」里的直接列出
        let s = SettingsLayout.sections(.general, added: [.deepseek], main: .deepseek, customOpen: [])
        try checkEqual(s, [SettingsSection(title: "本机", rows: [.launchAtLogin, .refreshInterval, .exchangeRate]),
                           SettingsSection(title: "更新与诊断", rows: [.updateCheck, .diagnostics])])
    }
    test("settingsAlertsPerPlatformAndSharedRules") {
        let s = SettingsLayout.sections(.alerts, added: [.claudePlan, .siliconflow, .deepseek, .codexPlan], main: .codexPlan,
                                        customOpen: [.siliconflow, .codexPlan])
        try checkEqual(s.map(\.title), ProviderRegistry.all.filter { ![.kimi, .openrouter, .packyapi, .geminiPlan].contains($0) }.map { ProviderRegistry.displayName($0) } + ["所有平台的提醒规则"])
        try checkEqual(s.map(\.rows), [
            [.alertStatus(.deepseek), .alert(.deepseek), .hourly(.deepseek)],
            [.alertStatus(.siliconflow), .alert(.siliconflow), .alertCustom(.siliconflow), .hourly(.siliconflow)],
            [.alertStatus(.codexPlan), .alert(.codexPlan), .alertCustom(.codexPlan)],
            [.alertStatus(.claudePlan), .alert(.claudePlan)],
            [.alertRepeat, .recoveredAlert, .spikeAlert, .quietHours]])
    }
    test("settingsAlertsSharedRulesForEmptyMoneyAndQuota") {
        for (added, rules): ([ProviderID], [SettingsRowID]) in [
            ([], [.spikeAlert, .quietHours]), ([.deepseek], [.alertRepeat, .spikeAlert, .quietHours]),
            ([.codexPlan], [.alertRepeat, .recoveredAlert, .spikeAlert, .quietHours])] {
            let s = SettingsLayout.sections(.alerts, added: added, main: nil, customOpen: [])
            try checkEqual(s.count, added.count + 1)
            try checkEqual(s.last?.rows, rules)
        }
    }
    test("settingsDisplayScaleDependsOnAddedMoneyNotMain") {
        for added: [ProviderID] in [[], [.codexPlan], [.deepseek, .codexPlan]] {
            let s = SettingsLayout.sections(.display, added: added, main: .codexPlan, customOpen: [])
            try checkEqual(s.first?.rows, [.mainPlatform])
            try checkEqual(s.flatMap(\.rows).contains(.fuelFull), added.contains(.deepseek))
        }
    }
    test("settingsAlertBarFractionClampsAndHandlesMissingReading") {
        try checkEqual(SettingsLayout.alertBarFraction(nil, fuelFull: 100, scale: nil, usdToCny: 7), nil)
        for (reading, full, expected): (AccountReading, Double, Double) in [
            (.money(25, currency: "USD"), 100, 0.25), (.money(-5, currency: nil), 100, 0),
            (.money(120, currency: nil), 100, 1), (.money(0.5, currency: nil), 0, 0.5),
            (.money(0.5, currency: nil), -20, 0.5), (.money(0.25, currency: nil), 0.5, 0.25),
            (.session(59), 20, 0.59),
            (.remaining(80), 20, 0.8), (.session(-1), 100, 0), (.remaining(101), 100, 1)] {
            // 美元那条：刻度也是美元（只加了美元平台）
            var scale: String? = nil
            if case .money(_, "USD") = reading { scale = "USD" }
            try checkEqual(SettingsLayout.alertBarFraction(reading, fuelFull: full, scale: scale, usdToCny: 7), expected)
        }
    }
    test("settingsThemeOrderAndCurrencyScaleOptions") {
        try checkEqual(SettingsLayout.themeOptions.map(\.key), ["system", "light", "dark"])
        try checkEqual(SettingsLayout.fuelFullOptions().map(\.label), ["¥20", "¥50", "¥100", "¥200"])
        try checkEqual(SettingsLayout.fuelFullOptions(symbol: "$").map(\.label), ["$20", "$50", "$100", "$200"])
    }
    test("settingsAccountActionsKeepEveryOldAction") {
        func titles(_ id: ProviderID, _ st: AccountState, main: Bool) -> [String] {
            SettingsLayout.accountActions(id, state: st, isMain: main).map(\.title)
        }
        try checkEqual(titles(.deepseek, .ok, main: true), ["更换 API Key", "重新登录控制台", "移除…"])
        try checkEqual(titles(.deepseek, .invalid, main: false), ["固定显示它", "更换 API Key", "重新登录控制台", "移除…"])
        try checkEqual(titles(.kimi, .invalid, main: true), ["更换 API Key", "移除…"])
        try checkEqual(AccountState.invalid.label(for: .deepseek), "API Key 无效")
        try checkEqual(AccountState.invalid.label(for: .kimi), "API Key 无效")
        try checkEqual(AccountState.invalid.label(for: .siliconflow), "登录已过期")
        try checkEqual(titles(.deepseek, .balanceOnly, main: true), ["更换 API Key", "登录控制台", "移除…"])
        try checkEqual(titles(.deepseek, .consoleExpired, main: true), ["更换 API Key", "重新登录控制台", "移除…"])
        try checkEqual(titles(.siliconflow, .expiring(days: 3), main: false), ["固定显示它", "重新登录", "移除…"])
        try checkEqual(titles(.codexPlan, .ok, main: false), ["固定显示它", "数据目录…", "移除…"])
        try checkEqual(titles(.codexPlan, .ok, main: true), ["数据目录…", "移除…"])
        try checkEqual(titles(.claudePlan, .ok, main: true), ["重装状态栏钩子", "改用登录 claude.ai", "改用本机 Claude Code 查", "数据目录…", "移除…"])
        let last = SettingsLayout.accountActions(.claudePlan, state: .ok, isMain: true).last!
        try check(last.destructive && last.kind == .remove)
    }
    test("settingsMenuBarSelectionFallsBackToFollowMain") {
        try checkEqual(SettingsLayout.mainSelection(auto: true, main: .deepseek, added: [.deepseek]), "auto")
        try checkEqual(SettingsLayout.mainSelection(auto: false, main: .deepseek, added: [.deepseek]), "deepseek")
        try checkEqual(SettingsLayout.mainSelection(auto: false, main: .siliconflow, added: [.deepseek]), "auto")
        try checkEqual(SettingsLayout.mainOptions(added: [.deepseek]).map(\.label), ["当前使用", "固定：DeepSeek"])
    }
    test("settingsAlertOptionsAndSelection") {
        try checkEqual(SettingsLayout.alertOptions(quota: false).map(\.label), ["关闭", "¥5", "¥10", "¥20", "自定义"])
        try checkEqual(SettingsLayout.alertOptions(quota: false, symbol: "$").map(\.label)[1], "$5")
        try checkEqual(SettingsLayout.alertOptions(quota: true).map(\.label), ["关闭", "5%", "10%", "20%", "自定义"])
        try checkEqual(SettingsLayout.alertSelection(value: 0, custom: false), "0")
        try checkEqual(SettingsLayout.alertSelection(value: 10, custom: false), "10")
        try checkEqual(SettingsLayout.alertSelection(value: 10, custom: true), "custom")
        try checkEqual(SettingsLayout.alertSelection(value: 8, custom: false), "custom")
        try checkEqual(SettingsLayout.label(of: "custom", in: SettingsLayout.alertOptions(quota: true)), "自定义")
    }
    test("settingsAccountStateLabels") {
        try checkEqual(AccountState.ok.label, "正常")
        try checkEqual(AccountState.expiring(days: 3).label, "3 天后过期")
        try checkEqual(AccountState.expiring(days: 0).label, "今天内过期")
        try check(AccountState.ok.tone == .good && AccountState.connecting.tone == .neutral && AccountState.invalid.tone == .warn)
    }
    // 评审 Minor 1：选中值不在选项里（旧版存的满盘 30、刷新 90 秒）时显示原值，不能显示成第一项
    test("settingsLabelFallsBackToValue") {
        try checkEqual(SettingsLayout.label(of: "30", in: SettingsLayout.fuelFullOptions(), fallback: "¥30"), "¥30")
        try checkEqual(SettingsLayout.label(of: "90", in: SettingsLayout.refreshOptions), "90")
        try checkEqual(SettingsLayout.label(of: "60", in: SettingsLayout.refreshOptions, fallback: "x"), "1 分钟")
        // 自查第 3 条：各平台最短 60 秒取一次，「30 秒」选了也是 60 秒，不再提供
        try checkEqual(SettingsLayout.refreshOptions.map(\.key), ["60", "120", "300"])
        try checkEqual(SettingsLayout.refreshLabel(90), "90 秒")
        try checkEqual(SettingsLayout.refreshLabel(600), "10 分钟")
    }
    // 评审 Important 3：主平台下拉选中后的写入
    test("settingsMainPickWrites") {
        try checkEqual(SettingsLayout.mainPick("auto", current: .deepseek), .init(pin: nil, auto: true))
        try checkEqual(SettingsLayout.mainPick("siliconflow", current: .deepseek), .init(pin: .siliconflow, auto: false))
        try checkEqual(SettingsLayout.mainPick("deepseek", current: .deepseek), .init(pin: nil, auto: false))
    }
    // 评审 Important 3：预警线下拉与自定义输入的写入
    test("settingsAlertWrites") {
        try checkEqual(SettingsLayout.alertPick("custom"), .custom)
        try checkEqual(SettingsLayout.alertPick("0"), .set(nil))
        try checkEqual(SettingsLayout.alertPick("10"), .set(10))
        // 自定义输入：套餐超过 100 不收；主平台清空不改；其他平台清空 = 关闭
        try checkEqual(SettingsLayout.customAlertInput(150, quota: true, isMain: false), .ignore)
        try checkEqual(SettingsLayout.customAlertInput(80, quota: true, isMain: false), .set(80))
        try checkEqual(SettingsLayout.customAlertInput(nil, quota: false, isMain: true), .ignore)
        try checkEqual(SettingsLayout.customAlertInput(nil, quota: false, isMain: false), .set(nil))
        try checkEqual(SettingsLayout.customAlertInput(150, quota: false, isMain: true), .set(150))
    }
    // 紧急操作只显示当前需要处理的事项，菜单保留其他操作。
    test("settingsUrgentActionMatchesProviderState") {
        let cases: [(ProviderID, AccountState, Bool, AccountAction?)] = [
            (.deepseek, .balanceOnly, false, .init(kind: .console, title: "登录控制台")),
            (.deepseek, .consoleExpired, false, .init(kind: .console, title: "重新登录控制台")),
            (.deepseek, .invalid, false, .init(kind: .apiKey, title: "更换 API Key")),
            (.kimi, .invalid, false, .init(kind: .apiKey, title: "更换 API Key")),
            (.siliconflow, .invalid, false, .init(kind: .webRelogin, title: "重新登录")),
            (.siliconflow, .expiring(days: 0), false, .init(kind: .webRelogin, title: "重新登录")),
            (.siliconflow, .expiring(days: 3), false, .init(kind: .webRelogin, title: "重新登录")),
            (.claudePlan, .ok, true, .init(kind: .reinstallHook, title: "重装状态栏钩子")),
            (.claudePlan, .ok, false, nil), (.deepseek, .ok, true, nil),
            (.siliconflow, .ok, false, nil), (.codexPlan, .invalid, true, nil),
            (.deepseek, .offline, false, nil), (.deepseek, .connecting, false, nil)
        ]
        for (id, state, gone, expected) in cases {
            try checkEqual(SettingsLayout.urgentAction(id, state: state, hookGone: gone, claudeSource: .terminal), expected)
        }
    }
    test("settingsMenuActionsExcludeUrgentAndKeepRemoveLast") {
        let cases: [(ProviderID, AccountState, Bool, [AccountAction.Kind])] = [
            (.deepseek, .invalid, false, [.setMain, .console, .remove]),
            (.deepseek, .balanceOnly, true, [.apiKey, .remove]),
            (.deepseek, .consoleExpired, false, [.setMain, .apiKey, .remove]),
            (.deepseek, .ok, true, [.apiKey, .console, .remove]),
            (.siliconflow, .expiring(days: 3), false, [.setMain, .remove]),
            (.siliconflow, .invalid, true, [.remove]),
            (.siliconflow, .ok, false, [.setMain, .webRelogin, .remove]),
            (.codexPlan, .ok, true, [.dataDir, .remove])
        ]
        for (id, state, main, expected) in cases {
            let actions = SettingsLayout.menuActions(id, state: state, isMain: main, claudeSource: .terminal, hookGone: false)
            try checkEqual(actions.map(\.kind), expected)
            try checkEqual(actions.filter(\.destructive).map(\.title), ["移除…"])
        }
    }
    // 平台行第二行的读数和说明
    test("settingsAccountDetailLine") {
        try checkEqual(SettingsLayout.accountDetail(.deepseek, state: .ok, reading: nil), nil)
        let money = AccountReading.money(23.03, currency: nil)
        try checkEqual(SettingsLayout.accountDetail(.deepseek, state: .ok, reading: money),
                       "余额 ¥23.03")
        try checkEqual(SettingsLayout.accountDetail(.siliconflow, state: .expiring(days: 5),
                                                    reading: .money(9.98, currency: nil)), "余额 ¥9.98")
        try checkEqual(SettingsLayout.accountDetail(.deepseek, state: .ok, reading: .money(2, currency: "USD")),
                       "余额 $2.00")
        try checkEqual(SettingsLayout.accountDetail(.codexPlan, state: .ok, reading: .session(59.4)),
                       "5 小时窗口剩 59% · 读本机使用记录")
        try checkEqual(SettingsLayout.accountDetail(.claudePlan, state: .ok, reading: .remaining(80)), "剩 80% · 来自终端版 Claude Code")
        // 没有读数的 Claude 套餐：等第一次使用
        try checkEqual(SettingsLayout.accountDetail(.claudePlan, state: .connecting, reading: nil),
                       "来自终端版 Claude Code · 等你在终端里用一次")
        // 失效、连不上、正在连接时不写读数（可能是旧数）
        try checkEqual(SettingsLayout.accountDetail(.siliconflow, state: .invalid, reading: .money(1, currency: nil)), nil)
        try checkEqual(SettingsLayout.accountDetail(.deepseek, state: .offline, reading: .money(1, currency: nil)), nil)
        try checkEqual(SettingsLayout.accountDetail(.deepseek, state: .balanceOnly, reading: .money(1, currency: nil)), "余额 ¥1.00")
    }
    test("settingsAccountReadingFromSnapshot") {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var q = Quota(plan: nil, windows: [QuotaWindow(kind: .weekly, usedPercent: 70, resetsAt: nil, windowMinutes: nil),
                                           QuotaWindow(kind: .session, usedPercent: 41, resetsAt: nil, windowMinutes: 300)],
                      observedAt: now)
        try checkEqual(AccountReading.from(balance: nil, quota: q, meter: .quota, now: now), .session(59))
        q.windows.removeLast()
        try checkEqual(AccountReading.from(balance: nil, quota: q, meter: .quota, now: now), .remaining(30))
        try checkEqual(AccountReading.from(balance: nil, quota: q, meter: .quota, now: now)?.text, "剩 30%")
        q.windows.insert(QuotaWindow(kind: .weeklyModel("opus"), usedPercent: 90, resetsAt: nil, windowMinutes: nil), at: 0)
        try checkEqual(AccountReading.from(balance: nil, quota: q, meter: .quota, now: now), .remaining(30))
        try checkEqual(AccountReading.from(balance: Money(amount: 5, currency: .usd), quota: nil, meter: .money, now: now),
                       .money(5, currency: "USD"))
        try checkEqual(AccountReading.from(balance: nil, quota: nil, meter: .money, now: now), nil)
    }
}

/// 说明按选中值写，写的是真实的切换规则
@MainActor
func registerSettingsHelpTests() {
    test("settingsMainHelpFollowsSelection") {
        try checkEqual(SettingsLayout.mainHelp(auto: true, main: .deepseek),
                       "跟着你当前使用的平台走：哪个正在用就显示哪个（Claude / Codex 看有没有任务在跑，按量付费平台看余额是不是在减少），几个同时在用时显示你最常用的那个（近 7 天在本机用得最久的）；都停了就停在最后一个。面板和菜单栏一起变。")
        try checkEqual(SettingsLayout.mainHelp(auto: false, main: .codexPlan), "面板和菜单栏固定显示 Codex 套餐。")
    }
    test("settingsAccountDetailHidesStaleReading") {
        let r = AccountReading.session(59.4)
        // 钩子不在了：读数不再更新，不显示
        try checkEqual(SettingsLayout.accountDetail(.claudePlan, state: .ok, reading: r, stale: true), "来自终端版 Claude Code")
        // 连不上时不写「等你用一次」
        try checkEqual(SettingsLayout.accountDetail(.claudePlan, state: .offline, reading: nil), "来自终端版 Claude Code")
        try checkEqual(SettingsLayout.accountDetail(.claudePlan, state: .ok, reading: nil), "来自终端版 Claude Code · 等你在终端里用一次")
        try checkEqual(SettingsLayout.accountDetail(.claudePlan, state: .ok, reading: r), "5 小时窗口剩 59% · 来自终端版 Claude Code")
    }
}
