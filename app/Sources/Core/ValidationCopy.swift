import Foundation

/// 登录验证结果 → 给用户看的话（说清楚是哪种问题、怎么办）
enum ValidationCopy {
    /// expiresInDays：登录会话还剩几天（硅基流动成功时附在摘要后面）
    static func message(for r: ValidationResult, provider: ProviderID, expiresInDays: Int? = nil) -> String {
        let name = ProviderRegistry.displayName(provider)
        switch r {
        case .ok(let summary):
            if provider == .siliconflow, let n = expiresInDays { return L("valid.loginExpiresIn", summary, n) }
            return summary
        case .failed(.auth):
            if provider == .siliconflow { return L("valid.sfLoginFailed") }
            return L("valid.keyInvalid")
        case .failed(.network): return L("valid.network", name)
        case .failed(.rateLimited): return L("valid.rateLimited")
        case .failed(.unavailable(let reason)):
            return L("valid.sameAccount", reason)
        case .failed(.schemaChanged): return L("valid.schemaChanged", name)
        case .failed(.badRequest): return L("valid.badRequest")
        }
    }

    /// 登录会话到期时间（Unix 秒字符串）→ 还剩几天；已过期记 0，读不出返回 nil
    static func daysLeft(expiresAt: String?, now: Date) -> Int? {
        guard let raw = expiresAt, let exp = Double(raw) else { return nil }
        return max(0, Int((exp - now.timeIntervalSince1970) / 86400))
    }
}

/// 设置里「重新登录」后的结果，写在该平台的账号行下（之前失败时登录窗一关就没有任何反馈）
struct ReloginNote: Equatable {
    var text: String
    var isError: Bool

    /// message 是 openWebLogin 回调给的话（验证文案或钥匙串错误）
    static func make(provider: ProviderID, ok: Bool, message: String) -> ReloginNote {
        if ok { return ReloginNote(text: message == L("relogin.signedIn") ? L("relogin.done") : L("relogin.doneWith", message), isError: false) }
        // 验证文案本身已说明「登录没有成功」时不再加前缀
        return ReloginNote(text: message.contains(L("relogin.failedMarker")) ? message : L("relogin.failed", message), isError: true)
    }
}
