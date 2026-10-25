import Foundation

// 「近 7 天 token」：点昨天或更早的柱子，图例换成那一天各模型的用量和花费
@MainActor
func registerTokenChartDayTests() {
    let isos = ["2026-10-09", "2026-10-10", "2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15"]
    func day(_ iso: String, _ by: [String: Int], cost: [String: Double] = [:]) -> AppData.Day {
        let detail = cost.isEmpty ? nil : Dictionary(uniqueKeysWithValues: by.map { m, t in
            (m, AppData.Day.Detail(tokens: t, costCny: cost[m] ?? 0, cacheHit: 0, cacheMiss: 0, output: 0, hitRate: 0))
        })
        return AppData.Day(date: String(iso.suffix(5)), iso: iso, totalTokens: by.values.reduce(0, +), byModel: by, detail: detail)
    }

    test("chartLegendForPastDay") {
        let main = isos.map { iso -> AppData.Day in
            switch iso {
            case "2026-10-15": return day(iso, ["deepseek-flash": 600])
            case "2026-10-14": return day(iso, ["deepseek-flash": 100, "deepseek-v4-pro": 300],
                                          cost: ["deepseek-flash": 0.12, "deepseek-v4-pro": 1.5])
            default: return day(iso, [:])
            }
        }
        let codex = TokenSource(provider: .codexPlan, byDay: ["2026-10-14": ["gpt-6-astra": 200]])
        let sf = TokenSource(provider: .siliconflow, byDay: ["2026-10-14": ["Qwen/Qwen3-Coder-480B": 50]],
                             costByDay: ["2026-10-14": ["Qwen/Qwen3-Coder-480B": 0.3]], currency: "CNY")
        let c = TokenChart.build(main: .deepseek, mainDays: main, others: [codex, sf], todayISO: "2026-10-15",
                                 mainTodayCost: ["deepseek-flash": 0.8], mainCurrency: "CNY")
        let yesterday = 5
        // 那一天的图例：用量从多到少，0 的不列
        let legend = c.legend(bar: yesterday)
        try checkEqual(legend.map { c.series[$0.series].label },
                       ["DeepSeek · V4 Pro", "Codex · gpt-6-astra", "DeepSeek · Flash", "硅基 · Qwen3-Coder-480B"])
        try checkEqual(legend.map(\.tokens), [300, 200, 100, 50])
        // 花费：主平台取那天明细里的金额，套餐写「套餐」，其他平台取账单
        try checkEqual(legend.map { c.costText(series: $0.series, bar: yesterday) }, ["¥1.50", "套餐", "¥0.12", "¥0.30"])
        // 今天沿用原来的图例和今日花费
        try checkEqual(c.legend(bar: 6), c.todayLegend())
        try checkEqual(c.costText(series: c.todayLegend()[0].series, bar: 6), "¥0.80")
        // 那一天的合计：只写总量，不和平时比
        try checkEqual(c.daySummary(bar: yesterday), TokenChart.TodaySummary(total: "650", change: nil, trend: .none))
        try checkEqual(c.daySummary(bar: 0), nil)
        try checkEqual(c.daySummary(bar: 6), c.todaySummary())
    }

    // 明细里金额是 0 的模型：看不到花费，不写 ¥0.00
    test("chartPastDayZeroCostUnknown") {
        let main = isos.map { iso in
            iso == "2026-10-14" ? day(iso, ["deepseek-flash": 100], cost: ["deepseek-flash": 0]) : day(iso, [:])
        }
        let c = TokenChart.build(main: .deepseek, mainDays: main, others: [], todayISO: "2026-10-15")
        try checkEqual(c.costText(series: c.legend(bar: 5)[0].series, bar: 5), nil)
    }

    // 单平台、那天全是套餐：每行不重复写「套餐」
    test("chartPastDayPlanOnly") {
        let claude = TokenSource(provider: .claudePlan, byDay: ["2026-10-14": ["claude-opus-5-5": 900]])
        let c = TokenChart.build(main: .claudePlan, mainDays: [], others: [claude], todayISO: "2026-10-15")
        try check(c.planOnly(bar: 5))
        try checkEqual(c.costText(series: c.legend(bar: 5)[0].series, bar: 5), nil)
    }
}
