import Foundation
import CoreFoundation

/// 先用 get_usage 控制协议读取账号实时额度；只有老版本不支持时才退回 /usage（可能是旧副本）。
/// 登录由 claude 进程处理，Token Bar 不读取凭据；保留文字解析用于老版本兼容。
enum ClaudeCLIUsage {
    enum Outcome: Equatable {
        /// 没找到 claude 命令
        case notInstalled
        /// 跑了但没拿到（超时、退出码、命令行报错）；参数是给用户看的原因
        case failed(String)
        /// 跑完了，但输出里没有认得的额度行（没登录、格式变了）
        case unrecognized
        case quota(Quota)
    }

    /// 复用失败类型，确保现有提示和补查逻辑仍把老版本当作失败。
    static var outdated: Outcome { .failed(L("cli.outdated")) }
    static var throttled: Outcome { .failed(L("cli.throttled")) }
    /// 命令行报登录错误：提示里直接写怎么登录
    static var needsLogin: Outcome { .failed(L("cli.needsLogin")) }
    /// 回复里没有订阅类型：退出登录、或用 API Key / Bedrock / Vertex 都是这样（claude 自己的说明），分不出来，
    /// 一句话同时说清：没用 Pro/Max 账号登录，怎么登
    static var notPlanLogin: Outcome { .failed(L("cli.notPlanLogin")) }
    /// 跟登录有关、重试也没用的结果
    static func isLoginProblem(_ o: Outcome) -> Bool { o == needsLogin || o == notPlanLogin || o == suspectedLogin }
    static var suspectedLogin: Outcome { .failed(L("cli.suspectedLogin")) }
    /// 连不上 Anthropic 时，claude 会拿本地存的旧快照回答；快照时间早于这个阈值就不当作新数据
    static var stale: Outcome { .failed(L("cli.stale")) }
    static let staleAfter: TimeInterval = 10 * 60

    struct Backoff {
        private var until: Date?
        private(set) var minutes = 0

        func blocked(now: Date) -> Bool {
            until.map { now < $0 } ?? false
        }

        mutating func record(_ outcome: Outcome, now: Date) {
            if outcome == throttled {
                minutes = minutes == 0 ? 5 : min(minutes * 2, 30)
                until = now.addingTimeInterval(TimeInterval(minutes * 60))
            } else if case .quota = outcome {
                minutes = 0
                until = nil
            }
        }
    }

    struct AuthStatus: Equatable, Sendable {
        var loggedIn: Bool
        var loginExpiresAt: Date?
    }

    /// 只取判定需要的字段，个人信息不进入诊断日志。
    static func parseAuthStatus(_ data: Data) -> AuthStatus? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let loggedIn = o["loggedIn"] as? NSNumber, CFGetTypeID(loggedIn) == CFBooleanGetTypeID() else { return nil }
        var expiry: Date?
        if let raw = o["loginExpiresAt"], !(raw is NSNull) {
            guard let text = raw as? String, let date = ISODate.parse(text) else { return nil }
            expiry = date
        }
        return AuthStatus(loggedIn: loggedIn.boolValue, loginExpiresAt: expiry)
    }

    /// 只记录真实查询；退避命中不调用这里，避免把等待误当成连续失败。
    struct ThrottleStreak {
        private(set) var startedAt: Date?
        private(set) var count = 0
        private var lastAt: Date?
        /// 两次真实查询隔得比这还久（多半是睡眠）就重新计数：限流 2 次、睡 8 小时、醒来再限流 1 次不算「连续 30 分钟」
        static let maxGap: TimeInterval = 2 * 3600

        mutating func record(_ outcome: Outcome, auth: AuthStatus?, now: Date) -> Outcome {
            guard outcome == throttled else { self = Self(); return outcome }
            if let auth, !auth.loggedIn || auth.loginExpiresAt.map({ $0 < now }) == true {
                self = Self()
                return needsLogin
            }
            if startedAt == nil || now < startedAt! || lastAt.map({ now.timeIntervalSince($0) > Self.maxGap }) == true {
                startedAt = now; count = 0
            }
            lastAt = now
            count += 1
            return count >= 3 && now.timeIntervalSince(startedAt!) >= 1800 ? suspectedLogin : throttled
        }
    }

    actor AuthCache {
        private var checkedAt: Date?
        private var status: AuthStatus?
        private var pending: Task<AuthStatus?, Never>?

        /// 平时 6 小时查一次；没查到（超时等）或 3 天内到期时 20 分钟就重查：
        /// auth status 只读本地、约 1 秒，重新登录后「N 天后到期」不该再挂好几个小时
        static func ttl(_ status: AuthStatus?, now: Date) -> TimeInterval {
            guard let status, let expiry = status.loginExpiresAt, expiry.timeIntervalSince(now) > 3 * 86400 else { return 20 * 60 }
            return 6 * 3600
        }

        func read(now: Date, refresh: Bool = false,
                  load: @escaping @Sendable () async -> AuthStatus?) async -> AuthStatus? {
            if let pending { return await pending.value }
            if !refresh, let checkedAt, now >= checkedAt, now.timeIntervalSince(checkedAt) < Self.ttl(status, now: now) { return status }
            let task = Task { await load() }
            pending = task
            let result = await task.value
            status = result
            checkedAt = now
            pending = nil
            return result
        }
    }

    private actor SharedBackoff {
        private var state = Backoff()
        private var streak = ThrottleStreak()
        private var suspected = false
        private var loginInvalid = false

        func blocked(now: Date) -> Bool { state.blocked(now: now) }

        func record(_ outcome: Outcome, auth: AuthStatus?, now: Date, log: @Sendable (String) -> Void) -> Outcome {
            let wasSuspected = suspected, wasInvalid = loginInvalid
            let result = streak.record(outcome, auth: auth, now: now)
            suspected = result == suspectedLogin
            loginInvalid = result == needsLogin
            if result == throttled {
                state.record(result, now: now)
                log("claude 额度被限流，\(state.minutes) 分钟内不再查")
            } else if isLoginProblem(result) {
                // 登录问题由 Store 的 5 分钟轮询接管，不能继续被 30 分钟限流退避挡住。
                state = Backoff()
            } else {
                // 超时、认不出等：照旧只在拿到额度时清零退避，免得一次超时把限流退避打回 5 分钟
                state.record(result, now: now)
            }
            // 失效期间每 5 分钟查一次，只在刚判成失效时记一条，免得一天几百条
            if result == needsLogin, !wasInvalid, let auth {
                log("claude 登录已失效（auth status：\(auth.loggedIn ? "已过期" : "未登录")）")
            }
            if result == suspectedLogin, !wasSuspected, let start = streak.startedAt {
                log("claude 连续 \(Int(now.timeIntervalSince(start) / 60)) 分钟拿不到额度，按登录掉线提示")
            }
            return result
        }
    }

    private static let backoff = SharedBackoff()
    private static let authCache = AuthCache()

    private static func authStatus(now: Date, refresh: Bool = false) async -> AuthStatus? {
        await authCache.read(now: now, refresh: refresh) {
            guard let exe = locate(candidates(home: URL(fileURLWithPath: NSHomeDirectory()), claudeConfig: AgentDirs.current.claudeConfig)) else { return nil }
            return await runAuthStatus(executable: exe, cwd: standardWorkDir)
        }
    }

    static func loginExpiry(now: Date) async -> Date? {
        let auth = await authStatus(now: now)
        return auth?.loggedIn == true ? auth?.loginExpiresAt : nil
    }

    static let controlArguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
                                   "--verbose", "--no-session-persistence", "--tools", "", "--strict-mcp-config",
                                   "--mcp-config", #"{"mcpServers":{}}"#, "--setting-sources", "",
                                   "--settings", #"{"disableAllHooks":true}"#]
    static let controlRequests = Data(("""
    {"type":"control_request","request_id":"initialize","request":{"subtype":"initialize"}}
    {"type":"control_request","request_id":"usage","request":{"subtype":"get_usage","skip_behaviors":true}}
    """ + "\n").utf8)

    /// 不调用模型、不留会话记录、不启动 MCP、不加载用户设置（免得每次查询都触发用户的钩子和插件）
    static let arguments = ["-p", "/usage", "--output-format", "json", "--no-session-persistence",
                            "--strict-mcp-config", "--setting-sources", "project"]
    static let timeout: TimeInterval = 25

    /// 常见安装位置（GUI App 的 PATH 里没有 ~/.local/bin）
    static func candidates(home: URL, claudeConfig: URL? = nil) -> [URL] {
        let paths = [home.appendingPathComponent(".local/bin/claude"),
         URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
         URL(fileURLWithPath: "/usr/local/bin/claude"),
         home.appendingPathComponent(".claude/local/claude"),
         home.appendingPathComponent(".npm-global/bin/claude"),
         (claudeConfig ?? home.appendingPathComponent(".claude")).appendingPathComponent("local/claude")]
        var seen: Set<URL> = []
        return paths.filter { seen.insert($0).inserted }
    }

    static func childEnvironment(base: [String: String], customClaudeDir: String?) -> [String: String] {
        var env = base
        if let path = customClaudeDir, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            env["CLAUDE_CONFIG_DIR"] = path
        }
        return env
    }

    static func locate(_ candidates: [URL]) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// 固定的工作目录：命令行会按工作目录在 ~/.claude/projects 下建一个空目录，固定下来就只有一个
    static var standardWorkDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/TokenBar/claude-cli", isDirectory: true)
    }

    /// 真 App 用：找命令、在固定目录里跑一次
    static func standard(now: Date, log: @escaping @Sendable (String) -> Void = { _ in }) async -> Outcome {
        guard !(await backoff.blocked(now: now)) else { return throttled }
        guard let exe = locate(candidates(home: URL(fileURLWithPath: NSHomeDirectory()), claudeConfig: AgentDirs.current.claudeConfig)) else { return await backoff.record(.notInstalled, auth: nil, now: now, log: log) }
        var result = await runControl(executable: exe, cwd: standardWorkDir, timeout: timeout, now: now, log: log)
        if result == outdated {
            result = await run(executable: exe, cwd: standardWorkDir, timeout: timeout, now: now, log: log)
        }
        let auth = result == throttled ? await authStatus(now: now, refresh: true) : nil
        result = await backoff.record(result, auth: auth, now: now, log: log)
        if result == stale { log("claude 返回旧数据（as_of 早于 10 分钟），多半没连上 Anthropic") }
        return result
    }

    /// 跑一次命令；超时就结束进程。输出读完再解析
    static func run(executable: URL, cwd: URL, timeout: TimeInterval, now: Date, log: @escaping @Sendable (String) -> Void = { _ in }) async -> Outcome {
        (await execute(executable: executable, cwd: cwd, timeout: timeout, now: now, control: false, log: log)).usage
    }

    static func runControl(executable: URL, cwd: URL, timeout: TimeInterval, now: Date, log: @escaping @Sendable (String) -> Void = { _ in }) async -> Outcome {
        (await execute(executable: executable, cwd: cwd, timeout: timeout, now: now, control: true, log: log)).usage
    }

    private enum CommandResult {
        case usage(Outcome), auth(AuthStatus?)
        var usage: Outcome { if case .usage(let o) = self { return o }; return .unrecognized }
    }

    static func runAuthStatus(executable: URL, cwd: URL, timeout: TimeInterval = 10) async -> AuthStatus? {
        let result = await execute(executable: executable, cwd: cwd, timeout: timeout, now: Date(), control: false, auth: true, log: { _ in })
        if case .auth(let status) = result { return status }
        return nil
    }

    private static func execute(executable: URL, cwd: URL, timeout: TimeInterval, now: Date, control: Bool, auth: Bool = false, log: @escaping @Sendable (String) -> Void) async -> CommandResult {
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        return await withCheckedContinuation { (cont: CheckedContinuation<CommandResult, Never>) in
            let p = Process()
            p.executableURL = executable
            p.arguments = auth ? ["auth", "status", "--json"] : (control ? controlArguments : arguments)
            p.currentDirectoryURL = cwd
            let custom = AgentDirs.custom(.standard)[.claude]
            var env = childEnvironment(base: ProcessInfo.processInfo.environment,
                                       customClaudeDir: custom.map { _ in AgentDirs.current.claudeConfig.path })
            let home = NSHomeDirectory()
            env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            env.removeValue(forKey: "CLAUDECODE")
            env["DISABLE_AUTOUPDATER"] = "1"
            // claude 不认 macOS 系统代理，launchd 环境里也没有代理变量，直连会被 Anthropic 拒绝（403）
            let system = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
            env.merge(proxyEnvironment(system: system, existing: env)) { _, new in new }
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            let input: Pipe? = control ? Pipe() : nil
            p.standardInput = input.map { $0 as Any } ?? FileHandle.nullDevice
            let runner = Runner(process: p, pipe: out, input: input, continuation: cont, now: now, auth: auth, log: log)
            runner.queue.async { runner.start(timeout: timeout) }
        }
    }

    /// 所有可变状态只在 queue 上访问；退出、EOF 和超时共享同一个完成出口。
    /// @unchecked Sendable：Process、DispatchIO 等不是 Sendable，安全性靠「只在 queue 上访问」保证
    private final class Runner: @unchecked Sendable {
        let queue = DispatchQueue(label: "TokenBar.claude-usage")
        private let process: Process
        private let pipe: Pipe
        private let input: Pipe?
        private let continuation: CheckedContinuation<CommandResult, Never>
        private let now: Date
        private let auth: Bool
        private let log: @Sendable (String) -> Void
        private var channel: DispatchIO?
        private var output = Data()
        private var exitCode: Int32?
        private var eof = false
        private var finished = false

        init(process: Process, pipe: Pipe, input: Pipe?, continuation: CheckedContinuation<CommandResult, Never>, now: Date, auth: Bool, log: @escaping @Sendable (String) -> Void) {
            self.process = process
            self.pipe = pipe
            self.input = input
            self.continuation = continuation
            self.now = now
            self.auth = auth
            self.log = log
        }

        func start(timeout: TimeInterval) {
            process.terminationHandler = { [self] p in
                let status = p.terminationStatus
                queue.async { [self] in
                    exitCode = status
                    completeIfReady()
                }
            }
            do { try process.run() } catch {
                finish(.failed(L("cli.launchFailed")))
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
                return
            }
            try? input?.fileHandleForReading.close()
            if let w = input?.fileHandleForWriting {
                // claude 已退出时写管道会触发 SIGPIPE（默认直接结束 Token Bar）：这个描述符上关掉，写失败只是返回错误
                _ = fcntl(w.fileDescriptor, F_SETNOSIGPIPE, 1)
                // 两行请求远小于管道容量；写失败仍由退出/EOF 给出准确的退出码。
                try? w.write(contentsOf: controlRequests)
            }
            try? pipe.fileHandleForWriting.close()
            let reader = pipe.fileHandleForReading
            let io = DispatchIO(type: .stream, fileDescriptor: reader.fileDescriptor, queue: queue) { _ in
                try? reader.close()
            }
            channel = io
            io.setLimit(lowWater: 1)
            io.read(offset: 0, length: Int.max, queue: queue) { [self] done, data, error in
                guard !finished else { return }
                if let data { output.append(contentsOf: data) }
                if input != nil {
                    while let end = output.firstIndex(of: 10) {
                        let line = Data(output[..<end])
                        output.removeSubrange(...end)
                        if accept(line) { return }
                    }
                }
                if error != 0 {
                    finish(.failed(L("cli.readFailed")))
                    if input == nil { stop(process) }
                } else if done {
                    if input != nil, !output.isEmpty, accept(output) { return }
                    eof = true
                    completeIfReady()
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                guard !finished else { return }
                // 即使主进程已退出，子进程也可能持有管道；截止时间不依赖 isRunning。
                finish(.failed(L("cli.timeout")))
                if input == nil { stop(process) }     // 控制模式 finish 里已经 stop 过，不再发第二次 SIGTERM
            }
        }

        /// 先 SIGTERM；2 秒后还没退出（忽略 SIGTERM）就 SIGKILL，免得超时后进程一直留着
        private func stop(_ process: Process) {
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            queue.asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }

        private func accept(_ line: Data) -> Bool {
            guard let result = controlOutcome(line: line, now: now) else {
                // 只保留诊断需要的前缀，避免长期保存无关消息。
                if diagnosticOutput.count < 800 {
                    diagnosticOutput.append((line + Data([10])).prefix(800 - diagnosticOutput.count))
                }
                return false
            }
            if result == .unrecognized { log("claude 命令行额度输出认不出：" + diagnostic(stdout: line)) }
            finish(result)
            return true
        }

        private var diagnosticOutput = Data()

        private func completeIfReady() {
            guard !finished, eof, let exitCode else { return }
            if auth {
                // auth status 的退出码不能代表登录状态；只按完整 stdout 的字段判断。
                finishAuth(parseAuthStatus(output))
                return
            }
            let result = input == nil ? outcome(stdout: output, exitCode: exitCode, now: now)
                : (exitCode == 0 ? .unrecognized : .failed(L("cli.exitCode", exitCode)))
            if result == .unrecognized { log("claude 命令行额度输出认不出：" + diagnostic(stdout: input == nil ? output : diagnosticOutput + output)) }
            finish(result)
        }

        private func finish(_ result: Outcome) { complete(.usage(result)) }
        private func finishAuth(_ status: AuthStatus?) { complete(.auth(status)) }

        private func complete(_ result: CommandResult) {
            guard !finished else { return }
            finished = true
            process.terminationHandler = nil
            try? input?.fileHandleForWriting.close()
            try? input?.fileHandleForReading.close()
            if input != nil { stop(process) }
            channel?.close(flags: .stop)
            channel = nil
            continuation.resume(returning: result)
        }
    }

    // MARK: 系统代理

    /// 系统代理设置（CFNetworkCopySystemProxySettings）→ 需要给 claude 补上的代理变量；已有代理变量就不动。
    /// 只处理 HTTP/HTTPS 代理，SOCKS 和 PAC 不处理
    static func proxyEnvironment(system: [String: Any], existing: [String: String]) -> [String: String] {
        let keys = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
        guard !keys.contains(where: { !(existing[$0] ?? "").isEmpty }) else { return [:] }
        func proxy(_ prefix: String) -> String? {
            guard let enabled = system["\(prefix)Enable"] as? NSNumber, enabled.intValue == 1, enabled.doubleValue == 1,
                  let host = system["\(prefix)Proxy"] as? String, !host.isEmpty,
                  let port = system["\(prefix)Port"] as? NSNumber,
                  port.doubleValue == port.doubleValue.rounded(), (1...65535).contains(port.doubleValue) else { return nil }
            return "http://\(host):\(port.intValue)"
        }
        let https = proxy("HTTPS"), http = proxy("HTTP")
        guard let secure = https ?? http, let plain = http ?? https else { return [:] }
        var env = ["HTTPS_PROXY": secure, "HTTP_PROXY": plain]
        let exceptions = (system["ExceptionsList"] as? [String] ?? [])
            .filter { !$0.isEmpty && !$0.contains("<") && !$0.contains(">") }
            .map { $0.hasPrefix("*.") ? String($0.dropFirst()) : $0 }
        if !exceptions.isEmpty { env["NO_PROXY"] = exceptions.joined(separator: ",") }
        return env
    }

    // MARK: 解析

    /// 忽略初始化和普通消息，只解析 usage 的控制回应。
    static func controlOutcome(line: Data, now: Date) -> Outcome? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any],
              response["request_id"] as? String == "usage" else { return nil }
        guard response["subtype"] as? String == "success" else {
            let error = response["error"] as? String ?? ""
            let lower = error.lowercased()
            if lower.contains("supported") || lower.contains("unknown") { return outdated }
            if ["auth", "login", "sign in", "logged in"].contains(where: lower.contains) {
                return needsLogin
            }
            return .failed(error.isEmpty ? L("cli.error") : String(error.prefix(80)))
        }
        let payload = response["response"] as? [String: Any] ?? [:]
        guard let available = payload["rate_limits_available"] as? NSNumber,
              CFGetTypeID(available) == CFBooleanGetTypeID(), available.boolValue else {
            // 没有订阅类型：11/6 实测退出登录后是 null；claude 的说明里 API Key / Bedrock / Vertex 也是 null，分不出来，
            // 所以写「没有用 Pro/Max 账号登录」并给登录方法。有类型但不是 Pro/Max 才说需要订阅
            let plan = (payload["subscription_type"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return plan.isEmpty ? notPlanLogin : .failed(L("cli.noSubscription"))
        }
        if payload["rate_limits"] == nil || payload["rate_limits"] is NSNull { return throttled }
        let limits = payload["rate_limits"] as? [String: Any] ?? [:]
        if let asOf = ((limits["seven_day_breakdown"] as? [String: Any])?["as_of"] as? String).flatMap(ISODate.parse),
           now.timeIntervalSince(asOf) > staleAfter {
            return stale
        }
        let windows = Self.windows(from: limits, now: now)
        guard !windows.isEmpty else { return .unrecognized }
        return .quota(Quota(plan: (payload["subscription_type"] as? String)?.lowercased(), windows: windows, observedAt: now,
                            resetCredits: parseResetCredits(limits["cedar_ember"])))
    }

    /// 额度窗口：five_hour / seven_day / seven_day_opus / seven_day_sonnet，各有 utilization（0–100）和 resets_at（ISO 时间）。
    /// claude 命令行的 rate_limits 和 claude.ai 网页的 /usage 是同一种格式（ClaudeWebUsage 共用）
    static func windows(from limits: [String: Any], now: Date) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        for (key, kind, minutes): (String, QuotaWindow.Kind, Int) in [
            ("five_hour", .session, 300), ("seven_day", .weekly, 10080),
            ("seven_day_opus", .weeklyModel("Opus"), 10080), ("seven_day_sonnet", .weeklyModel("Sonnet"), 10080)
        ] {
            guard let value = limits[key] as? [String: Any],
                  let used = value["utilization"] as? NSNumber,
                  CFGetTypeID(used) != CFBooleanGetTypeID() else { continue }
            let reset = (value["resets_at"] as? String).flatMap(ISODate.parse)
            windows.append(rolledOver(QuotaWindow(kind: kind, usedPercent: min(100, max(0, used.doubleValue)),
                                                  resetsAt: reset, windowMinutes: minutes), now: now))
        }
        return windows
    }

    /// 扩展字段独立解析；结构变化不能影响普通额度。
    static func parseResetCredits(_ value: Any?) -> ResetCredits? {
        func findGrants(_ value: Any, depth: Int = 0) -> Any? {
            guard depth < 20 else { return nil }
            if let object = value as? [String: Any] {
                if let grants = object["grants"] { return grants }
                for key in object.keys.sorted() {
                    if let found = findGrants(object[key]!, depth: depth + 1) { return found }
                }
            } else if let array = value as? [Any] {
                for child in array {
                    if let found = findGrants(child, depth: depth + 1) { return found }
                }
            }
            return nil
        }
        guard let value, !(value is NSNull),
              let grants = (findGrants(value) ?? value) as? [[String: Any]] else { return nil }
        var total = 0
        var dates: [Date] = []
        for grant in grants {
            guard let left = ResetCredits.count(grant["resets_left"]) else { return nil }
            let sum = total.addingReportingOverflow(left)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
            if let end = grant["ends_at"], !(end is NSNull) {
                guard let date = ResetCredits.date(end) else { return nil }
                dates.append(date)
            }
        }
        return ResetCredits(available: total, expiresAt: dates.min())
    }

    /// 命令的标准输出（JSON，可能混着别的行）→ 结果
    static func outcome(stdout: Data, exitCode: Int32, now: Date) -> Outcome {
        let obj = outputObject(stdout)
        guard let o = obj, let result = o["result"] as? String else {
            return exitCode != 0 ? .failed(L("cli.exitCode", exitCode)) : .unrecognized
        }
        if (o["is_error"] as? Bool) == true {
            let first = result.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let msg = first.trimmingCharacters(in: .whitespaces)
            return .failed(msg.isEmpty ? L("cli.error") : String(msg.prefix(80)))
        }
        guard exitCode == 0 else { return .failed(L("cli.exitCode", exitCode)) }
        return parseText(result, now: now).map { .quota($0) } ?? .unrecognized
    }

    /// 诊断与额度解析共用 JSON 提取规则，兼容输出前混入提示行。
    private static func outputObject(_ stdout: Data) -> [String: Any]? {
        let text = String(decoding: stdout, as: UTF8.self)
        var obj: [String: Any]?
        if let o = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any] { obj = o }
        if obj == nil {
            for line in text.split(whereSeparator: \.isNewline).reversed() {
                if let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], o["result"] != nil {
                    obj = o; break
                }
            }
        }
        return obj
    }

    static func diagnostic(stdout: Data) -> String {
        let result = outputObject(stdout)?["result"] as? String
        let text = result ?? String(decoding: stdout, as: UTF8.self)
        let current = result.map {
            $0.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.lowercased().hasPrefix("current") }.joined(separator: " | ")
        } ?? ""
        // 会写进 app.log：原始输出部分先打码（邮箱、token 等）；Current 行是额度文字，原样保留
        return (current + "；前 200 字：" + Diagnostics.redact(String(text.prefix(200))))
            .components(separatedBy: .newlines).joined(separator: "⏎")
    }

    /// 「Current session: 12% used · resets Oct 17 at 3:40pm (America/Los_Angeles)」
    /// 「Current week (all models): 34% used · resets Oct 23 at 9am (America/Los_Angeles)」
    /// 「Current week (Opus): …」等。一行都认不出为 nil
    static func parseText(_ text: String, now: Date) -> Quota? {
        var windows: [QuotaWindow] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let m = firstMatch(lineRegex, line) else { continue }
            let label = (m[1] ?? "").lowercased()
            guard let used = m[3].flatMap(Double.init) else { continue }
            let kind: QuotaWindow.Kind
            let minutes: Int
            if label == "session" {
                kind = .session; minutes = 300
            } else {
                let inner = (m[2] ?? "").lowercased()
                if inner.contains("opus") { kind = .weeklyModel("Opus") }
                else if inner.contains("sonnet") { kind = .weeklyModel("Sonnet") }
                else if inner.isEmpty || inner.contains("all") { kind = .weekly }
                else { kind = .weeklyModel(m[2] ?? "") }
                minutes = 10080
            }
            guard !windows.contains(where: { $0.kind == kind }) else { continue }
            let reset = m[4].flatMap { resetDate($0, now: now) }
            windows.append(rolledOver(QuotaWindow(kind: kind, usedPercent: used, resetsAt: reset, windowMinutes: minutes), now: now))
        }
        return windows.isEmpty ? nil : Quota(plan: nil, windows: windows, observedAt: now)
    }

    /// 命令行偶尔在刚重置后还报旧的重置时间（真机：8:59 重置、9:26 仍报「今天 9am」）。重置时间不晚于现在 → 当作已重置：
    /// 5 小时窗口已用 0、下一次重置时间未知（从下次使用开始算）；每周窗口已用 0、按 7 天周期往后推到晚于现在
    static func rolledOver(_ w: QuotaWindow, now: Date) -> QuotaWindow {
        guard var r = w.resetsAt, r <= now else { return w }
        var out = w
        out.usedPercent = 0
        if w.kind == .session {
            out.resetsAt = nil
        } else {
            let week: TimeInterval = 7 * 86400
            r.addTimeInterval(week * (floor(now.timeIntervalSince(r) / week) + 1))
            out.resetsAt = r
        }
        return out
    }

    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^Current (session|week(?: \(([^)]*)\))?):\s*([0-9]+(?:\.[0-9]+)?)%\s*used(?:\s*[·•|-]\s*resets\s+(.+))?$"#,
        options: [.caseInsensitive])
    private static let resetRegex = try! NSRegularExpression(
        pattern: #"^(?:([A-Za-z]{3})[a-z]*\.?\s+([0-9]{1,2})(?:,?\s+([0-9]{4}))?\s+at\s+)?([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)\s*\(([^)]+)\)"#,
        options: [.caseInsensitive])
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// 「Oct 17 at 3:40pm (America/Los_Angeles)」「3pm (UTC)」→ 时刻。没写年份时取离现在最近的那一年；
    /// 没写日期时取现在之后最近的那个时刻。时区认不出为 nil（不猜）
    static func resetDate(_ s: String, now: Date) -> Date? {
        guard let m = firstMatch(resetRegex, s.trimmingCharacters(in: .whitespaces)),
              let tzName = m[7], let tz = TimeZone(identifier: tzName.trimmingCharacters(in: .whitespaces)),
              var hour = m[4].flatMap(Int.init), hour >= 1, hour <= 12 else { return nil }
        let minute = m[5].flatMap(Int.init) ?? 0
        let pm = m[6]?.lowercased() == "pm"
        if hour == 12 { hour = 0 }
        if pm { hour += 12 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        if let mon = m[1].flatMap({ months.firstIndex(of: $0.lowercased()) }), let day = m[2].flatMap(Int.init) {
            let nowYear = cal.component(.year, from: now)
            let years = m[3].flatMap(Int.init).map { [$0] } ?? [nowYear - 1, nowYear, nowYear + 1]
            let dates = years.compactMap {
                cal.date(from: DateComponents(year: $0, month: mon + 1, day: day, hour: hour, minute: minute))
            }
            return dates.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
        }
        var c = cal.dateComponents([.year, .month, .day], from: now)
        c.hour = hour; c.minute = minute
        guard let today = cal.date(from: c) else { return nil }
        return today > now ? today : cal.date(byAdding: .day, value: 1, to: today)
    }

    /// 各捕获组的文字（没匹配上的组为 nil）
    private static func firstMatch(_ re: NSRegularExpression, _ s: String) -> [String?]? {
        let ns = s as NSString
        guard let r = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<r.numberOfRanges).map { i in
            let range = r.range(at: i)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }
}
