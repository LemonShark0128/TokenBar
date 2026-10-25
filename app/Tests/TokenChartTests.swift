import Foundation

// 「近 7 天 token」合并图：主平台 + 其他按量付费平台的 trend7 + 本机 Claude Code / Codex 用量
@MainActor
func registerTokenChartTests() {
    let isos = ["2026-10-09", "2026-10-10", "2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15"]
    @Sendable func day(_ iso: String, _ by: [String: Int], total: Int? = nil) -> AppData.Day {
        AppData.Day(date: String(iso.suffix(5)), iso: iso, totalTokens: total ?? by.values.reduce(0, +), byModel: by, detail: nil)
    }
    func mainDays(_ today: [String: Int], yesterday: [String: Int] = [:]) -> [AppData.Day] {
        isos.map { iso in
            iso == "2026-10-15" ? day(iso, today) : iso == "2026-10-14" ? day(iso, yesterday) : day(iso, [:])
        }
    }

    test("chartSinglePlatformKeepsTotals") {
        // 老用户只有 DeepSeek：总量与原 trend7 一致，没有平台前缀，算单平台
        var days = mainDays(["deepseek-flash": 600, "deepseek-v4-pro": 300], yesterday: ["deepseek-flash": 50])
        days[2] = day(isos[2], [:], total: 70)            // 有总量没有按模型拆分：差额记成平台本身
        let c = TokenChart.build(main: .deepseek, mainDays: days, others: [], todayISO: "2026-10-15")
        try check(!c.multiPlatform)
        try checkEqual(c.bars.map(\.iso), isos)
        try checkEqual(c.bars.map(\.total), [0, 0, 70, 0, 0, 50, 900])
        try checkEqual(c.bars.map(\.date).last, "10-15")
        try checkEqual(c.series.map(\.label), ["Flash", "V4 Pro", "DeepSeek"])
        for b in c.bars { try checkEqual(b.parts.reduce(0, +), b.total) }
    }
    // 评审：主平台近 7 天没用量、只有 Claude Code 有用量时，不能画成像是主平台的单色柱
    test("chartNonMainOnlySourceIsLabeled") {
        let claude = TokenSource(provider: .claudePlan, byDay: ["2026-10-15": ["claude-opus-5-5": 2_000]])
        let c = TokenChart.build(main: .deepseek, mainDays: mainDays([:]), others: [claude], todayISO: "2026-10-15")
        try check(c.multiPlatform, "有主平台以外的来源就要写平台名")
        try checkEqual(c.series.map(\.label), ["Claude · opus-5-5"])
    }
    // 评审：主平台数据停在昨天（离线跨过午夜）时，横轴仍以今天结尾，本机今天的用量不能丢
    test("chartStaleMainAxisEndsToday") {
        let staleIsos = ["2026-10-08"] + isos.dropLast()
        let days = staleIsos.map { day($0, $0 == "2026-10-14" ? ["deepseek-flash": 40] : [:]) }
        let claude = TokenSource(provider: .claudePlan, byDay: ["2026-10-15": ["claude-opus-5-5": 300]])
        let c = TokenChart.build(main: .deepseek, mainDays: days, others: [claude], todayISO: "2026-10-15")
        try checkEqual(c.bars.map(\.iso), isos)
        try checkEqual(c.bars.last?.total, 300)
        try checkEqual(c.bars[5].total, 40)
    }
    test("chartMultiPlatformPrefixesAndTop4") {
        let main = mainDays(["deepseek-flash": 600, "deepseek-v4-pro": 5], yesterday: ["deepseek-flash": 400])
        let sf = TokenSource(provider: .siliconflow, byDay: ["2026-10-15": ["Qwen/Qwen3-Coder-480B": 50, "BAAI/bge-m3": 1]])
        let claude = TokenSource(provider: .claudePlan, byDay: ["2026-10-15": ["claude-opus-5-5": 2_000],
                                                                "2026-10-13": ["claude-haiku-5-20261001": 30]])
        let codex = TokenSource(provider: .codexPlan, byDay: ["2026-10-14": ["gpt-5": 700]])
        let c = TokenChart.build(main: .deepseek, mainDays: main, others: [sf, claude, codex], todayISO: "2026-10-15")
        try check(c.multiPlatform)
        // 7 天总量：Claude opus 2000、DeepSeek flash 1000、Codex 700、硅基 Qwen 50；其余（haiku 30、V4 Pro 5、bge 1）合成「其他」
        try checkEqual(c.series.map(\.label), ["Claude · opus-5-5", "DeepSeek · Flash", "Codex · gpt-5", "硅基 · Qwen3-Coder-480B", "其他"])
        try checkEqual(c.series.map(\.isOther), [false, false, false, false, true])
        try checkEqual(c.bars[6].parts, [2_000, 600, 0, 50, 6])
        try checkEqual(c.bars[4].parts, [0, 0, 0, 0, 30])
        try checkEqual(c.bars[5].total, 1_100)
        // 图例：今天用量最多的模型依次列出，「其他」放最后，0 的不列
        let legend = c.todayLegend()
        try checkEqual(legend.map { c.series[$0.series].label }, ["Claude · opus-5-5", "DeepSeek · Flash", "硅基 · Qwen3-Coder-480B", "其他"])
        try checkEqual(legend.map(\.tokens), [2_000, 600, 50, 6])
    }
    test("chartAxisWithoutMainDays") {
        // 主平台是套餐（没有 trend7）：横轴按今天往前 7 天
        let claude = TokenSource(provider: .claudePlan, byDay: ["2026-10-15": ["claude-opus-5-5": 9], "2026-10-01": ["claude-opus-5-5": 99]])
        let c = TokenChart.build(main: nil, mainDays: [], others: [claude], todayISO: "2026-10-15")
        try checkEqual(c.bars.map(\.iso), isos)
        try checkEqual(c.bars.map(\.total), [0, 0, 0, 0, 0, 0, 9])
        try check(!c.multiPlatform)
        try checkEqual(c.series.map(\.label), ["opus-5-5"])
        // 跨月
        let m = TokenChart.build(main: nil, mainDays: [], others: [], todayISO: "2026-11-02")
        try checkEqual(m.bars.map(\.iso).first, "2026-10-27")
        try check(m.isEmpty)
    }
    test("chartSecondPlatformWithoutUsageStaysSingle") {
        let main = mainDays(["deepseek-flash": 600])
        let idle = TokenSource(provider: .codexPlan, byDay: [:])
        let c = TokenChart.build(main: .deepseek, mainDays: main, others: [idle], todayISO: "2026-10-15")
        try check(!c.multiPlatform)
    }
    test("chartModelShortNames") {
        try checkEqual(TokenChart.shortModel("deepseek-v4-pro", provider: .deepseek), "V4 Pro")
        try checkEqual(TokenChart.shortModel("Qwen/Qwen3-Coder-480B", provider: .siliconflow), "Qwen3-Coder-480B")
        try checkEqual(TokenChart.shortModel("claude-opus-5-5", provider: .claudePlan), "opus-5-5")
        try checkEqual(TokenChart.shortModel("claude-haiku-5-20261001", provider: .claudePlan), "haiku-5")
        try checkEqual(TokenChart.shortModel("gpt-5", provider: .codexPlan), "gpt-5")
        try checkEqual(TokenChart.platformShort(.siliconflow), "硅基")
        try checkEqual(TokenChart.platformShort(.claudePlan), "Claude")
    }
    test("chartA11yDescription") {
        let main = mainDays(["deepseek-flash": 60_000_000])
        let claude = TokenSource(provider: .claudePlan, byDay: ["2026-10-15": ["claude-opus-5-5": 12_340_000]])
        let c = TokenChart.build(main: .deepseek, mainDays: main, others: [claude], todayISO: "2026-10-15")
        try checkEqual(c.a11yLabel(incomplete: false),
                       "近 7 天 token 堆叠柱状图。今天合计 7234万：DeepSeek · Flash 6000万，Claude · opus-5-5 1234万 套餐")
        let single = TokenChart.build(main: .deepseek, mainDays: main, others: [], todayISO: "2026-10-15")
        try checkEqual(single.a11yLabel(incomplete: true), "近 7 天 token 柱状图，数据不完整。今天合计 6000万：Flash 6000万")
        try checkEqual(cnCount(306_000_000), "3.06亿")
    }
    test("mappingBuildsTokenSources") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let tz = TimeZone(secondsFromGMT: 28800)!
        func cny(_ v: String) -> Money { Money(amount: Decimal(string: v)!, currency: .cny) }
        let flash = ModelUsage(model: "deepseek-flash", cacheHit: 1, cacheMiss: 2, output: 3, requests: 1, cost: cny("1"))
        let ds = ProviderSnapshot(provider: .deepseek, balance: cny("9"), today: cny("1"), month: cny("1"), byModel: [flash],
                                  trend7: [DayUsage(day: "2026-10-15", tokens: 6, cost: cny("1"), models: [flash])],
                                  source: .bill, fetchedAt: now, credential: .ok)
        var sfSnap = ds; sfSnap.provider = .siliconflow
        sfSnap.trend7 = [DayUsage(day: "2026-10-14", tokens: 9, cost: nil, models: [])]
        let main = PlatformState(id: .deepseek, snapshot: ds, burn: nil, status: .ok)
        let sf = PlatformState(id: .siliconflow, snapshot: sfSnap, burn: nil, status: .ok)
        let codex = PlatformState(id: .codexPlan, snapshot: nil, burn: nil, status: .ok)
        let claudeGone = PlatformState(id: .claudePlan, snapshot: nil, burn: nil, status: .notAdded)
        let local: [ProviderID: DailyModelTokens] = [.codexPlan: ["2026-10-15": ["gpt-5": 5]],
                                                     .claudePlan: ["2026-10-15": ["claude-opus-5-5": 7]]]
        let d = AppDataMapping.appData(main: main, others: [sf, codex, claudeGone], now: now, timeZone: tz, localUsage: local)
        // 主平台自己的 trend7 不进 tokenSources；没添加的 Claude 套餐不进
        try checkEqual(d.tokenSources, [TokenSource(provider: .siliconflow, byDay: ["2026-10-14": ["": 9]]),
                                        TokenSource(provider: .codexPlan, byDay: ["2026-10-15": ["gpt-5": 5]])])
        let chart = d.tokenChart(main: .deepseek)
        try checkEqual(chart.bars.last?.total, 11)
        // 横轴沿用主平台的 trend7（这里只有今天一天）；不在横轴上的用量不参与排名
        try checkEqual(chart.series.map(\.label), ["DeepSeek · Flash", "Codex · gpt-5"])
        // 套餐平台作主平台：自己的本机用量也进图
        let claudeMain = PlatformState(id: .claudePlan, snapshot: nil, burn: nil, status: .ok)
        let q = AppDataMapping.appData(main: claudeMain, others: [], now: now, timeZone: tz, localUsage: local)
        try checkEqual(q.tokenSources, [TokenSource(provider: .claudePlan, byDay: ["2026-10-15": ["claude-opus-5-5": 7]])])
        try checkEqual(q.tokenChart(main: .claudePlan).bars.last?.total, 7)
        // 旧数据（没有 tokenSources 字段）照常解码
        let enc = try JSONEncoder().encode(d)
        var obj = try JSONSerialization.jsonObject(with: enc) as! [String: Any]
        obj.removeValue(forKey: "tokenSources")
        let back = try JSONDecoder().decode(AppData.self, from: JSONSerialization.data(withJSONObject: obj))
        try check(back.tokenSources.isEmpty)
    }

    // ---------------------------------------------------------------- 图例的今日花费 + 今天合计（方案 A：去掉面板里的模型占比条）
    test("chartLegendCostMainModels") {
        let main = mainDays(["deepseek-flash": 600, "deepseek-v4-pro": 300], yesterday: ["deepseek-flash": 50])
        var days = main
        days[6] = day(isos[6], ["deepseek-flash": 600, "deepseek-v4-pro": 300], total: 950)   // 50 没有按模型拆分
        let c = TokenChart.build(main: .deepseek, mainDays: days, others: [], todayISO: "2026-10-15",
                                 mainTodayCost: ["deepseek-flash": 2.68, "deepseek-v4-pro": 3.59], mainCurrency: "CNY")
        func cost(_ label: String) -> String? { c.costText(series: c.series.firstIndex { $0.label == label }!) }
        try checkEqual(cost("Flash"), "¥2.68")
        try checkEqual(cost("V4 Pro"), "¥3.59")
        try checkEqual(cost("DeepSeek"), nil)          // 没有按模型拆分的那部分：花费看不到就不写
        let usd = TokenChart.build(main: .deepseek, mainDays: main, others: [], todayISO: "2026-10-15",
                                   mainTodayCost: ["deepseek-flash": 1.5], mainCurrency: "USD")
        try checkEqual(usd.costText(series: 0), "$1.50")
        // 没给主平台花费（只有余额）：一律不写，不能写成 ¥0.00
        let none = TokenChart.build(main: .deepseek, mainDays: main, others: [], todayISO: "2026-10-15")
        try checkEqual(none.costText(series: 0), nil)
    }
    test("chartLegendCostPlansAndOthers") {
        let main = mainDays(["deepseek-flash": 600])
        let claude = TokenSource(provider: .claudePlan, byDay: ["2026-10-15": ["claude-opus-5-5": 2_000]])
        let sfCost = TokenSource(provider: .siliconflow, byDay: ["2026-10-15": ["Qwen/Qwen3-Coder-480B": 500]],
                                 costByDay: ["2026-10-15": ["Qwen/Qwen3-Coder-480B": 1.2]], currency: "CNY")
        let sfNoCost = TokenSource(provider: .siliconflow, byDay: ["2026-10-15": ["Qwen/Qwen3-Coder-480B": 500]])
        let c = TokenChart.build(main: .deepseek, mainDays: main, others: [claude, sfCost], todayISO: "2026-10-15",
                                 mainTodayCost: ["deepseek-flash": 2.68], mainCurrency: "CNY")
        func cost(_ c: TokenChart, _ label: String) -> String? { c.costText(series: c.series.firstIndex { $0.label == label }!) }
        try checkEqual(cost(c, "Claude · opus-5-5"), "套餐")
        try checkEqual(cost(c, "DeepSeek · Flash"), "¥2.68")
        try checkEqual(cost(c, "硅基 · Qwen3-Coder-480B"), "¥1.20")
        let n = TokenChart.build(main: .deepseek, mainDays: main, others: [claude, sfNoCost], todayISO: "2026-10-15",
                                 mainTodayCost: ["deepseek-flash": 2.68], mainCurrency: "CNY")
        try checkEqual(cost(n, "硅基 · Qwen3-Coder-480B"), nil)   // 拿不到花费：不写（看不到 ≠ 没花）

        // 「其他」：成员的花费都知道就合计；有一个不知道就不写；全是套餐写「套餐」
        let many = TokenSource(provider: .siliconflow,
                               byDay: ["2026-10-15": ["a/m1": 900, "a/m2": 800, "a/m3": 700, "a/m4": 600, "a/m5": 20, "a/m6": 10]],
                               costByDay: ["2026-10-15": ["a/m1": 1, "a/m2": 1, "a/m3": 1, "a/m4": 1, "a/m5": 0.25, "a/m6": 0.5]],
                               currency: "CNY")
        let o = TokenChart.build(main: nil, mainDays: [], others: [many], todayISO: "2026-10-15")
        try checkEqual(o.series.last?.isOther, true)
        try checkEqual(o.costText(series: o.series.count - 1), "¥0.75")
        var partial = many; partial.costByDay = ["2026-10-15": ["a/m1": 1, "a/m2": 1, "a/m3": 1, "a/m4": 1, "a/m5": 0.25]]
        let p = TokenChart.build(main: nil, mainDays: [], others: [partial], todayISO: "2026-10-15")
        try checkEqual(p.costText(series: p.series.count - 1), nil)
        let plans = TokenSource(provider: .claudePlan,
                                byDay: ["2026-10-15": ["claude-a": 900, "claude-b": 800, "claude-c": 700, "claude-d": 600, "claude-e": 20]])
        let q = TokenChart.build(main: nil, mainDays: [], others: [plans], todayISO: "2026-10-15")
        try checkEqual(q.series.last?.todayCost, .plan)
        try check(q.planOnly, "单平台全是套餐：每行不写，合计行写一次")
    }
    // 评审 M7：「其他」合计按币种代码比较，nil 当 CNY
    test("chartOtherCostCurrencyNilIsCny") {
        let cny = TokenSource(provider: .siliconflow,
                              byDay: ["2026-10-15": ["a/m1": 900, "a/m2": 800, "a/m3": 700, "a/m4": 600, "a/m5": 20]],
                              costByDay: ["2026-10-15": ["a/m1": 1, "a/m2": 1, "a/m3": 1, "a/m4": 1, "a/m5": 0.25]], currency: "CNY")
        let nilCur = TokenSource(provider: .deepseek, byDay: ["2026-10-15": ["deepseek-flash": 10]],
                                 costByDay: ["2026-10-15": ["deepseek-flash": 0.5]], currency: nil)
        let c = TokenChart.build(main: nil, mainDays: [], others: [cny, nilCur], todayISO: "2026-10-15")
        try checkEqual(c.costText(series: c.series.count - 1), "¥0.75")
        let other = TokenSource(provider: .deepseek, byDay: ["2026-10-15": ["deepseek-flash": 10]],
                                costByDay: ["2026-10-15": ["deepseek-flash": 0.5]], currency: "EUR")
        let d = TokenChart.build(main: nil, mainDays: [], others: [cny, other], todayISO: "2026-10-15")
        try checkEqual(d.costText(series: d.series.count - 1), nil)   // 币种不同不合计（符号一样也不行）
    }
    // 评审 M8：单平台全是套餐时，图例每行不重复写「套餐」，只在合计行写一次
    test("chartSinglePlanWritesPlanOnce") {
        let claude = TokenSource(provider: .claudePlan, byDay: ["2026-10-15": ["claude-opus-5-5": 2_000, "claude-haiku-4-5": 500]])
        let c = TokenChart.build(main: .claudePlan, mainDays: [], others: [claude], todayISO: "2026-10-15")
        try check(!c.multiPlatform)
        try checkEqual(c.costText(series: 0), nil)
        try check(c.planOnly, "单平台全是套餐时 planOnly 应为真")
        let multi = TokenChart.build(main: .deepseek, mainDays: mainDays(["deepseek-flash": 600]), others: [claude],
                                     todayISO: "2026-10-15")
        try check(!multi.planOnly)
        try checkEqual(multi.costText(series: multi.series.firstIndex { $0.label == "Claude · opus-5-5" }!), "套餐")
    }
    test("chartTodaySummary") {
        func chart(_ today: Int, prev: [Int]) -> TokenChart {
            let days = zip(isos, prev + [today]).map { day($0.0, ["deepseek-flash": $0.1]) }
            return TokenChart.build(main: .deepseek, mainDays: days, others: [], todayISO: "2026-10-15")
        }
        // 前 6 天日均 1 亿，今天 1.38 亿：涨 38%
        let up = chart(138_000_000, prev: Array(repeating: 100_000_000, count: 6)).todaySummary()
        try checkEqual(up?.total, "1.38亿")
        try checkEqual(up?.change, "比平时多 38%")
        try checkEqual(up?.trend, .up)
        let down = chart(50, prev: Array(repeating: 100, count: 6)).todaySummary()
        try checkEqual(down?.change, "比平时少 50%")
        try checkEqual(down?.trend, .down)
        // 评审 M6：只用有用量的天算日均（没用的天不拉低日均）；术语统一说「平时」（第 4 节）
        let sparse = chart(300, prev: [0, 0, 0, 0, 200, 600]).todaySummary()   // 有用量的 2 天日均 400
        try checkEqual(sparse?.change, "比平时少 25%")
        // 跌幅不会写成 -100%（今天有用量）
        let tiny = chart(1, prev: Array(repeating: 1_000_000, count: 6)).todaySummary()
        try checkEqual(tiny?.change, "比平时少 99%")
        // 近 7 天数据不完整：只写合计，不比较
        let inc = chart(138, prev: Array(repeating: 100, count: 6)).todaySummary(incomplete: true)
        try checkEqual(inc?.total, "138")
        try checkEqual(inc?.change, nil)
        let flat = chart(1_002, prev: Array(repeating: 1_000, count: 6)).todaySummary()  // +0.2% 四舍五入成 0
        try checkEqual(flat?.change, "和平时持平")
        try checkEqual(flat?.trend, .flat)
        let fresh = chart(500, prev: Array(repeating: 0, count: 6)).todaySummary()
        try checkEqual(fresh?.total, "500")
        try checkEqual(fresh?.change, nil)                                        // 前 6 天没用量：只写合计
        try checkEqual(fresh?.trend, TokenChart.TodaySummary.Trend.none)
        try check(chart(0, prev: Array(repeating: 1_000, count: 6)).todaySummary() == nil, "今天没有用量不显示合计行")
    }
    test("chartA11yIncludesCostAndChange") {
        let days = zip(isos, [10_000_000, 10_000_000, 10_000_000, 10_000_000, 10_000_000, 10_000_000, 60_000_000]).map { day($0.0, ["deepseek-flash": $0.1]) }
        let claude = TokenSource(provider: .claudePlan, byDay: ["2026-10-15": ["claude-opus-5-5": 12_340_000]])
        let c = TokenChart.build(main: .deepseek, mainDays: days, others: [claude], todayISO: "2026-10-15",
                                 mainTodayCost: ["deepseek-flash": 2.68], mainCurrency: "CNY")
        // 前 6 天日均 1000 万，今天 7234 万：+623%
        try checkEqual(c.a11yLabel(incomplete: false),
                       "近 7 天 token 堆叠柱状图。今天合计 7234万，比平时多 623%：DeepSeek · Flash 6000万 花费 ¥2.68，Claude · opus-5-5 1234万 套餐")
    }
    test("mappingTokenSourcesCarryTodayCost") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let tz = TimeZone(secondsFromGMT: 28800)!
        func cny(_ v: String) -> Money { Money(amount: Decimal(string: v)!, currency: .cny) }
        let flash = ModelUsage(model: "deepseek-flash", cacheHit: 1, cacheMiss: 2, output: 3, requests: 1, cost: cny("1"))
        let ds = ProviderSnapshot(provider: .deepseek, balance: cny("9"), today: cny("1"), month: cny("1"), byModel: [flash],
                                  trend7: [DayUsage(day: "2026-10-15", tokens: 6, cost: cny("1"), models: [flash])],
                                  source: .bill, fetchedAt: now, credential: .ok)
        let qwen = ModelUsage(model: "Qwen/Qwen3", cacheHit: 0, cacheMiss: 9, output: 1, requests: 1, cost: cny("1.2"))
        let bge = ModelUsage(model: "BAAI/bge-m3", cacheHit: 0, cacheMiss: 5, output: 0, requests: 1, cost: nil)
        var sfSnap = ds; sfSnap.provider = .siliconflow
        sfSnap.trend7 = [DayUsage(day: "2026-10-15", tokens: 15, cost: cny("1.2"), models: [qwen, bge]),
                         DayUsage(day: "2026-10-14", tokens: 9, cost: cny("0.3"), models: [])]
        let main = PlatformState(id: .deepseek, snapshot: ds, burn: nil, status: .ok)
        let sf = PlatformState(id: .siliconflow, snapshot: sfSnap, burn: nil, status: .ok)
        let d = AppDataMapping.appData(main: main, others: [sf], now: now, timeZone: tz)
        // 有花费的模型带上；花费为 nil 的模型不带（不能当成 0）；当天没拆分模型时整天的花费记在空串上
        try checkEqual(d.tokenSources.first?.costByDay,
                       ["2026-10-15": ["Qwen/Qwen3": 1.2], "2026-10-14": ["": 0.3]])
        try checkEqual(d.tokenSources.first?.currency, "CNY")
        let chart = d.tokenChart(main: .deepseek)
        func cost(_ label: String) -> String? { chart.series.firstIndex { $0.label == label }.flatMap { chart.costText(series: $0) } }
        try checkEqual(cost("DeepSeek · Flash"), "¥1.00")     // 主平台的花费取 d.models
        try checkEqual(cost("硅基 · Qwen3"), "¥1.20")
        try checkEqual(cost("硅基 · bge-m3"), nil)
    }
}
