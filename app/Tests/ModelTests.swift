import Foundation

@MainActor
func registerModelTests() {
    test("moneyConvertUsdToCny") {
        let m = Money(amount: Decimal(string: "1.20")!, currency: .usd)
        try checkEqual(m.converted(to: .cny, usdToCny: Decimal(string: "7.1")!),
                       Money(amount: Decimal(string: "8.52")!, currency: .cny))
    }
    test("moneyConvertSameCurrencyIsIdentity") {
        let m = Money(amount: 5, currency: .cny)
        try checkEqual(m.converted(to: .cny, usdToCny: 7), m)
    }
}
