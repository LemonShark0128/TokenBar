import Foundation

// 界面文案里要用、又需要在 Core 里测试的格式化函数

func fmtCNY(_ v: Double?, _ digits: Int = 2) -> String {
    guard let v = v, v.isFinite else { return "¥ —" }
    return "¥" + fixed(v, digits)
}

/// 定点小数：中文界面照旧（不分组，1234.56）；英文界面按 en_US 习惯千位分组（1,234.56）
func fixed(_ v: Double, _ digits: Int) -> String {
    guard !L10n.isZh, abs(v) >= 1000 else { return String(format: "%.\(digits)f", v) }
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US")
    f.numberStyle = .decimal
    f.minimumFractionDigits = digits
    f.maximumFractionDigits = digits
    return f.string(from: NSNumber(value: v)) ?? String(format: "%.\(digits)f", v)
}

/// 币种符号：USD → $，其余 → ¥（nil 视为人民币）
func currencySymbol(_ currency: String?) -> String { currency == "USD" ? "$" : "¥" }

/// 带币种的金额：fmtMoney(1.2, "USD") → $1.20
func fmtMoney(_ v: Double?, _ currency: String?, _ digits: Int = 2) -> String {
    guard let v = v, v.isFinite else { return currencySymbol(currency) + " —" }
    return currencySymbol(currency) + fixed(v, digits)
}

/// 口径（AppData 里的 source，内部值是中文代码，不随界面语言变）→ 显示用的文字
func sourceLabel(_ s: String?) -> String? {
    switch s {
    case nil: return nil
    case "平台账单": return L("source.bill")
    case "只有余额": return L("source.balanceOnly")
    case "离线": return L("source.offline")
    case "无": return L("source.none")
    default: return s
    }
}

/// 口径短标签（costSourceTag 的结果）→ 显示用的文字
func sourceTagLabel(_ tag: String) -> String {
    switch tag {
    case "账单": return L("tag.bill")
    case "余额": return L("tag.balance")
    case "离线": return L("tag.offline")
    case "估算": return L("tag.estimate")
    default: return tag
    }
}

/// 口径短标签：平台账单 → 「账单」，其它 → 「估算」，无 → 「—」。返回的是内部代码（中文），显示时用 sourceTagLabel
func costSourceTag(_ s: String?) -> String {
    guard let s = s, !s.isEmpty else { return "—" }
    if s == "只有余额" { return "余额" }
    if s == "离线" { return "离线" }
    return s.contains("平台") ? "账单" : "估算"
}

/// 中文紧凑计数（状态栏里的 token 用量）：3.06亿 / 8120万 / 306万；英文界面：306M / 81M / 3.1M / 12K
func cnCount(_ v: Int) -> String {
    let d = Double(v)
    if !L10n.isZh {
        if d >= 1_000_000_000 { return String(format: "%.2fB", d / 1_000_000_000) }
        if d >= 100_000_000 { return String(format: "%.0fM", d / 1_000_000) }
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 10_000 { return String(format: "%.0fK", d / 1_000) }
        return "\(v)"
    }
    if d >= 100_000_000 { return String(format: "%.2f亿", d / 100_000_000) }
    if d >= 10_000 { return String(format: "%.0f万", d / 10_000) }
    return "\(v)"
}

/// 菜单栏金额：固定 2 位整数槽位（按 ¥88.88 留宽），不足的在**后面**补 figure space
/// （U+2007，等宽数字下正好一个数字宽）—— 数字贴着图标，空位留在整项末尾。
/// 这样 ¥6.27 和 ¥27.07 一样宽，数值变了、模式换了都不挤动旁边的图标；≥ ¥100 才自然加宽
/// （余额和每日花费平时都在 ¥100 以内；用户嫌 3 位槽位太长）。
func menuBarAmount(_ v: Double?, currency: String? = nil) -> String {
    let sym = currencySymbol(currency)
    guard let v = v, v.isFinite else { return sym + " —\u{2007}\u{2007}" }
    let s = String(format: "%.2f", v)
    let intDigits = s.split(separator: ".").first?.count ?? 1
    return sym + s + String(repeating: "\u{2007}", count: max(0, 2 - intDigits))
}

/// 百分比读数：四舍五入到整数；没有数据为「—%」（菜单栏、面板、读屏共用）
func quotaPercent(_ v: Double?) -> String {
    guard let v = v, v.isFinite else { return "—%" }
    return "\(Int(v.rounded()))%"
}

/// 剩余不夸大，与提醒同口径：夹到 0…100 后向下取整。
func quotaRemainingPercent(_ v: Double?) -> String {
    guard let v = v, v.isFinite else { return "—%" }
    return "\(Int(min(100, max(0, v)).rounded(.down)))%"
}

/// 已用不低估：100 减去向下取整的剩余，与菜单栏读数同口径。
func quotaUsedPercent(remaining: Double?) -> String {
    guard let remaining, remaining.isFinite else { return "—%" }
    return "\(Int(100 - min(100, max(0, remaining)).rounded(.down)))%"
}
