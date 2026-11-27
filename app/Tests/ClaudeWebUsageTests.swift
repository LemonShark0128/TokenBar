import Foundation

/// Claude 套餐「登录 claude.ai」来源（用户 11/6 选）：用网页登录 Cookie（sessionKey）问 claude.ai 自己的额度接口。
/// 接口和字段照 CodexBar（MIT）的 ClaudeWebAPIFetcher：/api/organizations 选组织，/api/organizations/{id}/usage 读窗口
@MainActor
func registerClaudeWebUsageTests() {
    let now = ISODate.parse("2026-11-06T20:00:00Z")!

    test("claudeWebPicksChatOrg") {
        let orgs = """
        [{"uuid":"api-1","name":"API","capabilities":["api"]},
         {"uuid":"chat-1","name":"Me","capabilities":["chat","claude_max"]}]
        """
        try checkEqual(ClaudeWebUsage.pickOrg(Data(orgs.utf8)), "chat-1")
        // 没有 chat：跳过只有 api 的，取第一个别的
        let noChat = #"[{"uuid":"api-1","capabilities":["api"]},{"uuid":"x-2","capabilities":["foo"]}]"#
        try checkEqual(ClaudeWebUsage.pickOrg(Data(noChat.utf8)), "x-2")
        try checkEqual(ClaudeWebUsage.pickOrg(Data(#"[{"uuid":"only","capabilities":["api"]}]"#.utf8)), "only")
        try checkEqual(ClaudeWebUsage.pickOrg(Data("[]".utf8)), nil)
        try checkEqual(ClaudeWebUsage.pickOrg(Data("<html>".utf8)), nil)
    }

    test("claudeWebParsesUsage") {
        let body = """
        {"five_hour":{"utilization":37.0,"resets_at":"2026-11-06T22:00:00.512345+00:00"},
         "seven_day":{"utilization":61,"resets_at":"2026-11-10T08:00:00+00:00"},
         "seven_day_opus":null,
         "seven_day_sonnet":{"utilization":12.5,"resets_at":"2026-11-10T08:00:00+00:00"},
         "extra_usage":{"is_enabled":false}}
        """
        guard let q = ClaudeWebUsage.parseUsage(Data(body.utf8), now: now) else { throw TestFailure(description: "应解析出额度") }
        try checkEqual(q.windows.map(\.kind), [.session, .weekly, .weeklyModel("Sonnet")])
        try checkEqual(q.windows.map(\.usedPercent), [37, 61, 12.5])
        try checkEqual(q.windows[0].resetsAt.map { Int($0.timeIntervalSince1970) }, Int(ISODate.parse("2026-11-06T22:00:00Z")!.timeIntervalSince1970))
        try checkEqual(q.windows[1].resetsAt, ISODate.parse("2026-11-10T08:00:00Z"))
        try check(q.windows.allSatisfy { !$0.resetIsEstimated }, "重置时间是官方给的，不是推算")
        try checkEqual(q.observedAt, now)
        // 没有任何窗口 / 不是 JSON → nil
        try check(ClaudeWebUsage.parseUsage(Data(#"{"extra_usage":{}}"#.utf8), now: now) == nil)
        try check(ClaudeWebUsage.parseUsage(Data("Just a moment...".utf8), now: now) == nil)
    }

    test("claudeWebClassifiesErrors") {
        try checkEqual(ClaudeWebUsage.error(status: 200, body: Data()), nil)
        guard case .auth? = ClaudeWebUsage.error(status: 401, body: Data()) else { throw TestFailure(description: "401 = 登录过期") }
        guard case .auth? = ClaudeWebUsage.error(status: 403, body: Data(#"{"error":"permission"}"#.utf8)) else {
            throw TestFailure(description: "403 = 登录过期")
        }
        // Cloudflare 拦截：重新登录也没用，不能报成登录过期
        guard case .unavailable(let cf)? = ClaudeWebUsage.error(status: 403, body: Data("<title>Just a moment...</title>".utf8)) else {
            throw TestFailure(description: "Cloudflare 403 不是登录过期")
        }
        try checkEqual(cf, L("claudeWeb.cloudflare"))
        guard case .unavailable(let t)? = ClaudeWebUsage.error(status: 429, body: Data()) else { throw TestFailure(description: "429") }
        try checkEqual(t, L("claudeWeb.throttled"))
        guard case .network? = ClaudeWebUsage.error(status: 500, body: Data()) else { throw TestFailure(description: "500") }
    }

    testAsync("claudeWebFetchSendsCookieAndReadsUsage") {
        let http = HeaderRecordingClient { url in
            if url.path == "/api/organizations" { return (200, #"[{"uuid":"org-9","capabilities":["chat"]}]"#) }
            if url.path == "/api/organizations/org-9/usage" {
                return (200, #"{"five_hour":{"utilization":5,"resets_at":"2026-11-06T22:00:00Z"}}"#)
            }
            return (404, "")
        }
        guard case .success(let q) = await ClaudeWebUsage.fetch(http: http, sessionKey: "sk-ant-sid01-abc", now: now) else {
            throw TestFailure(description: "应取到额度")
        }
        try checkEqual(q.windows.first?.usedPercent, 5)
        try checkEqual(http.urls.map(\.absoluteString),
                       ["https://claude.ai/api/organizations", "https://claude.ai/api/organizations/org-9/usage?cedar_ember=1"])
        try check(http.headers.allSatisfy { $0["Cookie"] == "sessionKey=sk-ant-sid01-abc" }, "每个请求都带登录 Cookie")
    }

    testAsync("claudeWebFetchRetriesWithoutResetsAndStopsOnAuth") {
        // 带 cedar_ember 时报 400：去掉再问一次（CodexBar 同样处理）
        let retry = HeaderRecordingClient { url in
            if url.path == "/api/organizations" { return (200, #"[{"uuid":"o","capabilities":["chat"]}]"#) }
            if url.query == "cedar_ember=1" { return (400, "{}") }
            return (200, #"{"seven_day":{"utilization":40,"resets_at":"2026-11-10T08:00:00Z"}}"#)
        }
        guard case .success(let q) = await ClaudeWebUsage.fetch(http: retry, sessionKey: "sk-ant-x", now: now) else {
            throw TestFailure(description: "去掉 cedar_ember 后应成功")
        }
        try checkEqual(q.windows.map(\.kind), [.weekly])
        try checkEqual(retry.urls.count, 3)
        // 登录过期：组织列表就 401，不再往下问
        let expired = HeaderRecordingClient { _ in (401, "{}") }
        guard case .failure(.auth) = await ClaudeWebUsage.fetch(http: expired, sessionKey: "sk-ant-x", now: now) else {
            throw TestFailure(description: "401 = 登录过期")
        }
        try checkEqual(expired.urls.count, 1)
        // 没有组织
        let none = HeaderRecordingClient { _ in (200, "[]") }
        guard case .failure(.schemaChanged) = await ClaudeWebUsage.fetch(http: none, sessionKey: "sk-ant-x", now: now) else {
            throw TestFailure(description: "没有组织")
        }
    }

    testAsync("claudePlanWebSource") {
        let http = HeaderRecordingClient { url in
            if url.path == "/api/organizations" { return (200, #"[{"uuid":"o","capabilities":["chat"]}]"#) }
            return (200, #"{"five_hour":{"utilization":20,"resets_at":"2026-11-06T22:00:00Z"}}"#)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tb-cw-\(UUID().uuidString).json")
        let loggedIn = ClaudePlanProvider(quotaFile: file, source: { .web }, cli: { _ in throw TestFailure(description: "网页来源不该跑命令行") },
                                          route: { .relay(host: "relay.example") }, webKey: { "sk-ant-ok" }, http: http)
        guard case .success(let s) = await loggedIn.fetch(Credentials(values: [:]), now: now, timeZone: .gmt) else {
            throw TestFailure(description: "已登录应取到额度")
        }
        try checkEqual(s.quota?.windows.first?.usedPercent, 20)
        // 没登录（钥匙串里没有）：报登录问题，提示登录 claude.ai
        let loggedOut = ClaudePlanProvider(quotaFile: file, source: { .web }, webKey: { nil }, http: http)
        guard case .failure(.auth(let why)) = await loggedOut.fetch(Credentials(values: [:]), now: now, timeZone: .gmt) else {
            throw TestFailure(description: "没登录应报登录问题")
        }
        try checkEqual(why, L("claudeWeb.notLoggedIn"))
    }

    test("claudeWebPicksSessionCookie") {
        func cookie(_ name: String, _ value: String, _ domain: String) -> HTTPCookie {
            HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/"])!
        }
        let jar = [cookie("sessionKey", "sk-ant-sid01-good", ".claude.ai"), cookie("other", "x", ".claude.ai")]
        try checkEqual(ClaudeWebUsage.sessionKey(from: jar), "sk-ant-sid01-good")
        // 不是 sk-ant- 开头、别的网站的同名 Cookie、空值：都不收
        try checkEqual(ClaudeWebUsage.sessionKey(from: [cookie("sessionKey", "abc", "claude.ai")]), nil)
        try checkEqual(ClaudeWebUsage.sessionKey(from: [cookie("sessionKey", "sk-ant-x", "evil-claude.ai.com")]), nil)
        try checkEqual(ClaudeWebUsage.sessionKey(from: [cookie("sessionKey", "sk-ant-x", "notclaude.ai")]), nil)
        try checkEqual(ClaudeWebUsage.sessionKey(from: []), nil)
    }

    test("claudeDesktopResultPage") {
        // 「用本机 Claude Code 查」添加后结果页怎么说（proposal-claude-source-copy 乙）
        try checkEqual(ClaudeDesktopResult.of(cli: .quota(Quota(plan: nil, windows: [], observedAt: now)), desktopHasData: false), .gotCLI)
        try checkEqual(ClaudeDesktopResult.of(cli: ClaudeCLIUsage.needsLogin, desktopHasData: false), .needsLogin)
        try checkEqual(ClaudeDesktopResult.of(cli: ClaudeCLIUsage.notPlanLogin, desktopHasData: true), .needsLogin)
        try checkEqual(ClaudeDesktopResult.of(cli: .notInstalled, desktopHasData: true), .gotDesktop)
        try checkEqual(ClaudeDesktopResult.of(cli: .notInstalled, desktopHasData: false), .notInstalled)
        try checkEqual(ClaudeDesktopResult.of(cli: .failed("超时"), desktopHasData: false), .failed(L("claude.cliFailed", "超时")))
        try checkEqual(ClaudeDesktopResult.of(cli: .unrecognized, desktopHasData: false), .failed(L("claude.cliUnrecognized")))
        // 再也不说「打开桌面 App 等 15 分钟」
        for k in ["acct.note.claudeDesktop", "claude.desktopWaitingNote", "ob.claude.srcDesktop", "ob.claude.terminalOnly"] {
            try check(!L(k).contains("15 分钟") && !L(k).contains("不用改任何设置"), k)
        }
    }

    testAsync("removeClaudePlanForgetsWebLogin") {
        let creds = InMemoryCredentialStore()
        try creds.save(Credentials(values: [ClaudeWebUsage.credentialKey: "sk-ant-x"]), for: .claudePlan)
        let d = freshDefaults()
        d.set(true, forKey: UsageStore.addedKey(.claudePlan))
        d.set(true, forKey: UsageStore.credentialsSavedKey(.claudePlan))      // 登录 claude.ai 时 saveCredentials 记下的
        let p = FakeProvider([], id: .claudePlan, hasBalance: false, meter: .quota, needsCredentials: false)
        let store = UsageStore(providers: [p], credentials: creds, samples: try SampleStore(path: ":memory:"),
                               intervalSeconds: 120, defaults: d)
        try await store.removeAccount(.claudePlan)
        try checkEqual(creds.read(.claudePlan), .notFound)
        try check(d.object(forKey: UsageStore.credentialsSavedKey(.claudePlan)) == nil)
    }

    test("claudeWebExpiredAlwaysHasRelogin") {
        // 审核必须改：网页来源登录过期时，行内按钮或「···」菜单里一定要有「重新登录 claude.ai」
        let urgent = SettingsLayout.urgentAction(.claudePlan, state: .invalid, hookGone: false, claudeSource: .web)
        let menu = SettingsLayout.menuActions(.claudePlan, state: .invalid, isMain: true, claudeSource: .web, hookGone: false)
        try check(([urgent].compactMap { $0 } + menu).contains { $0.kind == .webRelogin })
    }

    testAsync("claudeWebHtmlOrgListMeansLoggedOut") {
        // 没登录时 claude.ai 可能回 200 的登录页 HTML：算登录过期（给重新登录），不是「接口变了」
        let html = HeaderRecordingClient { _ in (200, "<!DOCTYPE html><html><body>Log in</body></html>") }
        guard case .failure(.auth) = await ClaudeWebUsage.fetch(http: html, sessionKey: "sk-ant-x", now: now) else {
            throw TestFailure(description: "HTML = 登录过期")
        }
        let cf = HeaderRecordingClient { _ in (200, "<html><title>Just a moment...</title></html>") }
        guard case .failure(.unavailable) = await ClaudeWebUsage.fetch(http: cf, sessionKey: "sk-ant-x", now: now) else {
            throw TestFailure(description: "Cloudflare 页 = 稍后再试")
        }
        let limited = HeaderRecordingClient { _ in (429, "") }
        guard case .failure(.unavailable) = await ClaudeWebUsage.fetch(http: limited, sessionKey: "sk-ant-x", now: now) else {
            throw TestFailure(description: "429")
        }
    }

    testAsync("claudeWebReadsPlanFromOrg") {
        // 套餐名从组织的 capabilities 读（claude_max → max），和命令行来源一样显示「Max」
        let http = HeaderRecordingClient { url in
            if url.path == "/api/organizations" { return (200, #"[{"uuid":"o","capabilities":["chat","claude_max"]}]"#) }
            return (200, #"{"five_hour":{"utilization":1,"resets_at":"2026-11-06T22:00:00Z"}}"#)
        }
        guard case .success(let q) = await ClaudeWebUsage.fetch(http: http, sessionKey: "sk-ant-x", now: now) else {
            throw TestFailure(description: "应成功")
        }
        try checkEqual(q.plan, "max")
        try checkEqual(ClaudeWebUsage.plan(capabilities: ["chat", "claude_pro"]), "pro")
        try checkEqual(ClaudeWebUsage.plan(capabilities: ["chat"]), nil)
    }

    testAsync("removeClaudePlanLeavesKeychainAloneWithoutWebLogin") {
        // 没用过网页登录：移除 Claude 套餐不碰钥匙串（以前就不碰；免得弹授权框）
        let creds = CountingCredentials()
        let d = freshDefaults()
        d.set(true, forKey: UsageStore.addedKey(.claudePlan))
        let p = FakeProvider([], id: .claudePlan, hasBalance: false, meter: .quota, needsCredentials: false)
        let store = UsageStore(providers: [p], credentials: creds, samples: try SampleStore(path: ":memory:"),
                               intervalSeconds: 120, defaults: d)
        try await store.removeAccount(.claudePlan)
        try checkEqual(creds.deletes, 0)
        // 存过网页登录：移除时删掉，并清掉「存过」的标记
        let p2 = FakeProvider([.success(ProviderSnapshot(provider: .claudePlan, balance: nil, today: nil, month: nil, byModel: [],
                                                         trend7: [], source: .quota, fetchedAt: now, credential: .ok))],
                              id: .claudePlan, hasBalance: false, meter: .quota, needsCredentials: false)
        let store2 = UsageStore(providers: [p2], credentials: creds, samples: try SampleStore(path: ":memory:"),
                                intervalSeconds: 120, defaults: d)
        try await store2.saveCredentials([ClaudeWebUsage.credentialKey: "sk-ant-x"], for: .claudePlan)
        try check(store2.isAdded(.claudePlan), "保存后算已添加")
        try checkEqual(p2.calls, 1)
        try await store2.removeAccount(.claudePlan)
        try checkEqual(creds.deletes, 1)
        try await store2.removeAccount(.claudePlan)
        try checkEqual(creds.deletes, 1)
    }

    test("claudeWebSourceActions") {
        // 来源三选一：菜单里给另外两种；网页来源能「重新登录 claude.ai」
        func kinds(_ s: ClaudePlanSource) -> [AccountAction.Kind] {
            SettingsLayout.accountActions(.claudePlan, state: .ok, isMain: true, claudeSource: s).map(\.kind)
        }
        try checkEqual(kinds(.web), [.webRelogin, .switchClaudeSource(.desktop), .switchClaudeSource(.terminal), .dataDir, .remove])
        try checkEqual(kinds(.desktop), [.switchClaudeSource(.web), .switchClaudeSource(.terminal), .dataDir, .remove])
        try checkEqual(kinds(.terminal), [.reinstallHook, .switchClaudeSource(.web), .switchClaudeSource(.desktop), .dataDir, .remove])
        try checkEqual(SettingsLayout.urgentAction(.claudePlan, state: .invalid, hookGone: false, claudeSource: .web)?.kind, .webRelogin)
        try checkEqual(ClaudePlanSource.web.label, L("claude.source.web"))
        try checkEqual(ClaudePlanSource(rawValue: "web"), .web)
    }
}

/// 记下每个请求的地址和请求头
private final class HeaderRecordingClient: HTTPClient, @unchecked Sendable {
    let route: @Sendable (URL) -> (Int, String)
    private(set) var urls: [URL] = []
    private(set) var headers: [[String: String]] = []
    init(route: @escaping @Sendable (URL) -> (Int, String)) { self.route = route }
    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        urls.append(url); self.headers.append(headers)
        let r = route(url)
        return (r.0, Data(r.1.utf8))
    }
}

/// 数删除次数的凭据存储
private final class CountingCredentials: CredentialStore, @unchecked Sendable {
    private let base = InMemoryCredentialStore()
    private(set) var deletes = 0
    func read(_ p: ProviderID) -> CredentialRead { base.read(p) }
    func save(_ c: Credentials, for p: ProviderID) throws { try base.save(c, for: p) }
    func delete(_ p: ProviderID) throws { deletes += 1; try base.delete(p) }
}
