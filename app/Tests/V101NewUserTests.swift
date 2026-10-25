import Foundation

@MainActor
func registerV101NewUserTests() {
    func temporary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb new user \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    test("agentDirsResolvePriorityAndExpansion") {
        let home = URL(fileURLWithPath: "/tmp/test home")
        let defaults = AgentDirs.resolve(custom: [:], env: [:], home: home)
        try checkEqual(defaults.codexHome.path, home.appendingPathComponent(".codex").path)
        try checkEqual(defaults.claudeConfig.path, home.appendingPathComponent(".claude").path)
        let env = ["CODEX_HOME": "~/env codex", "CLAUDE_CONFIG_DIR": "~/env claude"]
        let environment = AgentDirs.resolve(custom: [.codex: "", .claude: "  "], env: env, home: home)
        try checkEqual(environment.codexHome.path, home.appendingPathComponent("env codex").path)
        try checkEqual(environment.claudeConfig.path, home.appendingPathComponent("env claude").path)
        let custom = AgentDirs.resolve(custom: [.codex: "~/custom codex", .claude: "~/custom claude"], env: env, home: home)
        try checkEqual(custom.codexSessions.path, home.appendingPathComponent("custom codex/sessions").path)
        try checkEqual(custom.claudeConfig.path, home.appendingPathComponent("custom claude").path)
        try checkEqual(AgentDirs.resolve(custom: [:], env: ["CODEX_HOME": "", "CLAUDE_CONFIG_DIR": " "], home: home), defaults)
        try checkEqual(AgentDirs.resolve(custom: [.codex: "~"], env: [:], home: home).codexHome.path, home.path)
    }
    test("agentDirsPersistResetAndDisplay") {
        let suite = "tb new user \(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let dir = URL(fileURLWithPath: "/tmp/test home/custom data")
        AgentDirs.setCustom(.codex, dir, d)
        try checkEqual(d.string(forKey: "agentDir.codex"), dir.path)
        try checkEqual(AgentDirs.custom(d)[.codex], dir.path)
        AgentDirs.setCustom(.codex, nil, d)
        try checkEqual(AgentDirs.custom(d)[.codex], nil)
        let home = URL(fileURLWithPath: "/tmp/test home")
        try checkEqual(AgentDirs.displayPath(dir, home: home), "~/custom data")
        try checkEqual(AgentDirs.displayPath(home, home: home), "~")
        try checkEqual(AgentDirs.displayPath(URL(fileURLWithPath: "/tmp/test home-other"), home: home), "/tmp/test home-other")
    }
    test("agentDirsValidateFolders") {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        try checkEqual(AgentDirs.validate(.codex, dir), L("agentDir.invalidCodex"))
        try checkEqual(AgentDirs.validate(.claude, dir), L("agentDir.invalidClaude"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try checkEqual(AgentDirs.validate(.codex, dir), nil)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try checkEqual(AgentDirs.validate(.claude, dir), nil)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("projects"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("settings.json"))
        try checkEqual(AgentDirs.validate(.claude, dir), nil)
        try check(AgentDirs.validate(.claude, dir.appendingPathComponent("settings.json")) != nil, "must choose a directory")
    }
    test("claudeChildEnvironmentCustomOnly") {
        let base = ["CLAUDE_CONFIG_DIR": "/inherited", "OTHER": "value"]
        try checkEqual(ClaudeCLIUsage.childEnvironment(base: base, customClaudeDir: nil), base)
        try checkEqual(ClaudeCLIUsage.childEnvironment(base: base, customClaudeDir: ""), base)
        try checkEqual(ClaudeCLIUsage.childEnvironment(base: base, customClaudeDir: "/custom dir"), ["CLAUDE_CONFIG_DIR": "/custom dir", "OTHER": "value"])
        let home = URL(fileURLWithPath: "/tmp/test home")
        let candidates = ClaudeCLIUsage.candidates(home: home, claudeConfig: home.appendingPathComponent("custom claude"))
        try check(candidates.contains(home.appendingPathComponent("custom claude/local/claude")), "custom executable candidate")
        let standard = ClaudeCLIUsage.candidates(home: home, claudeConfig: home.appendingPathComponent(".claude"))
        try checkEqual(Set(standard).count, standard.count)
    }
    test("agentDirAccountMenuOrderAndDetail") {
        for id: ProviderID in [.codexPlan, .claudePlan] {
            let ordinary = SettingsLayout.accountActions(id, state: .ok, isMain: true)
            try checkEqual(Array(ordinary.suffix(2).map(\.kind)), [.dataDir, .remove])
            let custom = SettingsLayout.accountActions(id, state: .ok, isMain: true, customDir: true)
            try checkEqual(Array(custom.suffix(3).map(\.kind)), [.dataDir, .resetDataDir, .remove])
            let menu = SettingsLayout.menuActions(id, state: .ok, isMain: true, claudeSource: .terminal, hookGone: false, customDir: true)
            try checkEqual(menu, custom)
            let detail = SettingsLayout.accountDetail(id, state: .ok, reading: nil, customDir: "~/custom data")
            try check(detail?.hasSuffix("数据目录 ~/custom data") == true, "directory appended")
        }
        try check(!SettingsLayout.accountActions(.deepseek, state: .ok, isMain: true, customDir: true).contains { $0.kind == .dataDir }, "only plan platforms")
    }
    testAsync("codexRootClosureReadsNewDirectoryEachFetch") {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        final class Root: @unchecked Sendable { var url: URL; init(_ url: URL) { self.url = url } }
        let root = Root(dir.appendingPathComponent("missing"))
        let provider = CodexPlanProvider(root: { root.url })
        let now = Date()
        let first = await provider.fetch(Credentials(values: [:]), now: now, timeZone: .current)
        guard case .success(let empty) = first else { throw TestFailure(description: "expected empty") }
        try checkEqual(empty.quota, nil)
        let day = dir.appendingPathComponent("sessions/2026/10/25")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data(#"{"payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":37,"window_minutes":300}}}}"#.utf8).write(to: day.appendingPathComponent("minimal.jsonl"))
        root.url = dir.appendingPathComponent("sessions")
        guard case .success(let snapshot) = await provider.fetch(Credentials(values: [:]), now: now, timeZone: .current) else { throw TestFailure(description: "expected quota") }
        try checkEqual(snapshot.quota?.windows.first?.usedPercent, 37)
    }
    test("claudeDesktopInstallDetection") {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let support = dir.appendingPathComponent("Application Support/Claude")
        let app = dir.appendingPathComponent("Applications/Claude.app")
        try check(!ClaudeAppUsageSource.isInstalled(supportDir: support, appPaths: [app]), "nothing installed")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try check(ClaudeAppUsageSource.isInstalled(supportDir: support, appPaths: [app]), "support folder")
        try FileManager.default.removeItem(at: support)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try check(ClaudeAppUsageSource.isInstalled(supportDir: support, appPaths: [app]), "app bundle")
    }
    testAsync("claudeDesktopMissingVersusNotInstalled") {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        for installed in [false, true] {
            let provider = ClaudePlanProvider(quotaFile: dir.appendingPathComponent("hook.json"), desktopFile: dir.appendingPathComponent("missing.json"), source: { .desktop }, desktopInstalled: { installed })
            guard case .success(let s) = await provider.fetch(Credentials(values: [:]), now: Date(), timeZone: .current) else { throw TestFailure(description: "expected note") }
            let expected = installed ? ClaudePlanProvider.desktopWaitingNote + L("common.sentenceSep") + ClaudePlanProvider.cliMissingHint : L("claude.nothingInstalled")
            try checkEqual(s.quotaNote, expected)
        }
        let file = dir.appendingPathComponent("empty.json")
        try Data(#"{"version":1,"samples":[]}"#.utf8).write(to: file)
        let provider = ClaudePlanProvider(quotaFile: dir.appendingPathComponent("hook.json"), desktopFile: file, source: { .desktop }, desktopInstalled: { false })
        guard case .success(let s) = await provider.fetch(Credentials(values: [:]), now: Date(), timeZone: .current) else { throw TestFailure(description: "expected waiting") }
        try checkEqual(s.quotaNote, ClaudePlanProvider.desktopWaitingNote + L("common.sentenceSep") + ClaudePlanProvider.cliMissingHint)
    }
    test("webLoadFailureIgnoresNavigationInterruptionsOnly") {
        for (domain, code) in [(NSURLErrorDomain, -999), ("WebKitErrorDomain", 102), ("WebKitErrorDomain", 204)] {
            try check(WebLoadFailure.shouldIgnore(domain: domain, code: code), "ignored interruption")
        }
        try check(!WebLoadFailure.shouldIgnore(domain: "other", code: -999), "domain matters")
        try check(!WebLoadFailure.shouldIgnore(domain: NSURLErrorDomain, code: -1001), "timeout visible")
    }
    test("webLoadFailureClassifiesAllReasons") {
        for (codes, reason) in [([-1009, -1005], "没有网络连接"), ([-1001], "连接超时"), ([-1003, -1004, -1006], "连不上 example.com，检查网络或代理"), (Array(-1206 ... -1200), "安全连接失败，检查代理或系统时间"), ([-1020], "当前网络不允许连接（数据漫游等）")] {
            for code in codes { try checkEqual(WebLoadFailure.message(domain: NSURLErrorDomain, code: code, host: "example.com"), "登录页没打开：" + reason) }
        }
        try checkEqual(WebLoadFailure.message(domain: "other", code: -1001, host: nil), "登录页没打开：页面加载失败（错误码 -1001）")
        try checkEqual(WebLoadFailure.message(domain: NSURLErrorDomain, code: -77, host: nil), "登录页没打开：页面加载失败（错误码 -77）")
        try check(!WebLoadFailure.message(domain: NSURLErrorDomain, code: -1003, host: nil).contains("nil"), "fallback host")
    }
    test("agentDirsDefaultPathIsNotCustom") {
        // 选回默认位置不算自定义：否则会给 claude 传 CLAUDE_CONFIG_DIR，它就找不到登录（10-25 实机）
        let suite = "tb new user \(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let home = URL(fileURLWithPath: "/tmp/test home")
        for stored in ["/tmp/test home/.claude", "/tmp/test home/.claude/", "~/.claude"] {
            d.set(stored, forKey: "agentDir.claude")
            try checkEqual(AgentDirs.custom(d, home: home)[.claude], nil)
        }
        d.set("/tmp/test home/.codex", forKey: "agentDir.codex")
        try checkEqual(AgentDirs.custom(d, home: home)[.codex], nil)
        AgentDirs.setCustom(.codex, home.appendingPathComponent(".codex"), d, home: home)
        try checkEqual(d.string(forKey: "agentDir.codex"), nil)
        AgentDirs.setCustom(.claude, home.appendingPathComponent("other"), d, home: home)
        try checkEqual(AgentDirs.custom(d, home: home)[.claude], "/tmp/test home/other")
    }
    test("installerFirstBackupIsNotAWriteFailure") {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = dir.appendingPathComponent("claude dir")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try "{}".write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        let saved = WriteFailureLog.shared
        WriteFailureLog.shared = WriteFailureLog(sink: { lines.all.append($0) })
        defer { WriteFailureLog.shared = saved }
        let inst = ClaudeStatusLineInstaller(settingsURL: claude.appendingPathComponent("settings.json"),
                                             supportDir: dir.appendingPathComponent("support dir"), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        _ = try inst.install()
        try checkEqual(lines.all, [])
        try checkEqual(WriteFailureLog.shared.recent().count, 0)
    }
}
