import Foundation

/// 终端版 Claude Code 的请求发去哪：只有直连 Anthropic、用订阅登录时，状态栏和 `claude -p /usage` 才会给套餐额度。
/// 只看 ~/.claude/settings.json 的 env 里有没有这几项、中转地址的主机名；只判断密钥是否存在，不保留、记录或展示密钥值
enum ClaudeAPIRoute: Equatable, Sendable {
    /// 没发现改道：用订阅登录直连
    case subscription
    /// ANTHROPIC_BASE_URL 指向非 Anthropic 的地址（第三方中转），host 是它的主机名
    case relay(host: String)
    /// 直连但按 API 计费（配了 API Key / Auth Token / apiKeyHelper，或走 Bedrock、Vertex、Foundry）
    case apiBilling

    /// 有没有套餐额度可读
    var hasPlanQuota: Bool { self == .subscription }

    /// 卡片上的说明（终端来源等额度时）；订阅直连时为 nil
    var note: String? {
        switch self {
        case .subscription: return nil
        case .relay(let host): return L("claude.relayNote", host)
        case .apiBilling: return L("claude.apiBillingNote")
        }
    }

    /// 桌面来源：为什么不问 claude 命令行（接在桌面记录的说明后面）
    var cliHint: String? {
        switch self {
        case .subscription: return nil
        case .relay(let host): return L("claude.cliRelayHint", host)
        case .apiBilling: return L("claude.cliApiBillingHint")
        }
    }

    static func detect(settings data: Data?) -> ClaudeAPIRoute {
        guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .subscription }
        let env = root["env"] as? [String: Any] ?? [:]
        func value(_ key: String) -> String? {
            guard let s = env[key] as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        func on(_ key: String) -> Bool {
            guard let v = value(key)?.lowercased() else { return false }
            return !["0", "false", "no", "off"].contains(v)
        }
        if let base = value("ANTHROPIC_BASE_URL") {
            let address = base.contains("://") ? base : "https://" + base
            // Never fall back to the raw URL: it may contain credentials or query tokens.
            if var host = URL(string: address)?.host?.lowercased() {
                if host.hasSuffix(".") { host.removeLast() }
                if !host.isEmpty, host != "anthropic.com", !host.hasSuffix(".anthropic.com") {
                    return .relay(host: host)
                }
            }
        }
        if ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"].contains(where: on) { return .apiBilling }
        if value("ANTHROPIC_API_KEY") != nil || value("ANTHROPIC_AUTH_TOKEN") != nil { return .apiBilling }
        if let helper = root["apiKeyHelper"] as? String, !helper.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .apiBilling }
        return .subscription
    }

    /// 读不到文件当作直连（不因为这一步拦住正常取数）
    static func read(_ settingsURL: URL) -> ClaudeAPIRoute {
        detect(settings: try? Data(contentsOf: settingsURL.resolvingSymlinksInPath()))
    }

    static var standard: ClaudeAPIRoute {
        read(AgentDirs.current.claudeConfig.appendingPathComponent("settings.json"))
    }
}
