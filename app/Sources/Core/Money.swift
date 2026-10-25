// TokenBarCore：与界面无关的平台对接、数据与计算
import Foundation

enum Currency: String, Codable {
    case cny = "CNY", usd = "USD"
}

/// 金额统一用 Decimal（账单金额不能有浮点误差）
struct Money: Equatable, Codable {
    var amount: Decimal
    var currency: Currency

    /// 换算币种：只支持 USD ↔ CNY，汇率由用户设置
    func converted(to target: Currency, usdToCny: Decimal) -> Money {
        guard target != currency else { return self }
        switch (currency, target) {
        case (.usd, .cny): return Money(amount: amount * usdToCny, currency: .cny)
        case (.cny, .usd): return Money(amount: usdToCny == 0 ? 0 : amount / usdToCny, currency: .usd)
        default: return self
        }
    }
}
