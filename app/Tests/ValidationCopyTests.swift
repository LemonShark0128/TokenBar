import Foundation

@MainActor
func registerValidationCopyTests() {
    test("validationCopy") {
        try checkEqual(ValidationCopy.message(for: .failed(.auth("x")), provider: .deepseek), "密钥无效，请检查后重新粘贴")
        try checkEqual(ValidationCopy.message(for: .failed(.network("x")), provider: .deepseek), "连不上 DeepSeek，检查网络后重试")
        try checkEqual(ValidationCopy.message(for: .failed(.unavailable("控制台里没认出这把 Key")), provider: .deepseek),
                       "控制台里没认出这把 Key，请确认登录的是同一个账号")
        try checkEqual(ValidationCopy.message(for: .ok(summary: "已连接，余额 ¥27.07"), provider: .deepseek), "已连接，余额 ¥27.07")
    }
    test("validationCopyPhase2") {
        try checkEqual(ValidationCopy.message(for: .ok(summary: "已连接，余额 ¥27.07"), provider: .siliconflow, expiresInDays: 14),
                       "已连接，余额 ¥27.07，登录 14 天后过期")
        // 拿不到到期时间：只显示摘要
        try checkEqual(ValidationCopy.message(for: .ok(summary: "已连接，余额 ¥27.07"), provider: .siliconflow),
                       "已连接，余额 ¥27.07")
        // 其它 auth 仍是「密钥无效」；网络错误用平台显示名
        try checkEqual(ValidationCopy.message(for: .failed(.auth("密钥无效")), provider: .deepseek), "密钥无效，请检查后重新粘贴")
        try checkEqual(ValidationCopy.message(for: .failed(.network("x")), provider: .deepseek), "连不上 DeepSeek，检查网络后重试")
    }
    test("validationDaysLeft") {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        try checkEqual(ValidationCopy.daysLeft(expiresAt: "\(1_792_000_000 + 14 * 86400 + 3600)", now: now), 14)
        try checkEqual(ValidationCopy.daysLeft(expiresAt: "\(1_792_000_000 - 10)", now: now), 0)
        try check(ValidationCopy.daysLeft(expiresAt: nil, now: now) == nil)
        try check(ValidationCopy.daysLeft(expiresAt: "abc", now: now) == nil)
    }
}
