import Foundation

@MainActor
func registerClaudeHookScriptTests() {
    struct Hook {
        let dir: URL
        let quota: URL
        let orig: URL
        let hook: URL
    }
    /// dirName 可带单引号；hook 脚本写到该目录里
    func makeHook(dirName: String = "tb hook \(UUID().uuidString)", originalJSON: String? = nil) throws -> Hook {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let quota = dir.appendingPathComponent("claude-ratelimits.json")
        let orig = dir.appendingPathComponent("claude-statusline-original.json")
        let hook = dir.appendingPathComponent("claude-statusline.sh")
        try ClaudeStatusLineInstaller.hookScript(quotaFile: quota, originalFile: orig)
            .write(to: hook, atomically: true, encoding: .utf8)
        if let originalJSON { try originalJSON.write(to: orig, atomically: true, encoding: .utf8) }
        return Hook(dir: dir, quota: quota, orig: orig, hook: hook)
    }
    func run(_ h: Hook, stdin: String) throws -> (out: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [h.hook.path]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try inPipe.fileHandleForWriting.close()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }
    let sample = """
    {"session_id":"abc-secret-123","cwd":"/Users/x/proj","model":{"id":"claude-opus-4"},
     "cost":{"total_cost_usd":0.12},
     "rate_limits":{"five_hour":{"used_percentage":41.2,"resets_at":1792041780},
                    "seven_day":{"used_percentage":12,"resets_at":1792472859}}}
    """

    test("hookWritesOnlyRateLimits") {
        let h = try makeHook()
        let r = try run(h, stdin: sample)
        try checkEqual(r.status, 0)
        try checkEqual(r.out, "")
        let data = try Data(contentsOf: h.quota)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        try checkEqual(Set(obj.keys), Set(["writtenAt", "rate_limits"]))
        let rl = obj["rate_limits"] as? [String: Any]
        try check((rl?["five_hour"] as? [String: Any]) != nil && (rl?["seven_day"] as? [String: Any]) != nil, "两个窗口都应在")
        let text = String(decoding: data, as: UTF8.self)
        try check(!text.contains("session_id") && !text.contains("cwd") && !text.contains("secret"), "不应落盘会话内容")
    }

    test("hookNoRateLimitsWritesNothing") {
        let h = try makeHook()
        let r = try run(h, stdin: "{\"session_id\":\"s\",\"cwd\":\"/x\"}")
        try checkEqual(r.status, 0)
        try checkEqual(r.out, "")
        try check(!FileManager.default.fileExists(atPath: h.quota.path), "不应生成额度文件")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: h.dir.path))?.filter { $0.hasSuffix(".tmp") } ?? []
        try check(left.isEmpty, "不应留下临时文件")
    }

    test("hookScriptUsesPerProcessTmpAndAbsoluteDate") {
        let script = ClaudeStatusLineInstaller.hookScript(quotaFile: URL(fileURLWithPath: "/x/q.json"), originalFile: URL(fileURLWithPath: "/x/o.json"))
        try check(script.contains("$out.$$.tmp"), "临时文件名应带进程号")
        try check(script.contains("/bin/date +%s"), "date 应写绝对路径")
    }

    test("hookPassesStdinOutputAndExitCode") {
        let h0 = try makeHook()
        let seen = h0.dir.appendingPathComponent("seen.json")
        let cmd = "cat > \(ClaudeStatusLineInstaller.shellQuote(seen.path)); echo hi; exit 3"
        let origObj: [String: Any] = ["statusLine": ["type": "command", "command": cmd]]
        try JSONSerialization.data(withJSONObject: origObj).write(to: h0.orig)
        let r = try run(h0, stdin: sample)
        try checkEqual(r.out, "hi\n")
        try checkEqual(r.status, 3)
        let a = try JSONSerialization.jsonObject(with: Data(sample.utf8))
        let b = try JSONSerialization.jsonObject(with: Data(contentsOf: seen))
        try check((a as AnyObject).isEqual(b), "原命令应收到完整 stdin")
        try check(FileManager.default.fileExists(atPath: h0.quota.path), "同时仍写额度文件")
    }

    test("hookWorksWithSpaceAndQuoteInPath") {
        let h = try makeHook(dirName: "tb hook it's \(UUID().uuidString)")
        let r = try run(h, stdin: sample)
        try checkEqual(r.status, 0)
        try check(FileManager.default.fileExists(atPath: h.quota.path), "额度文件应写到带空格和单引号的路径")
    }

    test("settingsCommandRunsViaShellFromSpacedAndQuotedSupportDir") {
        for name in ["tb hook \(UUID().uuidString)/Application Support/TokenBar", "tb hook it's \(UUID().uuidString)/App Support"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            let settings = FileManager.default.temporaryDirectory
                .appendingPathComponent("tb hook \(UUID().uuidString)").appendingPathComponent("settings.json")
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "{\"statusLine\":{\"type\":\"command\",\"command\":\"echo orig-ok\"}}".write(to: settings, atomically: true, encoding: .utf8)
            let inst = ClaudeStatusLineInstaller(settingsURL: settings, supportDir: root)
            _ = try inst.install()
            let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
            let cmd = (obj?["statusLine"] as? [String: Any])?["command"] as? String ?? ""
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            let inPipe = Pipe(), outPipe = Pipe()
            p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
            try p.run()
            inPipe.fileHandleForWriting.write(Data("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":1,\"resets_at\":1}}}".utf8))
            try inPipe.fileHandleForWriting.close()
            let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            try checkEqual(p.terminationStatus, 0)
            try checkEqual(out, "orig-ok\n")
            try check(FileManager.default.fileExists(atPath: inst.quotaFileURL.path), "额度文件应写入：\(name)")
        }
    }
}
