import Foundation
import CoreFoundation
import Darwin

/// 通过本机 Antigravity CLI（`agy -p /usage --output-format json`）读取 Gemini 套餐实时额度。
/// 不调用模型、不消耗 token、不读取凭据文件；登录与联网由 `agy` 进程自己处理。
enum GeminiCLIUsage {
    enum Outcome: Equatable {
        /// 没找到 agy 命令
        case notInstalled
        /// 跑了但没拿到（超时、退出码、登录失效、限流等）；参数是给用户看的原因
        case failed(String)
        /// 跑完了，但输出认不出来（格式变了）
        case unrecognized
        /// 成功返回，但账号下没有任何可用额度窗口
        case noQuotas
        case quota(Quota)
    }

    static var throttled: Outcome { .failed(L("gemini.cli.throttled")) }
    static var needsLogin: Outcome { .failed(L("gemini.cli.needsLogin")) }
    static func isLoginProblem(_ o: Outcome) -> Bool { o == needsLogin }

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
            } else if outcome == .noQuotas || isLoginProblem(outcome) {
                minutes = 0
                until = nil
            }
        }
    }

    private actor SharedBackoff {
        private var state = Backoff()
        func blocked(now: Date) -> Bool { state.blocked(now: now) }
        func record(_ outcome: Outcome, now: Date, log: @Sendable (String) -> Void) -> Outcome {
            state.record(outcome, now: now)
            if outcome == throttled { log("agy 额度被限流，\(state.minutes) 分钟内不再查") }
            return outcome
        }
    }

    actor PlanTierCache {
        private var checkedAt: Date?
        private var plan: String?
        private var lastProbeSucceeded = false
        private var pending: (gen: Int, task: Task<String?, Never>)?
        private var generation = 0

        /// 探测成功后缓存 6 小时；探测失败/超时 20 分钟后重查，期间保留上次已知套餐名避免徽章闪烁。
        static func ttl(succeeded: Bool) -> TimeInterval {
            succeeded ? 6 * 3600 : 20 * 60
        }

        func invalidate() {
            generation += 1
            checkedAt = nil
            plan = nil
            lastProbeSucceeded = false
            pending = nil
        }

        func read(now: Date, refresh: Bool = false,
                  load: @escaping @Sendable () async -> String?) async -> String? {
            if !refresh, let current = pending, current.gen == generation {
                let result = await current.task.value
                return generation == current.gen ? (result ?? plan) : nil
            }
            if !refresh, let checkedAt, now >= checkedAt,
               now.timeIntervalSince(checkedAt) < Self.ttl(succeeded: lastProbeSucceeded) {
                return plan
            }
            let gen = generation
            let task = Task { await load() }
            pending = (gen, task)
            let result = await task.value
            if pending?.gen == gen { pending = nil }
            guard generation == gen else { return nil }
            if let result {
                plan = result
                lastProbeSucceeded = true
            } else {
                lastProbeSucceeded = false
            }
            checkedAt = now
            return plan
        }
    }

    private static let backoff = SharedBackoff()
    private static let planCache = PlanTierCache()

    static let arguments = ["-p", "/usage", "--output-format", "json", "--print-timeout", "20s"]
    static let timeout: TimeInterval = 25
    static let planProbeTimeout: TimeInterval = 15
    static let maxOutputBytes = 1024 * 1024

    /// 常见安装位置（官方 install.sh 默认装到 ~/.local/bin/agy；GUI App 的 PATH 里没有它）
    static func candidates(home: URL) -> [URL] {
        let paths = [
            home.appendingPathComponent(".local/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
            home.appendingPathComponent(".gemini/antigravity/bin/agy"),
        ]
        var seen: Set<URL> = []
        return paths.filter { seen.insert($0).inserted }
    }

    static func locate(_ candidates: [URL]) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var standardWorkDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/TokenBar/gemini-cli", isDirectory: true)
    }

    private static func processEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        let system = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        env.merge(ClaudeCLIUsage.proxyEnvironment(system: system, existing: env)) { _, new in new }
        for (k, v) in extra { env[k] = v }
        return env
    }

    static func standard(now: Date, log: @escaping @Sendable (String) -> Void = { _ in }) async -> Outcome {
        guard !(await backoff.blocked(now: now)) else { return throttled }
        guard let exe = locate(candidates(home: URL(fileURLWithPath: NSHomeDirectory()))) else {
            return await backoff.record(.notInstalled, now: now, log: log)
        }
        var result = await run(executable: exe, cwd: standardWorkDir, timeout: timeout, now: now, log: log)
        if isLoginProblem(result) {
            await planCache.invalidate()
        } else if case .quota(var q) = result, q.plan == nil {
            q.plan = await planCache.read(now: now) {
                await probePlanTier(executable: exe, cwd: standardWorkDir, timeout: planProbeTimeout, log: log)
            }
            result = .quota(q)
        }
        return await backoff.record(result, now: now, log: log)
    }

    static func run(executable: URL, cwd: URL, timeout: TimeInterval, now: Date,
                    log: @escaping @Sendable (String) -> Void = { _ in }) async -> Outcome {
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = executable
            p.arguments = arguments
            p.currentDirectoryURL = cwd
            p.environment = processEnvironment()
            let out = Pipe()
            let err = Pipe()
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = out
            p.standardError = err
            let runner = Runner(process: p, stdoutPipe: out, stderrPipe: err, continuation: continuation, now: now, log: log)
            runner.queue.async { runner.start(timeout: timeout) }
        }
    }

    /// 清理上次异常退出遗留的旧探针文件（超过 2 分钟未修改），避免含状态负载的临时文件长期滞留磁盘。
    private static func sweepStaleProbeFiles(in cwd: URL, now: Date = Date()) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: cwd, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        ) else { return }
        for url in items where url.lastPathComponent.hasPrefix("plan-probe-") {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(mtime) > 120 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// 通过 `agy --settings` 注入会话级 `statusLine` 钩子（不改用户 settings.json，不消耗 token），
    /// 在 PTY 中短暂启动后读取官方公开字段 `plan_tier`，拿到后立刻终止进程并清理临时文件。
    static func probePlanTier(executable: URL, cwd: URL, timeout: TimeInterval,
                              log: @escaping @Sendable (String) -> Void = { _ in }) async -> String? {
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cwd.path)
        sweepStaleProbeFiles(in: cwd)

        let outURL = cwd.appendingPathComponent("plan-probe-\(UUID().uuidString).json")
        let tmpURL = cwd.appendingPathComponent(outURL.lastPathComponent + ".tmp")
        let command = #"umask 077 && cat > "$TOKENBAR_PLAN_OUT.tmp" && mv -f "$TOKENBAR_PLAN_OUT.tmp" "$TOKENBAR_PLAN_OUT""#
        let settingsObj: [String: Any] = [
            "statusLine": [
                "type": "command",
                "command": command,
                "enabled": true,
            ]
        ]
        guard let settingsData = try? JSONSerialization.data(withJSONObject: settingsObj),
              let settingsStr = String(data: settingsData, encoding: .utf8) else { return nil }

        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return nil }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(master, F_GETFL)
        if flags >= 0 { _ = fcntl(master, F_SETFL, flags | O_NONBLOCK) }

        return await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = executable
            p.arguments = ["--settings", settingsStr]
            p.currentDirectoryURL = cwd
            let term = ProcessInfo.processInfo.environment["TERM"].flatMap { $0.isEmpty ? nil : $0 } ?? "xterm-256color"
            p.environment = processEnvironment(extra: ["TOKENBAR_PLAN_OUT": outURL.path, "TERM": term])
            let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
            p.standardInput = slaveHandle
            p.standardOutput = slaveHandle
            p.standardError = slaveHandle
            let runner = PlanProbeRunner(process: p, masterFD: master, slaveFD: slave,
                                         outURL: outURL, tmpURL: tmpURL, continuation: continuation, log: log)
            runner.queue.async { runner.start(timeout: timeout) }
        }
    }

    private final class PlanProbeRunner: @unchecked Sendable {
        let queue = DispatchQueue(label: "TokenBar.gemini-plan-probe")
        private let process: Process
        private let masterFD: Int32
        private let slaveFD: Int32
        private let outURL: URL
        private let tmpURL: URL
        private let continuation: CheckedContinuation<String?, Never>
        private let log: @Sendable (String) -> Void
        private var keepAlive: PlanProbeRunner?
        private var readSource: DispatchSourceRead?
        private var pollTimer: DispatchSourceTimer?
        private var timeoutWork: DispatchWorkItem?
        private var idleSinceUptime: TimeInterval?
        private var finished = false

        init(process: Process, masterFD: Int32, slaveFD: Int32, outURL: URL, tmpURL: URL,
             continuation: CheckedContinuation<String?, Never>, log: @escaping @Sendable (String) -> Void) {
            self.process = process
            self.masterFD = masterFD
            self.slaveFD = slaveFD
            self.outURL = outURL
            self.tmpURL = tmpURL
            self.continuation = continuation
            self.log = log
        }

        func start(timeout: TimeInterval) {
            // 运行期间显式持有自身，finish 时释放，确保 continuation 必有归属且不泄漏
            keepAlive = self
            let outURL = self.outURL
            let tmpURL = self.tmpURL
            let q = self.queue
            process.terminationHandler = { [weak self] _ in
                let runner = self
                q.async {
                    guard let runner else {
                        try? FileManager.default.removeItem(at: outURL)
                        try? FileManager.default.removeItem(at: tmpURL)
                        return
                    }
                    if runner.finished {
                        runner.cleanupFiles()
                        return
                    }
                    let parsed = runner.readCurrentPayload()
                    runner.finish(parsed.plan)
                }
            }
            do { try process.run() } catch {
                close(slaveFD)
                close(masterFD)
                cleanupFiles()
                finish(nil)
                return
            }
            // 父进程不再持有 slave 端，子进程退出时 PTY 才能正常 EOF
            close(slaveFD)

            let fd = masterFD
            let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            rs.setEventHandler { [weak self] in
                guard let self else { return }
                var buf = [UInt8](repeating: 0, count: 4096)
                for _ in 0..<16 {
                    let n = read(fd, &buf, buf.count)
                    if n > 0 { continue }
                    if n == 0 || (errno != EAGAIN && errno != EINTR) {
                        self.readSource?.cancel()
                        self.readSource = nil
                    }
                    break
                }
            }
            rs.setCancelHandler { close(fd) }
            readSource = rs
            rs.resume()

            let pt = DispatchSource.makeTimerSource(queue: queue)
            pt.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
            pt.setEventHandler { [weak self] in
                guard let self, !self.finished else { return }
                let parsed = self.readCurrentPayload()
                if let plan = parsed.plan {
                    self.finish(plan)
                    return
                }
                if parsed.agentState == "idle" {
                    let nowUptime = ProcessInfo.processInfo.systemUptime
                    if let since = self.idleSinceUptime {
                        if nowUptime - since >= 3 { self.finish(nil) }
                    } else {
                        self.idleSinceUptime = nowUptime
                    }
                } else {
                    self.idleSinceUptime = nil
                }
            }
            pollTimer = pt
            pt.resume()

            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.finished else { return }
                self.finish(self.readCurrentPayload().plan)
            }
            timeoutWork = work
            queue.asyncAfter(deadline: .now() + timeout, execute: work)
        }

        private func readCurrentPayload() -> (plan: String?, agentState: String?) {
            guard let data = try? Data(contentsOf: outURL), !data.isEmpty else { return (nil, nil) }
            return GeminiCLIUsage.parseStatusLinePlanTier(data)
        }

        private func cleanupFiles() {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: tmpURL)
        }

        private func finish(_ result: String?) {
            guard !finished else { return }
            finished = true
            timeoutWork?.cancel(); timeoutWork = nil
            pollTimer?.cancel(); pollTimer = nil
            readSource?.cancel(); readSource = nil
            cleanupFiles()
            let proc = process
            let outURL = self.outURL
            let tmpURL = self.tmpURL
            if proc.isRunning {
                proc.terminate()
                let pid = proc.processIdentifier
                queue.asyncAfter(deadline: .now() + 2) {
                    if proc.isRunning && pid > 0 { kill(pid, SIGKILL) }
                    try? FileManager.default.removeItem(at: outURL)
                    try? FileManager.default.removeItem(at: tmpURL)
                }
            }
            if let result {
                log("agy 套餐识别：\(Diagnostics.redact(result))")
            }
            keepAlive = nil
            continuation.resume(returning: result)
        }
    }

    /// 所有可变状态只在 queue 上访问；退出、双管道 EOF 与超时共享同一完成出口。
    private final class Runner: @unchecked Sendable {
        let queue = DispatchQueue(label: "TokenBar.gemini-usage")
        private let process: Process
        private let stdoutPipe: Pipe
        private let stderrPipe: Pipe
        private let continuation: CheckedContinuation<Outcome, Never>
        private let now: Date
        private let log: @Sendable (String) -> Void
        private var outChannel: DispatchIO?
        private var errChannel: DispatchIO?
        private var timeoutWork: DispatchWorkItem?
        private var stdoutData = Data()
        private var stderrData = Data()
        private var exitCode: Int32?
        private var outDone = false
        private var errDone = false
        private var readFailed = false
        private var finished = false

        init(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe,
             continuation: CheckedContinuation<Outcome, Never>, now: Date, log: @escaping @Sendable (String) -> Void) {
            self.process = process
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.continuation = continuation
            self.now = now
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
                try? stdoutPipe.fileHandleForReading.close()
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForWriting.close()
                finish(.failed(L("cli.launchFailed")))
                return
            }
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            outChannel = readStream(stdoutPipe.fileHandleForReading, isStdErr: false)
            errChannel = readStream(stderrPipe.fileHandleForReading, isStdErr: true)
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.finished else { return }
                self.stop(self.process)
                self.finish(.failed(L("cli.timeout")))
            }
            timeoutWork = work
            queue.asyncAfter(deadline: .now() + timeout, execute: work)
        }

        private func readStream(_ handle: FileHandle, isStdErr: Bool) -> DispatchIO {
            let io = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in
                try? handle.close()
            }
            io.setLimit(lowWater: 1)
            io.read(offset: 0, length: Int.max, queue: queue) { [self] done, data, error in
                guard !finished else { return }
                if let data {
                    if isStdErr {
                        if stderrData.count < GeminiCLIUsage.maxOutputBytes {
                            stderrData.append(contentsOf: data.prefix(GeminiCLIUsage.maxOutputBytes - stderrData.count))
                        }
                    } else {
                        if stdoutData.count < GeminiCLIUsage.maxOutputBytes {
                            stdoutData.append(contentsOf: data.prefix(GeminiCLIUsage.maxOutputBytes - stdoutData.count))
                        }
                    }
                }
                if error != 0 {
                    readFailed = true
                    if isStdErr { errDone = true } else { outDone = true }
                    completeIfReady()
                } else if done {
                    if isStdErr { errDone = true } else { outDone = true }
                    completeIfReady()
                }
            }
            return io
        }

        private func stop(_ process: Process) {
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            guard pid > 0 else { return }
            queue.asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }

        private func completeIfReady() {
            guard !finished, outDone, errDone, let exitCode else { return }
            if readFailed && stdoutData.isEmpty && stderrData.isEmpty {
                finish(.failed(L("cli.readFailed")))
                return
            }
            var result = GeminiCLIUsage.outcome(stdout: stdoutData, stderr: stderrData, exitCode: exitCode, now: now)
            if readFailed && result == .unrecognized {
                result = .failed(L("cli.readFailed"))
            } else if result == .unrecognized {
                log("agy 命令行额度输出认不出：" + GeminiCLIUsage.diagnostic(stdout: stdoutData, stderr: stderrData))
            }
            finish(result)
        }

        private func finish(_ result: Outcome) {
            guard !finished else { return }
            finished = true
            timeoutWork?.cancel(); timeoutWork = nil
            process.terminationHandler = nil
            outChannel?.close(flags: .stop); outChannel = nil
            errChannel?.close(flags: .stop); errChannel = nil
            stdoutData.removeAll(keepingCapacity: false)
            stderrData.removeAll(keepingCapacity: false)
            continuation.resume(returning: result)
        }
    }

    // MARK: 解析

    /// 解析 `agy -p /usage --output-format json` 的标准输出与标准错误。
    static func outcome(stdout: Data, stderr: Data = Data(), exitCode: Int32, now: Date) -> Outcome {
        let obj = outputObject(stdout)
        let status = (obj?["status"] as? String)?.uppercased()
        let jsonError = extractErrorText(obj?["error"])
        let responseText = (obj?["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrText = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let rawStdoutText = obj == nil ? String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""

        if status == "ERROR" || exitCode != 0 {
            let candidates = [jsonError, stderrText, responseText, rawStdoutText].filter { !$0.isEmpty }
            let combined = candidates.joined(separator: " ")
            if let classified = classifyError(combined) { return classified }
            if let firstMessage = candidates.first {
                return .failed(safeFirstLine(firstMessage))
            }
            return exitCode != 0 ? .failed(L("cli.exitCode", exitCode)) : .failed(L("cli.error"))
        }

        guard let obj, status == nil || status == "SUCCESS" else {
            return .unrecognized
        }

        if let command = obj["command"] as? [String: Any],
           let data = command["data"] as? [String: Any],
           let groups = data["groups"] as? [[String: Any]] {
            if groups.isEmpty { return .noQuotas }
            let windows = parseGroups(groups, now: now)
            if windows.isEmpty {
                let hasAnyBuckets = groups.contains { !($0["buckets"] as? [[String: Any]] ?? []).isEmpty }
                let hasEnabledBuckets = groups.contains { g in
                    (g["buckets"] as? [[String: Any]] ?? []).contains { !isDisabled($0) }
                }
                return (!hasAnyBuckets || !hasEnabledBuckets) ? .noQuotas : .unrecognized
            }
            let plan = extractPlanTier(from: obj, data: data)
            return .quota(Quota(plan: plan, windows: windows, observedAt: now))
        }

        if !responseText.isEmpty {
            if let classified = classifyError(responseText) { return classified }
            let windows = parseTSV(responseText, now: now)
            if !windows.isEmpty {
                let plan = extractPlanTier(from: obj, data: (obj["command"] as? [String: Any])?["data"] as? [String: Any])
                return .quota(Quota(plan: plan, windows: windows, observedAt: now))
            }
        }
        return .unrecognized
    }

    private static let tierMatchers: [(name: String, regex: NSRegularExpression)] = [
        "ultra", "max", "plus", "pro", "enterprise", "team", "free",
    ].map { ($0, try! NSRegularExpression(pattern: "(?<![a-z0-9])\($0)(?![a-z0-9])")) }

    /// 按 ASCII 词边界匹配已知套餐词（避免 "Program"/"Promotional"/"Nonprofit" 误中 "pro"），
    /// 优先级与 `TodayCards.planBadge` 保持一致。
    static func matchCanonicalTier(_ raw: String) -> String? {
        let lower = raw.lowercased()
        let range = NSRange(lower.startIndex..., in: lower)
        for matcher in tierMatchers {
            if matcher.regex.firstMatch(in: lower, range: range) != nil {
                return matcher.name
            }
        }
        return nil
    }

    /// 把 Antigravity / Google AI 的套餐展示名归一到 TokenBar 统一的短名（ultra / max / plus / pro / enterprise / team / free）；
    /// 不认识的原始字符串返回 nil，避免把异常文案或隐私字段写入快照或日志。
    static func normalizePlanTier(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return matchCanonicalTier(trimmed)
    }

    /// 仅从 statusLine JSON 提取 `plan_tier` 与 `agent_state`，绝不读取或记录 email 等个人信息。
    static func parseStatusLinePlanTier(_ data: Data) -> (plan: String?, agentState: String?) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
        let rawPlan = (obj["plan_tier"] as? String) ?? (obj["planTier"] as? String)
        let state = (obj["agent_state"] as? String)?.lowercased()
        return (normalizePlanTier(rawPlan), state)
    }

    private static func extractPlanTier(from obj: [String: Any], data: [String: Any]?) -> String? {
        let candidates: [Any?] = [
            data?["plan_tier"], data?["planTier"], data?["tier"], data?["plan"],
            obj["plan_tier"], obj["planTier"], obj["tier"], obj["plan"],
        ]
        for value in candidates {
            if let plan = normalizePlanTier(value as? String) { return plan }
        }
        return nil
    }

    private static func extractErrorText(_ value: Any?) -> String {
        if let s = value as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let dict = value as? [String: Any], let msg = dict["message"] as? String {
            return msg.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static let http429Regex = try! NSRegularExpression(pattern: #"(?<![0-9])429(?![0-9])"#)

    private static func classifyError(_ message: String) -> Outcome? {
        let lower = message.lowercased()
        guard !lower.isEmpty else { return nil }
        let authHints = ["authentication required", "unauthenticated", "not authenticated",
                         "not logged in", "please sign in", "sign in", "login required", "re-authenticate"]
        if authHints.contains(where: lower.contains) { return needsLogin }
        let throttleHints = ["rate limit", "too many requests", "resource_exhausted", "resource exhausted"]
        if throttleHints.contains(where: lower.contains)
            || http429Regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
            return throttled
        }
        return nil
    }

    private static func safeFirstLine(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = Diagnostics.redact(first.trimmingCharacters(in: .whitespaces))
        return trimmed.isEmpty ? L("cli.error") : String(trimmed.prefix(80))
    }

    private static func isDisabled(_ bucket: [String: Any]) -> Bool {
        guard let v = bucket["disabled"] as? NSNumber, CFGetTypeID(v) == CFBooleanGetTypeID() else { return false }
        return v.boolValue
    }

    private static func isNumber(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    private static func isGeminiGroup(_ group: [String: Any]) -> Bool {
        if let name = group["name"] as? String, name.localizedCaseInsensitiveContains("gemini") { return true }
        let buckets = group["buckets"] as? [[String: Any]] ?? []
        return buckets.contains { ($0["id"] as? String)?.lowercased().hasPrefix("gemini-") == true }
    }

    static func shortGroupName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("claude") && lower.contains("gpt") { return "Claude / GPT" }
        var out = trimmed
        for suffix in [" models", " Models", " model", " Model"] {
            if out.hasSuffix(suffix) { out = String(out.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    /// 把 `command.data.groups` 映射成 TokenBar 的 `QuotaWindow` 列表：
    /// 主组（Gemini Models）→ `.session`（5h）在先、`.weekly`（weekly）在后；
    /// 其余模型组（如 Claude and GPT models）取周窗口映射为 `.weeklyModel(...)`。
    static func parseGroups(_ groups: [[String: Any]], now: Date) -> [QuotaWindow] {
        guard !groups.isEmpty else { return [] }
        let primaryIndex = groups.firstIndex(where: isGeminiGroup) ?? 0
        let primary = groups[primaryIndex]

        var sessionWindow: QuotaWindow?
        var weeklyWindow: QuotaWindow?
        var extraWindows: [QuotaWindow] = []

        func bucketWindow(_ bucket: [String: Any], asKind: QuotaWindow.Kind, minutes: Int) -> QuotaWindow? {
            guard !isDisabled(bucket), let remaining = isNumber(bucket["remaining_fraction"]) else { return nil }
            let used = min(100, max(0, (1.0 - remaining) * 100.0))
            let reset = (bucket["reset_time"] as? String).flatMap(ISODate.parse)
            return ClaudeCLIUsage.rolledOver(QuotaWindow(kind: asKind, usedPercent: used, resetsAt: reset, windowMinutes: minutes), now: now)
        }

        func bucketPeriod(_ bucket: [String: Any]) -> String {
            if let w = (bucket["window"] as? String)?.lowercased(), !w.isEmpty { return w }
            let id = (bucket["id"] as? String)?.lowercased() ?? ""
            if id.hasSuffix("-5h") || id.contains("five_hour") { return "5h" }
            if id.hasSuffix("-weekly") || id.contains("weekly") { return "weekly" }
            let name = (bucket["name"] as? String)?.lowercased() ?? ""
            if name.contains("five hour") || name.contains("5-hour") || name.contains("5h") { return "5h" }
            if name.contains("weekly") { return "weekly" }
            return ""
        }

        for bucket in primary["buckets"] as? [[String: Any]] ?? [] {
            switch bucketPeriod(bucket) {
            case "5h", "five_hour", "session":
                if sessionWindow == nil { sessionWindow = bucketWindow(bucket, asKind: .session, minutes: 300) }
            case "weekly", "seven_day", "7d":
                if weeklyWindow == nil { weeklyWindow = bucketWindow(bucket, asKind: .weekly, minutes: 10080) }
            default: break
            }
        }

        for (index, group) in groups.enumerated() where index != primaryIndex {
            let label = shortGroupName(group["name"] as? String ?? "")
            guard !label.isEmpty else { continue }
            let kind = QuotaWindow.Kind.weeklyModel(label)
            guard !extraWindows.contains(where: { $0.kind == kind }) else { continue }
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                let period = bucketPeriod(bucket)
                if ["weekly", "seven_day", "7d"].contains(period),
                   let w = bucketWindow(bucket, asKind: kind, minutes: 10080) {
                    extraWindows.append(w)
                    break
                }
            }
        }

        return [sessionWindow, weeklyWindow].compactMap { $0 } + extraWindows
    }

    /// 兜底：从 `response` 的 TSV 文本行（`<组名>\t<窗口名>\t<剩余>%\t<ISO 时间>`）解析。
    static func parseTSV(_ text: String, now: Date) -> [QuotaWindow] {
        var sessionWindow: QuotaWindow?
        var weeklyWindow: QuotaWindow?
        var extraWindows: [QuotaWindow] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let cols = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            guard cols.count >= 3 else { continue }
            let group = cols[0]
            let label = cols[1].lowercased()
            let pctStr = (cols[2].hasSuffix("%") ? String(cols[2].dropLast()) : cols[2])
                .trimmingCharacters(in: .whitespaces)
            guard let remainingPct = Double(pctStr), remainingPct.isFinite else { continue }
            let used = min(100, max(0, 100.0 - remainingPct))
            let reset = cols.count >= 4 ? ISODate.parse(cols[3]) : nil
            let is5h = label.contains("five hour") || label.contains("5-hour") || label.contains("5h")
            let isWeekly = label.contains("weekly")
            if group.localizedCaseInsensitiveContains("gemini") {
                if is5h, sessionWindow == nil {
                    sessionWindow = ClaudeCLIUsage.rolledOver(QuotaWindow(kind: .session, usedPercent: used, resetsAt: reset, windowMinutes: 300), now: now)
                } else if isWeekly, weeklyWindow == nil {
                    weeklyWindow = ClaudeCLIUsage.rolledOver(QuotaWindow(kind: .weekly, usedPercent: used, resetsAt: reset, windowMinutes: 10080), now: now)
                }
            } else if isWeekly {
                let short = shortGroupName(group)
                guard !short.isEmpty else { continue }
                let kind = QuotaWindow.Kind.weeklyModel(short)
                if !extraWindows.contains(where: { $0.kind == kind }) {
                    extraWindows.append(ClaudeCLIUsage.rolledOver(QuotaWindow(kind: kind, usedPercent: used, resetsAt: reset, windowMinutes: 10080), now: now))
                }
            }
        }
        return [sessionWindow, weeklyWindow].compactMap { $0 } + extraWindows
    }

    private static func outputObject(_ stdout: Data) -> [String: Any]? {
        if let o = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any] { return o }
        let text = String(decoding: stdout, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            if let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
               o["status"] != nil || o["command"] != nil || o["response"] != nil || o["error"] != nil {
                return o
            }
        }
        return nil
    }

    static func diagnostic(stdout: Data, stderr: Data) -> String {
        let outText = String(decoding: stdout, as: UTF8.self)
        let errText = String(decoding: stderr, as: UTF8.self)
        let sample = outText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? errText : outText
        // 先对较长前缀脱敏再截断，避免长 token / 邮箱跨第 200 字符被截断后逃过脱敏正则
        let redacted = Diagnostics.redact(String(sample.prefix(1000)))
        return String(redacted.prefix(200))
            .components(separatedBy: .newlines).joined(separator: "⏎")
    }
}
