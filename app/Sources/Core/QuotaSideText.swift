import Foundation

extension AppData.Side {
    /// 套餐平台的一行（金额字段为空，读数在 quotaRemaining）
    var isQuota: Bool { currency == "PCT" }
    /// 「Codex 套餐 已用 41% · 2:13 后重置」（菜单栏 tooltip、右键卡）
    var quotaLine: String {
        if let e = quotaExhausted { return "\(name) \(e.text)" }      // 用完：「Codex 套餐 下次重置：08:00」
        return ([L("side.quotaUsed", name, quotaUsedPercent(remaining: quotaRemaining))] + [quotaReset].compactMap { $0 }).joined(separator: " · ")
    }
}

