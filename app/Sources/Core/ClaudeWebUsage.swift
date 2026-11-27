import Foundation

/// Claude 套餐「登录 claude.ai」来源（用户 11/6 选）：用 App 内网页登录拿到的 claude.ai 登录 Cookie（sessionKey），
/// 问 claude.ai 网页自己用的额度接口。不需要装、也不需要登录 Claude Code；Cookie 存在 TokenBar 自己的钥匙串项里。
/// 接口和字段照开源的 CodexBar（MIT，Sources/CodexBarCore/Providers/Claude/ClaudeWeb/ClaudeWebAPIFetcher.swift）：
/// - GET https://claude.ai/api/organizations → 选带 chat 能力的组织（其次第一个不是只有 api 的，再其次第一个）
/// - GET https://claude.ai/api/organizations/{uuid}/usage?cedar_ember=1 → five_hour / seven_day / …，格式同 claude 命令行
/// 都只带 Cookie 和 Accept 两个请求头。这是 claude.ai 的内部接口，Anthropic 改了要跟着改
enum ClaudeWebUsage {
    static let base = "https://claude.ai/api"
    static let loginURL = URL(string: "https://claude.ai/login")!
    /// 登录 Cookie 的名字和值的前缀（不是这个前缀的不收）
    static let cookieName = "sessionKey"
    static let cookiePrefix = "sk-ant-"
    /// 存进钥匙串时用的键（凭据里 webToken 一项）
    static let credentialKey = "webToken"

    /// 登录窗里取到的 Cookie 中找 claude.ai 的 sessionKey（域名是 claude.ai 或它的子域，值以 sk-ant- 开头）
    static func sessionKey(from cookies: [HTTPCookie]) -> String? {
        cookies.first { c in
            let host = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return c.name == cookieName && (host == "claude.ai" || host.hasSuffix(".claude.ai"))
                && c.value.trimmingCharacters(in: .whitespaces).hasPrefix(cookiePrefix)
        }.map { $0.value.trimmingCharacters(in: .whitespaces) }
    }

    static func headers(_ sessionKey: String) -> [String: String] {
        ["Cookie": "\(cookieName)=\(sessionKey)", "Accept": "application/json"]
    }

    /// 组织列表里选一个：有 chat 能力的；没有就第一个不是「只有 api」的；再没有就第一个。不是数组 / 空数组为 nil
    static func pickOrg(_ data: Data) -> String? { pickOrgEntry(data)?.id }

    /// 选中的组织：uuid 和它的能力列表（套餐名从能力里读）
    static func pickOrgEntry(_ data: Data) -> (id: String, capabilities: [String])? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        func caps(_ o: [String: Any]) -> [String] { (o["capabilities"] as? [String] ?? []).map { $0.lowercased() } }
        let pick = list.first { caps($0).contains("chat") }
            ?? list.first { let c = caps($0); return !(c.count == 1 && c[0] == "api") }
            ?? list.first
        guard let p = pick, let id = p["uuid"] as? String, !id.isEmpty else { return nil }
        return (id, caps(p))
    }

    /// 套餐名（和命令行来源的 subscription_type 一样小写）：能力里有 claude_max → max，claude_pro → pro；看不出为 nil
    static func plan(capabilities: [String]) -> String? {
        let c = Set(capabilities.map { $0.lowercased() })
        if c.contains("claude_max") { return "max" }
        if c.contains("claude_pro") { return "pro" }
        return nil
    }

    /// 200 但不是 JSON（以「<」开头的网页）：Cloudflare 页 = 稍后再试；其余多半是被转到登录页 = 登录过期
    static func htmlError(_ body: Data) -> ProviderError? {
        let head = body.prefix(512).drop { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        guard head.first == UInt8(ascii: "<") else { return nil }
        return isCloudflare(body) ? .unavailable(L("claudeWeb.cloudflare")) : .auth(L("claudeWeb.expired"))
    }

    /// /usage 的回复 → 额度；一个窗口都没有（或不是 JSON）为 nil
    static func parseUsage(_ data: Data, now: Date) -> Quota? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let windows = ClaudeCLIUsage.windows(from: obj, now: now)
        guard !windows.isEmpty else { return nil }
        return Quota(plan: nil, windows: windows, observedAt: now, resetCredits: ClaudeCLIUsage.parseResetCredits(obj["cedar_ember"]))
    }

    /// 被 Cloudflare 拦下的网页（「Just a moment…」）：多半是 VPN / 机房网络，重新登录也没用
    static func isCloudflare(_ body: Data) -> Bool {
        guard let s = String(data: body.prefix(64 * 1024), encoding: .utf8) else { return false }
        return s.localizedCaseInsensitiveContains("Just a moment") || s.localizedCaseInsensitiveContains("cf-chl")
    }

    /// 状态码 → 错误；200 为 nil。401 / 403 = 登录过期（403 且是 Cloudflare 页除外），429 = 查得太勤
    static func error(status: Int, body: Data) -> ProviderError? {
        switch status {
        case 200: return nil
        case 403 where isCloudflare(body): return .unavailable(L("claudeWeb.cloudflare"))
        case 401, 403: return .auth(L("claudeWeb.expired"))
        case 429: return .unavailable(L("claudeWeb.throttled"))
        default: return .network("claude.ai HTTP \(status)")
        }
    }

    /// 取一次：组织列表 → 额度。带 cedar_ember（手动重置次数）被拒时去掉再问一次（同 CodexBar）
    static func fetch(http: HTTPClient, sessionKey: String, now: Date) async -> Result<Quota, ProviderError> {
        let h = headers(sessionKey)
        do {
            let (s1, orgs) = try await http.get(URL(string: "\(base)/organizations")!, headers: h)
            if let e = error(status: s1, body: orgs) ?? htmlError(orgs) { return .failure(e) }
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove("/")
            guard let org = pickOrgEntry(orgs), let id = org.id.addingPercentEncoding(withAllowedCharacters: allowed) else {
                return .failure(.schemaChanged(L("claudeWeb.noOrg")))
            }
            var (s2, body) = try await http.get(URL(string: "\(base)/organizations/\(id)/usage?cedar_ember=1")!, headers: h)
            if ![200, 401, 429].contains(s2), !(s2 == 403 && isCloudflare(body)) {
                (s2, body) = try await http.get(URL(string: "\(base)/organizations/\(id)/usage")!, headers: h)
            }
            if let e = error(status: s2, body: body) ?? htmlError(body) { return .failure(e) }
            guard var q = parseUsage(body, now: now) else { return .failure(.schemaChanged(L("claudeWeb.unrecognized"))) }
            q.plan = plan(capabilities: org.capabilities)
            return .success(q)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}

/// 「用本机 Claude Code 查」添加后的结果页（proposal-claude-source-copy 乙，用户 11/6 选）：按命令行实际情况给说法和按钮，
/// 不再说「打开桌面 App 等 15 分钟」（桌面 App 新版不再写额度记录）
enum ClaudeDesktopResult: Equatable {
    /// 命令行查到了
    case gotCLI
    /// 没装命令行，但桌面 App 的旧记录还有（推算）
    case gotDesktop
    /// 装了命令行但没用 Pro/Max 账号登录：给「打开终端登录」「重新检查」
    case needsLogin
    /// 没装命令行、也没有桌面记录：给安装说明，或建议改用登录 claude.ai
    case notInstalled
    /// 其他失败：写原因，给「重新检查」
    case failed(String)

    static func of(cli: ClaudeCLIUsage.Outcome, desktopHasData: Bool) -> ClaudeDesktopResult {
        if ClaudeCLIUsage.isLoginProblem(cli) { return .needsLogin }
        switch cli {
        case .quota: return .gotCLI
        case .notInstalled: return desktopHasData ? .gotDesktop : .notInstalled
        case .failed, .unrecognized: return .failed(ClaudePlanProvider.cliHint(cli) ?? L("claude.cliError"))
        }
    }
}
