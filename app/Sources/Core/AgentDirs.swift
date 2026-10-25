import Foundation

enum AgentDirKind: String, Sendable { case codex, claude }

struct AgentDirs: Equatable, Sendable {
    var codexHome: URL
    var claudeConfig: URL
    var codexSessions: URL { codexHome.appendingPathComponent("sessions", isDirectory: true) }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    static func resolve(custom: [AgentDirKind: String], env: [String: String], home: URL) -> AgentDirs {
        func directory(_ kind: AgentDirKind, _ variable: String, _ fallback: String) -> URL {
            let path = nonempty(custom[kind]) ?? nonempty(env[variable]) ?? home.appendingPathComponent(fallback).path
            if path == "~" { return home }
            if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true) }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return AgentDirs(codexHome: directory(.codex, "CODEX_HOME", ".codex"),
                         claudeConfig: directory(.claude, "CLAUDE_CONFIG_DIR", ".claude"))
    }

    /// 设置里选的目录；选回默认位置（~/.codex、~/.claude）不算自定义——否则会给 claude 传 CLAUDE_CONFIG_DIR，
    /// 它会去钥匙串里找另一条登录记录，结果当作没登录
    static func custom(_ d: UserDefaults, home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> [AgentDirKind: String] {
        var result: [AgentDirKind: String] = [:]
        for kind: AgentDirKind in [.codex, .claude] {
            guard let path = nonempty(d.string(forKey: "agentDir." + kind.rawValue)), !isDefault(kind, path, home: home) else { continue }
            result[kind] = path
        }
        return result
    }

    static func setCustom(_ kind: AgentDirKind, _ url: URL?, _ d: UserDefaults,
                          home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        let key = "agentDir." + kind.rawValue
        if let url, !isDefault(kind, url.path, home: home) { d.set(url.path, forKey: key) } else { d.removeObject(forKey: key) }
    }

    private static func isDefault(_ kind: AgentDirKind, _ path: String, home: URL) -> Bool {
        let given = resolve(custom: [kind: path], env: [:], home: home)
        let standard = resolve(custom: [:], env: [:], home: home)
        let pick: (AgentDirs) -> URL = { kind == .codex ? $0.codexHome : $0.claudeConfig }
        return pick(given).standardizedFileURL.path == pick(standard).standardizedFileURL.path
    }

    static var current: AgentDirs {
        resolve(custom: custom(.standard), env: ProcessInfo.processInfo.environment,
                home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    static func validate(_ kind: AgentDirKind, _ url: URL) -> String? {
        let fm = FileManager.default
        func directory(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        let valid: Bool
        switch kind {
        case .codex: valid = directory(url) && directory(url.appendingPathComponent("sessions"))
        case .claude:
            var isDir: ObjCBool = false
            let settings = fm.fileExists(atPath: url.appendingPathComponent("settings.json").path, isDirectory: &isDir) && !isDir.boolValue
            valid = directory(url) && (directory(url.appendingPathComponent("projects")) || settings)
        }
        return valid ? nil : L(kind == .codex ? "agentDir.invalidCodex" : "agentDir.invalidClaude")
    }

    static func displayPath(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = home.standardizedFileURL.path
        if path == base { return "~" }
        let prefix = base == "/" ? "/" : base + "/"
        return path.hasPrefix(prefix) ? "~/" + String(path.dropFirst(prefix.count)) : path
    }
}
