import Foundation

@MainActor
func registerClaudeStatusLineInstallerTests() {
    struct Env {
        let root: URL
        let claudeDir: URL
        let settings: URL
        let support: URL
        let installer: ClaudeStatusLineInstaller
    }
    let fixedNow = Date(timeIntervalSince1970: 1_792_022_400)

    /// 每个用例单独的临时目录，名字里带空格
    func makeEnv(settings content: String?, createClaudeDir: Bool = true) throws -> Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tb hook \(UUID().uuidString)")
        let claude = root.appendingPathComponent(".claude")
        let support = root.appendingPathComponent("Application Support/TokenBar")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if createClaudeDir { try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true) }
        let s = claude.appendingPathComponent("settings.json")
        if let content { try content.write(to: s, atomically: true, encoding: .utf8) }
        let inst = ClaudeStatusLineInstaller(settingsURL: s, supportDir: support, now: { fixedNow })
        return Env(root: root, claudeDir: claude, settings: s, support: support, installer: inst)
    }
    func json(_ url: URL) throws -> [String: Any] {
        let d = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
    }
    func command(_ url: URL) throws -> String? {
        (try json(url)["statusLine"] as? [String: Any])?["command"] as? String
    }
    func backups(_ env: Env) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: env.claudeDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("settings.json.tokenbar-backup-") }
    }
    func same(_ a: Any, _ b: Any) -> Bool { (a as AnyObject).isEqual(b) }

    test("installWithoutStatusLine") {
        let original = "{\"model\":\"opus\"}"
        let e = try makeEnv(settings: original)
        let r = try e.installer.install()
        guard case .installed(let backup?) = r else { throw TestFailure(description: "期望 installed(backup:)，实际 \(r)") }
        try checkEqual(try command(e.settings), ClaudeStatusLineInstaller.shellQuote(e.installer.hookURL.path))
        try checkEqual(try json(e.settings)["model"] as? String, "opus")
        try checkEqual(try Data(contentsOf: backup), Data(original.utf8))
        try check(backup.lastPathComponent.hasPrefix("settings.json.tokenbar-backup-"), "备份文件名")
        let orig = try json(e.installer.originalURL)
        try check(orig["statusLine"] is NSNull, "original 应记 null")
        try check(FileManager.default.isExecutableFile(atPath: e.installer.hookURL.path), "hook 应可执行")
        try checkEqual(e.installer.state(), .installed)
    }

    test("installWrapsExistingStatusLine") {
        let e = try makeEnv(settings: "{\"statusLine\":{\"type\":\"command\",\"command\":\"~/bin/sl.sh\",\"padding\":0}}")
        _ = try e.installer.install()
        let sl = try json(e.installer.originalURL)["statusLine"] as? [String: Any]
        try checkEqual(sl?["command"] as? String, "~/bin/sl.sh")
        try checkEqual(sl?["padding"] as? Int, 0)
        try checkEqual(sl?["type"] as? String, "command")
    }

    test("installLeavesUnparseableFileUntouched") {
        let bad = "{ // 注释\n \"a\": 1, }"
        let e = try makeEnv(settings: bad)
        let r = try e.installer.install()
        guard case .unparseable(let snippet) = r else { throw TestFailure(description: "期望 unparseable，实际 \(r)") }
        try check(snippet.contains(e.installer.hookURL.path), "snippet 应含 hook 路径")
        try checkEqual(try Data(contentsOf: e.settings), Data(bad.utf8))
        try checkEqual(try backups(e).count, 0)
        // 用户手动粘贴片段后钩子要能跑：脚本照写（可执行），settings.json、备份、original 都不碰
        try check(FileManager.default.isExecutableFile(atPath: e.installer.hookURL.path), "应生成可执行的 hook")
        try check(!FileManager.default.fileExists(atPath: e.installer.originalURL.path), "不应生成 original")
    }

    test("installTwiceIsNoop") {
        let e = try makeEnv(settings: "{\"model\":\"opus\"}")
        _ = try e.installer.install()
        let r2 = try e.installer.install()
        try checkEqual(r2, .alreadyInstalled)
        try checkEqual(try backups(e).count, 1)
        try check(try json(e.installer.originalURL)["statusLine"] is NSNull, "original 仍是第一次安装前的值")
    }

    test("installCreatesClaudeDir") {
        let e = try makeEnv(settings: nil, createClaudeDir: false)
        let r = try e.installer.install()
        try checkEqual(r, .installed(backup: nil))
        try checkEqual(try command(e.settings), ClaudeStatusLineInstaller.shellQuote(e.installer.hookURL.path))
    }

    test("restoreRestoresOriginal") {
        let original = "{\"model\":\"opus\",\"statusLine\":{\"type\":\"command\",\"command\":\"~/bin/sl.sh\"}}"
        let e = try makeEnv(settings: original)
        _ = try e.installer.install()
        try "{}".write(to: e.installer.quotaFileURL, atomically: true, encoding: .utf8)
        try checkEqual(try e.installer.restore(), .restored)
        let a = try JSONSerialization.jsonObject(with: Data(original.utf8))
        let b = try JSONSerialization.jsonObject(with: Data(contentsOf: e.settings))
        try check(same(a, b), "还原后应与原文件语义相等")
        try check(!FileManager.default.fileExists(atPath: e.installer.originalURL.path), "original 应删除")
        try check(!FileManager.default.fileExists(atPath: e.installer.quotaFileURL.path), "额度文件应删除")

        let e2 = try makeEnv(settings: "{\"model\":\"opus\"}")
        _ = try e2.installer.install()
        try checkEqual(try e2.installer.restore(), .restored)
        let after = try json(e2.settings)
        try check(after["statusLine"] == nil, "原来没有 statusLine，还原后也不应有")
        try checkEqual(after["model"] as? String, "opus")
    }

    test("restoreSkipsWhenUserChanged") {
        let e = try makeEnv(settings: "{\"model\":\"opus\"}")
        try checkEqual(e.installer.state(), .notInstalled)
        try checkEqual(try e.installer.restore(), .notInstalled)
        _ = try e.installer.install()
        try checkEqual(e.installer.state(), .installed)
        var obj = try json(e.settings)
        obj["statusLine"] = ["type": "command", "command": "other.sh"]
        try JSONSerialization.data(withJSONObject: obj).write(to: e.settings)
        let before = try Data(contentsOf: e.settings)
        try checkEqual(e.installer.state(), .replaced)
        try checkEqual(try e.installer.restore(), .changedByUser)
        try checkEqual(try Data(contentsOf: e.settings), before)
    }

    test("installRecordsCurrentCommandWhenReinstalledFromReplaced") {
        let e = try makeEnv(settings: "{\"statusLine\":{\"type\":\"command\",\"command\":\"sl.sh\"}}")
        _ = try e.installer.install()
        var obj = try json(e.settings)
        obj["statusLine"] = ["type": "command", "command": "new.sh"]
        try JSONSerialization.data(withJSONObject: obj).write(to: e.settings)
        try checkEqual(e.installer.state(), .replaced)
        _ = try e.installer.install()
        let sl = try json(e.installer.originalURL)["statusLine"] as? [String: Any]
        try checkEqual(sl?["command"] as? String, "new.sh")
        try checkEqual(try e.installer.restore(), .restored)
        try checkEqual(try command(e.settings), "new.sh")
    }

    test("restoreThrowsOnCorruptOriginal") {
        let e = try makeEnv(settings: "{\"statusLine\":{\"type\":\"command\",\"command\":\"sl.sh\"}}")
        _ = try e.installer.install()
        try "not json".write(to: e.installer.originalURL, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: e.settings)
        var threw = false
        do { _ = try e.installer.restore() } catch { threw = true }
        try check(threw, "应抛错")
        try checkEqual(try Data(contentsOf: e.settings), before)
        try check(FileManager.default.fileExists(atPath: e.installer.originalURL.path), "original 不应被删")
    }

    test("installThroughSymlinkedSettingsKeepsLink") {
        let e = try makeEnv(settings: nil)
        let fm = FileManager.default
        let realDir = e.root.appendingPathComponent("dotfiles repo")
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        let real = realDir.appendingPathComponent("settings.json")
        let original = "{\"model\":\"opus\"}"
        try original.write(to: real, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: e.settings, withDestinationURL: real)
        let r = try e.installer.install()
        guard case .installed(let backup?) = r else { throw TestFailure(description: "期望 installed(backup:)，实际 \(r)") }
        try check((try? fm.destinationOfSymbolicLink(atPath: e.settings.path)) != nil, "安装后 settings.json 仍应是符号链接")
        try checkEqual(try command(real), e.installer.hookCommand)
        try check((try? fm.destinationOfSymbolicLink(atPath: backup.path)) == nil, "备份应是普通文件")
        try checkEqual(try Data(contentsOf: backup), Data(original.utf8))
        _ = try e.installer.restore()
        try check((try? fm.destinationOfSymbolicLink(atPath: e.settings.path)) != nil, "还原后仍应是符号链接")
        try check(try command(real) == nil, "目标文件应已还原")
    }

    test("reinstallRepairsMissingHookScript") {
        let e = try makeEnv(settings: "{}")
        _ = try e.installer.install()
        try FileManager.default.removeItem(at: e.installer.hookURL)
        try checkEqual(try e.installer.install(), .alreadyInstalled)
        try check(FileManager.default.isExecutableFile(atPath: e.installer.hookURL.path), "钩子脚本应被补回且可执行")
    }

    test("settingsStillReferenceHook") {
        let e = try makeEnv(settings: "{}")
        try checkEqual(e.installer.settingsStillReferenceHook(), false)
        _ = try e.installer.install()
        try checkEqual(e.installer.settingsStillReferenceHook(), true)
        try "{ broken".write(to: e.settings, atomically: true, encoding: .utf8)
        try check(e.installer.settingsStillReferenceHook() == nil, "解析不了应返回 nil")
        let raw = "{\"statusLine\":{\"type\":\"command\",\"command\":\"\(e.installer.hookURL.path)\"}}"
        try raw.write(to: e.settings, atomically: true, encoding: .utf8)
        try checkEqual(e.installer.settingsStillReferenceHook(), true)
    }

    test("manualSnippetIsValidJSON") {
        let e = try makeEnv(settings: nil)
        let obj = try JSONSerialization.jsonObject(with: Data(("{" + e.installer.manualSnippet + "}").utf8)) as? [String: Any]
        try checkEqual((obj?["statusLine"] as? [String: Any])?["command"] as? String, e.installer.hookCommand)
    }

    test("shellQuoteEscapesSingleQuote") {
        try checkEqual(ClaudeStatusLineInstaller.shellQuote("a b"), "'a b'")
        try checkEqual(ClaudeStatusLineInstaller.shellQuote("it's"), "'it'\\''s'")
    }

    // 用户只用桌面 App 时钩子不会被调用：添加页给「打开终端并启动 Claude Code」，用的是这个启动脚本
    test("terminalLauncherWritesExecutableCommandFile") {
        let env = try makeEnv(settings: nil)
        defer { try? FileManager.default.removeItem(at: env.root) }
        let url = try env.installer.writeTerminalLauncher()
        try checkEqual(url.lastPathComponent, "open-claude-code.command")
        try checkEqual(url.deletingLastPathComponent().standardizedFileURL, env.support.standardizedFileURL)
        let text = try String(contentsOf: url, encoding: .utf8)
        try check(text.hasPrefix("#!/bin/sh\n"), "要有 shebang")
        try check(text.contains("-l -i -c 'claude'"), "用登录 + 交互 shell 启动 claude，PATH 才和用户平时一样")
        try check(text.contains("command -v claude"), "先检查有没有装 Claude Code 命令行")
        try check(text.contains("https://code.claude.com/docs/en/setup"), "找不到时给安装说明")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        try checkEqual(perms, 0o755)
        try checkEqual(ClaudeStatusLineInstaller.terminalCommand, "claude")
    }

    /// 假 shell：忽略 -l -i，只用 /bin/sh 跑 -c 后面的命令（不碰用户真实的 profile）
    func fakeShell(_ dir: URL) throws -> URL {
        let sh = dir.appendingPathComponent("fake shell")
        try "#!/bin/sh\nshift 3\nexec /bin/sh -c \"$1\"\n".write(to: sh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh.path)
        return sh
    }
    func runLauncher(_ url: URL, shell: URL, path: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [url.path]
        p.environment = ["SHELL": shell.path, "PATH": path, "HOME": NSTemporaryDirectory()]
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    // 只用桌面 App 的用户多半没装命令行版：找不到 claude 时打印安装说明并停住窗口，不是 command not found
    test("terminalLauncherExplainsMissingClaude") {
        let env = try makeEnv(settings: nil)
        defer { try? FileManager.default.removeItem(at: env.root) }
        let url = try env.installer.writeTerminalLauncher()
        let out = try runLauncher(url, shell: try fakeShell(env.root), path: "/usr/bin:/bin")
        try check(out.contains("没有找到 claude 命令"), "实际输出：\(out)")
        try check(out.contains("https://code.claude.com/docs/en/setup"))
        try check(out.contains("按回车键关闭"))
    }
    // 装了 claude：在固定的工作目录里启动它（不在 ~ 里，免得每次问是否信任家目录）
    test("terminalLauncherRunsClaudeInWorkDir") {
        let env = try makeEnv(settings: nil)
        defer { try? FileManager.default.removeItem(at: env.root) }
        let bin = env.root.appendingPathComponent("bin dir")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        try "#!/bin/sh\necho FAKE-CLAUDE-IN \"$(pwd)\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let url = try env.installer.writeTerminalLauncher()
        let out = try runLauncher(url, shell: try fakeShell(env.root), path: "\(bin.path):/usr/bin:/bin")
        try check(out.contains("FAKE-CLAUDE-IN"), "实际输出：\(out)")
        try check(!out.contains("没有找到"))
        let wd = env.installer.claudeWorkDirURL.resolvingSymlinksInPath().path
        try check(out.contains(wd), "应在 \(wd) 里启动，实际：\(out)")
    }

    // 用户 shell 不认 command -v（如 nushell）时，再用 /bin/sh 自己查一次（含 ~/.local/bin），不误报没装
    test("terminalLauncherFallsBackToShPath") {
        let env = try makeEnv(settings: nil)
        defer { try? FileManager.default.removeItem(at: env.root) }
        let home = env.root.appendingPathComponent("home dir")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\necho FAKE-CLAUDE\n".write(to: bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("claude").path)
        // 这个「shell」什么命令都执行失败
        let badShell = env.root.appendingPathComponent("bad shell")
        try "#!/bin/sh\nexit 1\n".write(to: badShell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: badShell.path)
        let url = try env.installer.writeTerminalLauncher()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [url.path]
        p.environment = ["SHELL": badShell.path, "PATH": "/usr/bin:/bin", "HOME": home.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try check(text.contains("FAKE-CLAUDE"), "实际输出：\(text)")
        try check(!text.contains("没有找到"))
    }
}

/// 第五批第 2 条：终端那一步把要用的命令放进同一个框，一次复制粘贴：没装 Claude Code 就先用官方命令装，再启动
@MainActor
func registerClaudeTerminalScriptTests() {
    test("claudeTerminalScriptInstallsIfMissingThenRuns") {
        let lines = ClaudeStatusLineInstaller.terminalScript.split(separator: "\n").map(String.init)
        try checkEqual(lines, [
            "command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash",
            "export PATH=\"$HOME/.local/bin:$PATH\"; claude",
        ])
        // 不含以 # 开头的注释行：zsh 交互模式默认不认注释，粘贴后会报错
        try check(!lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") })
    }
    test("claudeInstallButtonTitleFollowsHookState") {
        try checkEqual(ClaudeStatusLineInstaller.confirmButtonTitle(state: .notInstalled, busy: false), "允许修改并安装")
        try checkEqual(ClaudeStatusLineInstaller.confirmButtonTitle(state: .replaced, busy: false), "允许修改并安装")
        try checkEqual(ClaudeStatusLineInstaller.confirmButtonTitle(state: .installed, busy: false), "已安装，下一步")
        try checkEqual(ClaudeStatusLineInstaller.confirmButtonTitle(state: .notInstalled, busy: true), "正在安装…")
    }
}
