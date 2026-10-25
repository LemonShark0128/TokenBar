import Foundation

/// 平台注册表：界面上显示的平台名都从这里取，不在界面里写死
enum ProviderRegistry {
    /// 所有平台，按界面顺序；主平台回落也按这个顺序找
    static let all: [ProviderID] = [.deepseek, .siliconflow, .codexPlan, .claudePlan]

    static func makeProvider(_ id: ProviderID, http: HTTPClient, log: @escaping @Sendable (String) -> Void = { _ in }) -> UsageProvider {
        switch id {
        case .deepseek: return DeepSeekProvider(http: http)
        case .siliconflow: return SiliconFlowProvider(http: http)
        case .codexPlan: return CodexPlanProvider(root: { AgentDirs.current.codexSessions })
        case .claudePlan:
            let installer = ClaudeStatusLineInstaller.standard
            return ClaudePlanProvider(quotaFile: installer.quotaFileURL, desktopFile: ClaudeAppUsageSource.standardURL,
                                      source: { ClaudePlanSource.load(.standard, hookInstalled: { ClaudeStatusLineInstaller.standard.state() == .installed }) },
                                      cli: { await ClaudeCLIUsage.standard(now: $0, log: log) },
                                      desktopInstalled: { ClaudeAppUsageSource.isInstalled() })
        }
    }

    static func displayName(_ id: ProviderID) -> String {
        switch id {
        case .deepseek: return "DeepSeek"
        case .siliconflow: return L("provider.siliconflow")
        case .codexPlan: return L("provider.codexPlan")
        case .claudePlan: return L("provider.claudePlan")
        }
    }

    /// 日志固定使用中文平台名，复用文案表的中文列。
    static func logName(_ id: ProviderID) -> String {
        switch id {
        case .deepseek: return "DeepSeek"
        default: return L10n.text("provider.\(id.rawValue)", [], lang: .zh)
        }
    }

    /// 各平台官方控制台的用量页（右键菜单「打开 X 用量页」）
    static func usageURL(_ id: ProviderID) -> URL {
        switch id {
        case .deepseek: return URL(string: "https://platform.deepseek.com/usage")!
        case .siliconflow: return URL(string: "https://cloud.siliconflow.cn/account/expensebill")!
        case .codexPlan: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .claudePlan: return URL(string: "https://claude.ai/settings/usage")!
        }
    }

    /// 平台的计费币种（界面在没有快照时也要知道）
    static func currency(_ id: ProviderID) -> Currency {
        switch id {
        case .deepseek, .siliconflow, .codexPlan, .claudePlan: return .cny
        }
    }

    /// 有没有账户余额（套餐平台没有，油箱是额度百分比）
    static func hasBalance(_ id: ProviderID) -> Bool { id == .deepseek || id == .siliconflow }

    /// 油箱按金额还是套餐额度
    static func meter(_ id: ProviderID) -> Meter { id == .codexPlan || id == .claudePlan ? .quota : .money }
}
