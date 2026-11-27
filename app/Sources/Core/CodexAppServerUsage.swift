import Foundation

/// 只查账号额度，不创建会话；认证由 codex 自己处理。
enum CodexAppServerUsage {
    static let timeout: TimeInterval = 25
    static let initialize = Data((#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"tokenbar","version":"1"}}}"# + "\n").utf8)
    static let requests = Data((#"{"method":"initialized"}"# + "\n" + #"{"id":2,"method":"account/rateLimits/read"}"# + "\n").utf8)

    static func candidates(home: URL, codexHome: URL? = nil) -> [URL] {
        let paths = [home.appendingPathComponent(".local/bin/codex"),
                     URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                     URL(fileURLWithPath: "/usr/local/bin/codex"),
                     home.appendingPathComponent(".codex/local/codex"),
                     home.appendingPathComponent(".npm-global/bin/codex"),
                     (codexHome ?? home.appendingPathComponent(".codex")).appendingPathComponent("local/codex")]
        var seen: Set<URL> = []
        return paths.filter { seen.insert($0).inserted }
    }

    static func childEnvironment(base: [String: String], customCodexDir: String?) -> [String: String] {
        var env = base
        if let path = customCodexDir, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            env["CODEX_HOME"] = path
        }
        return env
    }

    /// 接受 account/rateLimits/read 的 result 或完整 JSON-RPC 回复；时间由 provider 补上。
    static func parseRateLimits(_ data: Data) -> Quota? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let result = object["result"] as? [String: Any] ?? object
        guard object["error"] == nil, let limits = result["rateLimits"] as? [String: Any],
              let primary = limits["primary"] as? [String: Any] else { return nil }
        func window(_ value: [String: Any], kind: QuotaWindow.Kind) -> QuotaWindow? {
            guard let used = value["usedPercent"] as? NSNumber, CFGetTypeID(used) != CFBooleanGetTypeID(),
                  used.doubleValue.isFinite, used.doubleValue >= 0 else { return nil }
            return QuotaWindow(kind: kind, usedPercent: used.doubleValue,
                               resetsAt: (value["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                               windowMinutes: (value["windowDurationMins"] as? NSNumber)?.intValue)
        }
        guard let first = window(primary, kind: .session) else { return nil }
        var windows = [first]
        if let secondary = limits["secondary"] as? [String: Any] {
            guard let second = window(secondary, kind: .weekly) else { return nil }
            windows.append(second)
        }
        var credits: ResetCredits?
        if let c = result["rateLimitResetCredits"] as? [String: Any], let count = ResetCredits.count(c["availableCount"]) {
            credits = ResetCredits(available: count, expiresAt: (c["credits"] as? [[String: Any]] ?? []).compactMap { ResetCredits.date($0["expiresAt"]) }.min())
        }
        return Quota(plan: limits["planType"] as? String, windows: windows,
                     observedAt: Date(timeIntervalSince1970: 0), resetCredits: credits)
    }

    static func standard() async -> Quota? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let exe = candidates(home: home, codexHome: AgentDirs.current.codexHome)
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
        let cwd = home.appendingPathComponent("Library/Application Support/TokenBar/codex-cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = exe
            process.arguments = ["app-server"]
            process.currentDirectoryURL = cwd
            let custom = AgentDirs.custom(.standard)[.codex]
            var env = childEnvironment(base: ProcessInfo.processInfo.environment,
                                       customCodexDir: custom.map { _ in AgentDirs.current.codexHome.path })
            env["PATH"] = "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            process.environment = env
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let runner = Runner(process: process, input: input, output: output, continuation: continuation)
            runner.queue.async { runner.start() }
        }
    }

    /// 所有读写和完成状态只在串行队列访问，收到 id=2 或超时后结束子进程。
    private final class Runner: @unchecked Sendable {
        let queue = DispatchQueue(label: "TokenBar.codex-reset-credits")
        let process: Process
        let input: Pipe
        let output: Pipe
        let continuation: CheckedContinuation<Quota?, Never>
        var channel: DispatchIO?
        var buffer = Data()
        var finished = false
        var initialized = false

        init(process: Process, input: Pipe, output: Pipe, continuation: CheckedContinuation<Quota?, Never>) {
            self.process = process; self.input = input; self.output = output; self.continuation = continuation
        }

        func start() {
            do { try process.run() } catch {
                try? output.fileHandleForReading.close()
                try? output.fileHandleForWriting.close()
                finish(nil)
                return
            }
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            let reader = output.fileHandleForReading
            let io = DispatchIO(type: .stream, fileDescriptor: reader.fileDescriptor, queue: queue) { _ in
                try? reader.close()
            }
            channel = io
            io.setLimit(lowWater: 1)
            io.read(offset: 0, length: Int.max, queue: queue) { [self] done, data, error in
                guard !finished else { return }
                if let data { buffer.append(contentsOf: data) }
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    accept(line)
                    if finished { return }
                }
                // 异常输出不能无限占内存。
                if error != 0 || buffer.count > 1024 * 1024 { finish(nil) }
                else if done {
                    if !buffer.isEmpty { accept(buffer) }
                    if !finished { finish(nil) }
                }
            }
            send(initialize)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(nil) }
        }

        private func send(_ data: Data) {
            do { try input.fileHandleForWriting.write(contentsOf: data) }
            catch { finish(nil) }
        }

        private func accept(_ line: Data) {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
            if ResetCredits.count(object["id"]) == 1, !initialized {
                guard object["result"] != nil, object["error"] == nil else { finish(nil); return }
                initialized = true
                send(requests)
            } else if ResetCredits.count(object["id"]) == 2 {
                finish(parseRateLimits(line))
            }
        }

        private func finish(_ value: Quota?) {
            guard !finished else { return }
            finished = true
            try? input.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
            channel?.close(flags: .stop)
            channel = nil
            if process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                queue.asyncAfter(deadline: .now() + 2) { [process] in
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
            continuation.resume(returning: value)
        }
    }
}
