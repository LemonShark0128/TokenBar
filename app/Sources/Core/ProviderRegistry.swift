import Foundation

/// 平台注册表：界面上显示的平台名都从这里取，不在界面里写死
enum ProviderRegistry {
    /// 所有平台，按界面顺序；主平台回落也按这个顺序找
    static let all: [ProviderID] = [.deepseek, .siliconflow, .kimi, .openrouter, .packyapi, .codexPlan, .claudePlan, .geminiPlan]

    static func makeProvider(_ id: ProviderID, http: HTTPClient, credentials: CredentialStore? = nil,
                             log: @escaping @Sendable (String) -> Void = { _ in }) -> UsageProvider {
        switch id {
        case .deepseek: return DeepSeekProvider(http: http)
        case .siliconflow: return SiliconFlowProvider(http: http)
        case .kimi: return KimiProvider(http: http)
        // 海外服务：走系统代理（没设代理时等于直连），只开了系统代理的用户也连得上
        case .openrouter: return OpenRouterProvider(http: http is URLSessionHTTPClient ? URLSessionHTTPClient(systemProxy: true) : http)
        // 站点在 Cloudflare 后面，用户多半开着代理访问：同样走系统代理
        case .packyapi: return PackyAPIProvider(http: http is URLSessionHTTPClient ? URLSessionHTTPClient(systemProxy: true) : http)
        case .codexPlan: return CodexPlanProvider(root: { AgentDirs.current.codexSessions }, log: log)
        case .claudePlan:
            let installer = ClaudeStatusLineInstaller.standard
            return ClaudePlanProvider(quotaFile: installer.quotaFileURL, desktopFile: ClaudeAppUsageSource.standardURL,
                                      source: { ClaudePlanSource.load(.standard, hookInstalled: { ClaudeStatusLineInstaller.standard.state() == .installed }) },
                                      cli: { await ClaudeCLIUsage.standard(now: $0, log: log) },
                                      loginExpiry: { await ClaudeCLIUsage.loginExpiry(now: $0) },
                                      desktopInstalled: { ClaudeAppUsageSource.isInstalled() },
                                      route: { ClaudeAPIRoute.standard },
                                      // 只在网页来源时读：钥匙串整份已缓存在内存里，不会每次都问
                                      webKey: { credentials?.load(.claudePlan)?.values[ClaudeWebUsage.credentialKey] },
                                      http: URLSessionHTTPClient(cookies: false))
        case .geminiPlan:
            return GeminiPlanProvider(cli: { await GeminiCLIUsage.standard(now: $0, log: log) })
        }
    }

    static func displayName(_ id: ProviderID) -> String {
        switch id {
        case .deepseek: return "DeepSeek"
        case .siliconflow: return L("provider.siliconflow")
        case .kimi: return "Kimi"
        case .openrouter: return "OpenRouter"
        case .packyapi: return "PackyAPI"
        case .codexPlan: return L("provider.codexPlan")
        case .claudePlan: return L("provider.claudePlan")
        case .geminiPlan: return L("provider.geminiPlan")
        }
    }

    /// 日志固定使用中文平台名，复用文案表的中文列。
    static func logName(_ id: ProviderID) -> String {
        switch id {
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi"
        case .openrouter: return "OpenRouter"
        case .packyapi: return "PackyAPI"
        default: return L10n.text("provider.\(id.rawValue)", [], lang: .zh)
        }
    }

    /// 各平台官方控制台的用量页（右键菜单「打开 X 用量页」）
    static func usageURL(_ id: ProviderID) -> URL {
        switch id {
        case .deepseek: return URL(string: "https://platform.deepseek.com/usage")!
        case .siliconflow: return URL(string: "https://cloud.siliconflow.cn/account/expensebill")!
        case .kimi: return URL(string: "https://platform.moonshot.cn/console/account")!
        case .openrouter: return URL(string: "https://openrouter.ai/activity")!
        case .packyapi: return URL(string: "https://www.packyapi.ai/console/usage-detail")!
        case .codexPlan: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .claudePlan: return URL(string: "https://claude.ai/settings/usage")!
        case .geminiPlan: return URL(string: "https://gemini.google.com/usage")!
        }
    }

    /// 平台能力的唯一来源：各 Provider 的 capabilities 和下面几个便捷函数都从这里取（审查 C9：原来两处各写一份）
    static func capabilities(_ id: ProviderID) -> Capabilities {
        switch id {
        case .deepseek, .siliconflow, .packyapi:
            return Capabilities(hasBalance: true, currency: .cny, minPollInterval: 60)
        case .kimi:
            return Capabilities(hasBalance: true, currency: .cny, minPollInterval: 60, estimatesSpendFromBalance: true)
        case .openrouter:
            return Capabilities(hasBalance: true, currency: .usd, minPollInterval: 60, hasTokenDetail: false,
                                billingTimeZone: TimeZone(identifier: "UTC")!)
        case .codexPlan, .claudePlan:
            return Capabilities(hasBalance: false, currency: .cny, minPollInterval: 60, meter: .quota, needsCredentials: false)
        case .geminiPlan:
            return Capabilities(credentialRetryInterval: 300, hasBalance: false, currency: .cny, minPollInterval: 60, meter: .quota, needsCredentials: false)
        }
    }

    /// 主凭据是什么：凭据失效时按它说「API Key 无效 · 更换 API Key」还是「登录已过期 · 重新登录」
    /// （11/6 用户定 round7-scout 第 5 条乙；DeepSeek 的控制台登录是可选的，失效走 consoleLoginNeeded）
    /// accessToken：控制台系统访问令牌 + 用户 ID（PackyAPI），失效时说「访问令牌无效 · 更换访问令牌」
    enum CredentialKind { case apiKey, accessToken, webLogin, none }
    static func credentialKind(_ id: ProviderID) -> CredentialKind {
        switch id {
        case .deepseek, .kimi, .openrouter: return .apiKey
        case .packyapi: return .accessToken
        case .siliconflow: return .webLogin
        case .codexPlan, .claudePlan, .geminiPlan: return .none
        }
    }

    /// 平台的计费币种（界面在没有快照时也要知道）
    static func currency(_ id: ProviderID) -> Currency { capabilities(id).currency }

    /// 有没有账户余额（套餐平台没有，油箱是额度百分比）
    static func hasBalance(_ id: ProviderID) -> Bool { capabilities(id).hasBalance }

    /// 油箱按金额还是套餐额度
    static func meter(_ id: ProviderID) -> Meter { capabilities(id).meter }
}
