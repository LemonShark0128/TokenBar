import Foundation

extension AppData.Side {
    /// 套餐平台的一行（金额字段为空，读数在 quotaRemaining）
    var isQuota: Bool { currency == "PCT" }
}

