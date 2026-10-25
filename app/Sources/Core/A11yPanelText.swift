import Foundation

/// VoiceOver 朗读文案：面板、小组件、右键卡（第 17 条）。界面上的写法（¥、万、「·」）读出来别扭，这里换成说法
extension A11yText {
    /// token 数：不到 1 万照写；万保留 1 位小数，亿保留 2 位，末尾的 0 不读（「12.3 万」「12 万」「1.23 亿」）
    static func count(_ n: Int) -> String {
        let d = Double(n)
        if d < 10_000 { return "\(n)" }
        if !L10n.isZh {
            // 英文：12.3 thousand / 1.23 million / 1.23 billion
            if d < 1_000_000 { return trimmed((d / 100).rounded() / 10, digits: 1) + " thousand" }
            if d < 1_000_000_000 { return trimmed((d / 10_000).rounded() / 100, digits: 2) + " million" }
            return trimmed((d / 10_000_000).rounded() / 100, digits: 2) + " billion"
        }
        let wan = (d / 10_000 * 10).rounded() / 10
        if wan < 10_000 { return trimmed(wan, digits: 1) + " 万" }
        return trimmed((d / 100_000_000 * 100).rounded() / 100, digits: 2) + " 亿"
    }

    /// 金额：「12.35 元」「1.20 美元」；不知道时读「未知」
    static func money(_ v: Double?, currency: String?) -> String {
        guard let v, v.isFinite else { return L("a11y.unknown") }
        return L(currency == "USD" ? "a11y.dollars" : "a11y.yuan", String(format: "%.2f", v))
    }

    /// 剩余百分比：一律向下取整（与界面「已用」的算法一致）；取整后为 0 就是用完
    static func remaining(_ percent: Double?) -> String {
        guard let p = percent, p.isFinite else { return L("a11y.remainingUnknown") }
        if QuotaText.isExhausted(remaining: p) { return L("runway.exhausted") }
        return L("a11y.remaining", Int(min(100, max(0, p)).rounded(.down)))
    }

    /// 把界面上的短写法换成读得顺的说法：¥12.34 → 12.34 元，≈ → 约，12万 → 12 万，「 · 」→「，」，— → 暂无数据。
    /// separators 为 false 时保留「 · 」（模型名里也有，比如「Claude · opus」）
    static func speak(_ text: String, separators: Bool = true) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t == "—" { return L("a11y.noData") }
        if t == "¥ —" || t == "$ —" { return L("a11y.unknown") }
        var s = text.replacingOccurrences(of: "≈", with: L("a11y.approx"))
        s = s.replacingOccurrences(of: "¥ —", with: L("a11y.unknown")).replacingOccurrences(of: "$ —", with: L("a11y.unknown"))
        s = s.replacingOccurrences(of: #"¥\s?([0-9][0-9,]*(\.[0-9]+)?)"#, with: L("a11y.yuan", "$1"), options: .regularExpression)
        s = s.replacingOccurrences(of: #"\$\s?([0-9][0-9,]*(\.[0-9]+)?)"#, with: L("a11y.dollars", "$1"), options: .regularExpression)
        s = s.replacingOccurrences(of: #"([0-9])(万|亿)"#, with: "$1 $2", options: .regularExpression)
        if separators { s = s.replacingOccurrences(of: " · ", with: L("a11y.sep")) }
        return s
    }

    /// 一排数字合成一句：「今日 6.27 元，本月 88.00 元，缓存命中 87.5%」
    static func stats(_ items: [(String, String)]) -> String {
        items.map { "\($0.0) \(speak($0.1))" }.joined(separator: L("a11y.sep"))
    }

    /// 2026-10-18 → 「10 月 18 日」；认不出的原样返回
    static func spokenDate(iso: String) -> String {
        let p = iso.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return iso }
        if L10n.isZh { return L("a11y.monthDay", m, d) }
        guard (1...12).contains(m) else { return iso }
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US")
        return L("a11y.monthDay", cal.monthSymbols[m - 1], d)
    }

    /// 7 天柱状图的一根柱子：「10 月 18 日，12.3 万 token」；有两个以上模型时补上各模型的用量
    static func trendBar(iso: String, total: Int, parts: [(String, Int)], isToday: Bool) -> String {
        let head = (isToday ? L("a11y.todayPrefix") : "") + spokenDate(iso: iso)
        guard total > 0 else { return head + L("a11y.noUsage") }
        let used = parts.filter { $0.1 > 0 }
        let breakdown = used.count >= 2
            ? L("a11y.breakdownColon") + used.map { "\($0.0.replacingOccurrences(of: " · ", with: " ")) \(count($0.1))" }.joined(separator: L("a11y.sep")) : ""
        return head + L("a11y.tokens", count(total)) + breakdown
    }

    /// 柱子能点时的提示：面板里点柱子是在图例里列出那天各模型，离屏 / 旧行为是直接打开那天的详情
    static func trendBarHint(opensDetail: Bool) -> String {
        opensDetail ? L("a11y.hintOpensDetail") : L("a11y.hintListsModels")
    }

    /// 整张 7 天图的概述；7 天都没有用量时说「暂无数据」
    static func trendChart(summary: String, allZero: Bool) -> String {
        guard allZero else { return speak(summary, separators: false) }
        let kind = L10n.isZh ? (summary.split(separator: "。", maxSplits: 1).first.map(String.init) ?? summary)
            : (summary.components(separatedBy: ". ").first ?? summary)
        return kind + L("a11y.chartNoData")
    }

    /// 图下面「今天 12万」那一格
    static func selectedDay(iso: String, total: Int, isToday: Bool) -> String {
        (isToday ? L("a11y.today") : L("a11y.selectedDay", spokenDate(iso: iso))) + (total > 0 ? L("a11y.tokens", count(total)) : L("a11y.noUsage"))
    }

    static func openDayDetail(iso: String) -> String { L("a11y.openDayDetail", spokenDate(iso: iso)) }

    static func todayTokens(_ n: Int) -> String { L("a11y.todayTokens", count(n)) }

    /// 套餐窗口列表的一行：「当前会话，已用 42%，剩余 58%，2 小时 13 分后重置」
    static func quotaWindow(_ r: AppData.QuotaRow) -> String {
        if r.isReset { return L("a11y.windowReset", r.name) }
        let left = 100 - r.usedPercent
        var parts = [r.name]
        if QuotaText.isExhausted(remaining: left) {
            parts.append(L("runway.exhausted"))
        } else {
            parts.append(L("a11y.usedPct", quotaUsedPercent(remaining: left)))
            parts.append(remaining(left))
        }
        if let reset = r.reset { parts.append(reset) }
        return parts.joined(separator: L("a11y.sep"))
    }

    /// 其他平台的一行（面板、右键卡）：名称，中间那句（风险 / 异常 / 重置时间 / 今日花费），右边的读数
    static func side(_ s: AppData.Side) -> String {
        var parts = [s.name]
        if let e = s.quotaExhausted { return (parts + [e.a11y]).joined(separator: L("a11y.sep")) }
        if let risk = s.riskText {
            parts.append(risk)
        } else if s.needsAttention {
            parts.append(s.status)
        } else if s.isQuota {
            if let r = s.quotaReset { parts.append(r) }
        } else if let t = s.todayCost {
            parts.append(L("a11y.todayMoney", money(t, currency: s.currency)))
        }
        if s.isQuota {
            parts.append(s.quotaRemaining == nil ? L("a11y.noData") : L("a11y.usedPct", quotaUsedPercent(remaining: s.quotaRemaining)))
        } else {
            parts.append(L("a11y.balanceMoney", money(s.tank, currency: s.currency)))
        }
        if s.quotaStale { parts.append(L("a11y.notLatest")) }
        return parts.joined(separator: L("a11y.sep"))
    }

    /// 表盘的读数：表盘本身那句 + 下面的续航提示（已经说过的不重复）
    static func gaugeValue(base: String, chipTitle: String?, chipDetail: String?) -> String {
        var parts = [base]
        for t in [chipTitle, chipDetail].compactMap({ $0 }) where !t.isEmpty {
            let said = speak(t)
            if !base.contains(t) && !base.contains(said) { parts.append(said) }
        }
        return parts.joined(separator: L("a11y.sep"))
    }

    /// 冷启动断网：表盘上是最后一次记录的余额
    static func offline(provider: String) -> String { L("a11y.offline", provider) }

    /// 套餐平台还没有额度数据（读不到记录）：「Claude 套餐，暂无数据。<平台给的说明>」
    static func quotaNoData(provider: String, note: String?) -> String {
        L("a11y.quotaNoData", provider) + (note.map { L("a11y.noteSep") + $0 } ?? "")
    }

    /// 末尾的 0 不读：12.0 → 12，1.20 → 1.2
    private static func trimmed(_ v: Double, digits: Int) -> String {
        var s = String(format: "%.\(digits)f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s
    }
}
