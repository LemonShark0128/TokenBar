import Foundation

/// 安装 / 还原 Claude Code 的状态栏钩子：钩子只把 rate_limits 写进 TokenBar 的额度文件，
/// 并把原来的 statusLine 命令原样转发，用户看到的状态栏不变。
struct ClaudeStatusLineInstaller: Sendable {
    let settingsURL: URL
    let supportDir: URL
    let now: @Sendable () -> Date

    init(settingsURL: URL, supportDir: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.settingsURL = settingsURL
        self.supportDir = supportDir
        self.now = now
    }

    /// settings.json 若是符号链接（常见于 dotfiles 仓库），读写都落在链接指向的真文件上，链接本身保留
    private var realSettingsURL: URL { settingsURL.resolvingSymlinksInPath() }

    var hookURL: URL { supportDir.appendingPathComponent("claude-statusline.sh") }
    var quotaFileURL: URL { supportDir.appendingPathComponent("claude-ratelimits.json") }
    /// 内容是 {"statusLine": <安装前的原值或 null>}
    var originalURL: URL { supportDir.appendingPathComponent("claude-statusline-original.json") }

    enum HookState: Equatable { case notInstalled, installed, replaced }
    enum InstallResult: Equatable {
        case installed(backup: URL?)
        case alreadyInstalled
        case unparseable(snippet: String)
    }
    enum RestoreResult: Equatable { case restored, changedByUser, notInstalled }

    /// 解析不了 settings.json 时给用户手动粘贴的片段
    var manualSnippet: String {
        let obj: [String: Any] = ["type": "command", "command": hookCommand]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return "\"statusLine\": " + String(decoding: data, as: UTF8.self)
    }

    /// 写进 settings.json 的命令：Claude Code 经 shell 执行，路径里有空格（Application Support），必须加引号
    var hookCommand: String { Self.shellQuote(hookURL.path) }

    /// 给用户复制到终端运行的那一句
    static let terminalCommand = "claude"
    var terminalLauncherURL: URL { supportDir.appendingPathComponent("open-claude-code.command") }

    /// 找不到 claude 命令时给的安装说明（docs.claude.com 的旧地址会 301 到这里）
    static let installGuideURL = "https://code.claude.com/docs/en/setup"
    /// 终端里一次粘贴的两行：没装 Claude Code 就用官方安装命令装（装到 ~/.local/bin），再启动它。
    /// 不写 # 注释（zsh 交互模式默认不认注释）
    static let terminalScript = """
    command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash
    export PATH="$HOME/.local/bin:$PATH"; claude
    """

    /// 安装确认页右下角按钮：钩子已经装好时不再「安装」，直接进下一步
    static func confirmButtonTitle(state: HookState, busy: Bool) -> String {
        if busy { return L("hook.installing") }
        return state == .installed ? L("hook.installedNext") : L("hook.allowInstall")
    }
    /// 终端里启动 Claude Code 的固定目录：不在 ~ 里启动，免得 Claude Code 每次都问是否信任家目录
    var claudeWorkDirURL: URL { supportDir.appendingPathComponent("Claude Code") }

    /// 写一个 .command 启动脚本：用 Finder 打开它，终端会新开一个窗口运行 Claude Code。
    /// 用登录 + 交互 shell，PATH 和用户平时开终端一样（claude 常装在 ~/.local/bin 或 npm 全局目录）。
    /// 判断和提示都在 /bin/sh 里做（fish 不认 if …; then），用户 shell 只执行单条命令
    func writeTerminalLauncher() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: claudeWorkDirURL, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        # TokenBar：在终端里启动 Claude Code。每次回复后，状态栏钩子把套餐额度写到本机
        cd \(Self.shellQuote(claudeWorkDirURL.path)) 2>/dev/null || cd "$HOME"
        if "${SHELL:-/bin/zsh}" -l -i -c 'command -v \(Self.terminalCommand)' </dev/null >/dev/null 2>&1; then
          exec "${SHELL:-/bin/zsh}" -l -i -c '\(Self.terminalCommand)'
        fi
        # 用户 shell 不认 command -v（如 nushell）时，用 /bin/sh 自己的 PATH 加家目录下常见的安装位置再查一次
        PATH="$PATH:$HOME/.local/bin:$HOME/.claude/local:$HOME/.npm-global/bin"
        if command -v \(Self.terminalCommand) >/dev/null 2>&1; then
          exec \(Self.terminalCommand)
        fi
        echo \(Self.shellQuote(L("launcher.notFound")))
        echo \(Self.shellQuote(L("launcher.guide", Self.installGuideURL)))
        echo \(Self.shellQuote(L("launcher.afterInstall")))
        printf \(Self.shellQuote(L("launcher.pressReturn")))
        read _

        """
        let url = terminalLauncherURL
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    struct CorruptOriginalError: Error, CustomStringConvertible {
        var description: String { L("hook.corruptOriginal") }
    }

    /// 写回 settings.json 失败（只读、磁盘满、权限等）：settings.json 没有改动，界面照这句提示
    struct SettingsWriteError: LocalizedError, CustomStringConvertible {
        let underlying: Error
        var errorDescription: String? {
            L("hook.writeFailed", underlying.localizedDescription)
        }
        var description: String { errorDescription! }
    }

    /// 引号形式和原始路径形式都算「我们的」（兼容旧版写法）
    private func isOurs(_ obj: [String: Any]) -> Bool {
        guard let c = currentCommand(obj) else { return false }
        return c == hookCommand || c == hookURL.path
    }

    // MARK: 状态

    func state() -> HookState {
        if let obj = readSettings(), isOurs(obj) { return .installed }
        return FileManager.default.fileExists(atPath: originalURL.path) ? .replaced : .notInstalled
    }

    // MARK: 安装

    func install() throws -> InstallResult {
        let fm = FileManager.default
        var settings: [String: Any] = [:]
        let existed = fm.fileExists(atPath: realSettingsURL.path)
        if existed {
            guard let obj = readSettings() else {
                // 不动 settings.json、不备份、不记 original；但钩子脚本照写，用户手动粘贴片段后就能用
                try writeHookScript()
                return .unparseable(snippet: manualSnippet)
            }
            settings = obj
        }
        // 脚本被删 / 过期时重装能补回（幂等）
        if isOurs(settings) { try writeHookScript(); return .alreadyInstalled }

        var backup: URL?
        if existed {
            let b = settingsURL.deletingLastPathComponent()
                .appendingPathComponent("settings.json.tokenbar-backup-\(Self.stamp(now()))")
            // 同一秒的旧备份通常不存在，不存在就不删（否则每次安装都误记一次写入失败）
            if fm.fileExists(atPath: b.path) {
                do { try fm.removeItem(at: b) }
                catch { WriteFailureLog.shared.failed("清理旧备份", error) }
            }
            // 用读到的字节写成普通文件：settings.json 若是符号链接，copyItem 只会复制出一条链接
            try Data(contentsOf: realSettingsURL).write(to: b, options: .atomic)
            backup = b
        }

        try writeHookScript()
        // 走到这里说明当前 statusLine 不是我们的钩子：一律记下当前值（含从「被替换」状态重装），覆盖旧的 original
        let previousOriginal = try? Data(contentsOf: originalURL)
        let orig: [String: Any] = ["statusLine": settings["statusLine"] ?? NSNull()]
        try JSONSerialization.data(withJSONObject: orig, options: [.prettyPrinted, .withoutEscapingSlashes])
            .write(to: originalURL, options: .atomic)

        settings["statusLine"] = ["type": "command", "command": hookCommand]
        do {
            try writeSettings(settings)
        } catch {
            // settings.json 没写进去：original 退回安装前的样子，否则 state() 会把「没装上」误报成「被替换」
            do {
                if let previousOriginal { try previousOriginal.write(to: originalURL, options: .atomic) }
                else { try fm.removeItem(at: originalURL) }
            } catch { WriteFailureLog.shared.failed("状态栏设置回滚", error) }
            throw SettingsWriteError(underlying: error)
        }
        return .installed(backup: backup)
    }

    /// 写钩子脚本（0755）；没有 original 文件时脚本不转发任何命令
    private func writeHookScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try Self.hookScript(quotaFile: quotaFileURL, originalFile: originalURL)
            .write(to: hookURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
    }

    /// settings.json 现在是否还引用我们的钩子（引号或原始路径写法都算）；读不出 / 解析不了返回 nil
    func settingsStillReferenceHook() -> Bool? {
        guard let obj = readSettings() else {
            return FileManager.default.fileExists(atPath: realSettingsURL.path) ? nil : false
        }
        return isOurs(obj)
    }

    // MARK: 还原

    func restore() throws -> RestoreResult {
        let fm = FileManager.default
        guard let settings = readSettings(), isOurs(settings) else {
            return fm.fileExists(atPath: originalURL.path) ? .changedByUser : .notInstalled
        }
        var updated = settings
        var original: Any = NSNull()
        if fm.fileExists(atPath: originalURL.path) {
            // 文件在却读不了 / 不是有效 JSON：不能当作 null，否则会删掉用户的 statusLine
            guard let data = try? Data(contentsOf: originalURL),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let v = obj["statusLine"] else { throw CorruptOriginalError() }
            original = v
        }
        if original is NSNull { updated.removeValue(forKey: "statusLine") } else { updated["statusLine"] = original }
        do { try writeSettings(updated) } catch { throw SettingsWriteError(underlying: error) }
        if fm.fileExists(atPath: originalURL.path) { try fm.removeItem(at: originalURL) }
        if fm.fileExists(atPath: quotaFileURL.path) { try fm.removeItem(at: quotaFileURL) }
        return .restored
    }

    // MARK: 读写 settings.json

    private func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: realSettingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private func currentCommand(_ obj: [String: Any]) -> String? {
        (obj["statusLine"] as? [String: Any])?["command"] as? String
    }

    private func writeSettings(_ obj: [String: Any]) throws {
        try FileManager.default.createDirectory(at: realSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: realSettingsURL, options: .atomic)
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    // MARK: 钩子脚本

    /// 用单引号包住，内部的 ' 写成 '\''
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func hookScript(quotaFile: URL, originalFile: URL) -> String {
        """
        #!/bin/sh
        # TokenBar：Claude Code 状态栏钩子。只把 rate_limits 写进 TokenBar 的额度文件，会话的其他内容不落盘
        input=$(cat)
        out=\(shellQuote(quotaFile.path))
        orig=\(shellQuote(originalFile.path))
        rl=$(printf '%s' "$input" | /usr/bin/plutil -extract rate_limits json -o - - 2>/dev/null)
        if [ -n "$rl" ]; then
          printf '{"writtenAt": %s, "rate_limits": %s}\\n' "$(/bin/date +%s)" "$rl" > "$out.$$.tmp" && mv -f "$out.$$.tmp" "$out"
        fi
        cmd=$(/usr/bin/plutil -extract statusLine.command raw -o - "$orig" 2>/dev/null)
        if [ -n "$cmd" ]; then
          printf '%s' "$input" | /bin/sh -c "$cmd"
          exit $?
        fi
        exit 0

        """
    }
}
