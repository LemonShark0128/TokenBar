import Foundation
import Security

/// 第 10 / 12 / 15 条：日志串行写、诊断里列崩溃报告、写操作失败留痕、几处用户看得到的小问题
@MainActor
func registerLogsPolishTests() {
    let now = Date(timeIntervalSince1970: 1_792_022_400)      // 上海时间 2026-10-15 08:00:00
    let tz = TimeZone(secondsFromGMT: 28800)!

    func tempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb \(tag) \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    /// 收集写失败日志的替身
    final class Lines: @unchecked Sendable {
        var all: [String] = []
        func log() -> WriteFailureLog { WriteFailureLog(sink: { [unowned self] in self.all.append($0) }) }
    }
    struct Boom: Error, CustomStringConvertible { var description: String }

    // MARK: A 日志

    test("appLoggerWritesInOrderWithTimestamp") {
        let dir = try tempDir("log")
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var time: Date
            init(_ time: Date) { self.time = time }
            func read() -> Date { lock.withLock { time } }
            func set(_ time: Date) { lock.withLock { self.time = time } }
        }
        let clock = Clock(now)
        let logger = AppLogger(file: LogFile(url: dir.appendingPathComponent("app.log")), timeZone: tz, now: { clock.read() })
        logger.log("第一行")
        clock.set(now.addingTimeInterval(61))
        logger.log("第二行")
        logger.flush()
        try checkEqual(try String(contentsOf: logger.file.url, encoding: .utf8),
                       "[10-15 08:00:00] 第一行\n[10-15 08:01:01] 第二行\n")
    }
    test("appLoggerFlushWaitsForManyLines") {
        let dir = try tempDir("log")
        let logger = AppLogger(file: LogFile(url: dir.appendingPathComponent("app.log")), timeZone: tz, now: { now })
        DispatchQueue.concurrentPerform(iterations: 200) { logger.log("行 \($0)") }
        logger.flush()
        try checkEqual(logger.file.tail(1000).count, 200)
    }
    test("appLoggerSharedIsStandardLogPath") {
        try check(AppLogger.shared.file.url.path.hasSuffix("/Library/Logs/TokenBar/app.log"), AppLogger.shared.file.url.path)
    }
    test("crashReportsNewestThreeTokenBarOnly") {
        let dir = try tempDir("crash")
        let fm = FileManager.default
        let files: [(String, TimeInterval)] = [("TokenBar-2026-10-16-230729.ips", -4000), ("TokenBar-2026-10-17-023438.ips", -3000),
                                               ("TokenBar-2026-10-17-045805.ips", -2000), ("TokenBar-2026-10-17-054219.ips", -1000),
                                               ("Safari-2026-10-17-060000.ips", -10), ("TokenBarNotes.txt", -5)]
        for (name, ago) in files {
            let u = dir.appendingPathComponent(name)
            try "不应被读取".write(to: u, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(ago)], ofItemAtPath: u.path)
        }
        let r = Diagnostics.crashReports(in: dir)
        try checkEqual(r.map(\.name), ["TokenBar-2026-10-17-054219.ips", "TokenBar-2026-10-17-045805.ips",
                                       "TokenBar-2026-10-17-023438.ips"])
        try checkEqual(r.first?.date, now.addingTimeInterval(-1000))
        try checkEqual(Diagnostics.crashReports(in: dir.appendingPathComponent("没有这个目录")).count, 0)
    }
    test("reportListsCrashReports") {
        let st = PlatformState(id: .deepseek, snapshot: snap(now), burn: nil, status: .ok)
        let crashes = [Diagnostics.CrashReport(name: "TokenBar-2026-10-17-054219.ips", date: now.addingTimeInterval(-3600))]
        let r = Diagnostics.report(appVersion: "1.0.0 (1)", osVersion: "26", now: now, timeZone: tz, platforms: [st],
                                   logLines: [], crashReports: crashes)
        try check(r.contains("最近崩溃报告（1 份）：") && r.contains("- TokenBar-2026-10-17-054219.ips（2026-10-15 07:00:00 +08:00）"), r)
        let none = Diagnostics.report(appVersion: "1", osVersion: "26", now: now, timeZone: tz, platforms: [st], logLines: [])
        try check(none.contains("最近崩溃报告：无"), none)
    }

    // MARK: B 写操作失败留痕

    test("writeFailureRecentKeepsLatestEvenWhenDeduplicatedOrSucceeded") {
        let lines = Lines()
        let log = lines.log()
        try check(log.recent().isEmpty, "新运行没有失败")
        log.failed("快照", Boom(description: "只读"), now: now)
        log.failed("快照", Boom(description: "只读"), now: now.addingTimeInterval(60))
        try checkEqual(lines.all.count, 1)
        try checkEqual(log.recent().map(\.at), [now.addingTimeInterval(60)])
        log.failed("快照", Boom(description: "磁盘满"), now: now.addingTimeInterval(120))
        log.succeeded("快照")
        try checkEqual(log.recent().map(\.at), [now.addingTimeInterval(120)])
        try checkEqual(log.recent().map(\.line), ["写入失败（快照）：磁盘满"])
    }
    test("writeFailureRecentSortsByTimeAndEvictsOldestOfTwentyPlaces") {
        let log = WriteFailureLog(sink: { _ in })
        for i in (0..<20).reversed() {
            log.failed("位置\(i)", Boom(description: "只读"), now: now.addingTimeInterval(Double(i)))
        }
        log.failed("位置0", Boom(description: "只读"), now: now.addingTimeInterval(30))
        log.failed("新增", Boom(description: "只读"), now: now.addingTimeInterval(20))
        let recent = log.recent()
        try checkEqual(recent.count, 20)
        try checkEqual(recent.map(\.at), (2...20).map { now.addingTimeInterval(Double($0)) } + [now.addingTimeInterval(30)])
        try checkEqual(recent.first?.line, "写入失败（位置2）：只读")
        try checkEqual(recent.last?.line, "写入失败（位置0）：只读")
    }
    test("reportListsAndRedactsWriteFailuresBeforeRecentLogs") {
        let failures = ["[2026-10-15 08:00:00 +08:00] 写入失败（快照）：sk-fake-secret-123",
                        "[2026-10-15 08:01:00 +08:00] 写入失败（采样库）：只读"]
        let r = Diagnostics.report(appVersion: "1", osVersion: "26", now: now, timeZone: tz,
                                   platforms: [], logLines: (1...60).map { "日志\($0)" }, writeFailures: failures)
        let section = "本次运行的写入失败（2 处）：\n[2026-10-15 08:00:00 +08:00] 写入失败（快照）：sk-***\n[2026-10-15 08:01:00 +08:00] 写入失败（采样库）：只读\n最近 50 行日志：\n日志11\n"
        try check(r.contains(section), r)
        try check(!r.contains("sk-fake-secret-123"), "写入失败必须打码")
        let none = Diagnostics.report(appVersion: "1", osVersion: "26", now: now, timeZone: tz,
                                      platforms: [], logLines: [])
        try check(!none.contains("本次运行的写入失败"), none)
        try check(none.contains("最近 0 行日志："), none)
    }

    test("writeFailureLogOncePerStreak") {
        let lines = Lines()
        let log = lines.log()
        log.failed("采样库写入", Boom(description: "磁盘满"))
        log.failed("采样库写入", Boom(description: "磁盘满"))
        try checkEqual(lines.all, ["写入失败（采样库写入）：磁盘满"])
        log.failed("采样库写入", Boom(description: "只读"))          // 原因变了再记
        log.succeeded("采样库写入")
        log.failed("采样库写入", Boom(description: "只读"))          // 成功过一次后再失败要重新记
        log.failed("快照写入", Boom(description: "只读"))
        try checkEqual(lines.all.count, 4)
    }
    test("sampleStoreWriteFailureIsLogged") {
        let dir = try tempDir("samples")
        let path = dir.appendingPathComponent("samples.sqlite").path
        do { _ = try SampleStore(path: path) }                                  // 建好表后关掉
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        let lines = Lines()
        let store = try SampleStore(path: path, failures: lines.log())
        let s = Sample(provider: .deepseek, t: now, balance: 1, cumulativeCost: nil, currency: .cny)
        var threw = false
        do { try store.append(s) } catch { threw = true }
        try check(threw, "只读库写入应抛错（行为不变）")
        try checkEqual(lines.all.count, 1)
        try check(lines.all[0].hasPrefix("写入失败（采样库写入）："), lines.all[0])
        try? store.prune(olderThan: now)
        try checkEqual(lines.all.count, 2)
    }
    test("snapshotCacheWriteFailureIsLogged") {
        let dir = try tempDir("cache")
        let blocker = dir.appendingPathComponent("not-a-dir")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)        // 父目录其实是个文件：建不了目录
        let lines = Lines()
        let cache = SnapshotCache(url: blocker.appendingPathComponent("last-snapshot.json"), failures: lines.log())
        var threw = false
        do { try cache.save(snap(now)) } catch { threw = true }
        try check(threw, "写不了应抛错（行为不变）")
        try checkEqual(lines.all.count, 1)
        try check(lines.all[0].hasPrefix("写入失败（快照写入）："), lines.all[0])
    }
    test("keychainWriteFailureIsLoggedWithoutSecrets") {
        let ops = FakeKeychainOperations()
        ops.failAdd = true
        let lines = Lines()
        let store = KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: freshDefaults(), failures: lines.log())
        var threw = false
        do { try store.save(Credentials(values: ["apiKey": "sk-fake-secret-123"]), for: .deepseek) } catch { threw = true }
        try check(threw, "写失败应照旧抛错")
        try checkEqual(lines.all.count, 1)
        try check(lines.all[0].hasPrefix("写入失败（钥匙串写入）：") && lines.all[0].contains("\(errSecIO)"), lines.all[0])
        try check(!lines.all[0].contains("sk-fake"), "日志里不能有凭据")
    }

    // MARK: C4 settings.json 写回失败

    /// settings.json 是指向只读目录里真文件的符号链接：备份、original 都写得进，唯独写回 settings.json 失败
    func readOnlySettingsEnv(_ content: String) throws -> (ClaudeStatusLineInstaller, real: URL, roDir: URL) {
        let root = try tempDir("hook")
        let claude = root.appendingPathComponent(".claude")
        let roDir = root.appendingPathComponent("dot files")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)
        let real = roDir.appendingPathComponent("settings.json")
        try content.write(to: real, atomically: true, encoding: .utf8)
        let link = claude.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roDir.path)
        let inst = ClaudeStatusLineInstaller(settingsURL: link, supportDir: root.appendingPathComponent("Application Support/TokenBar"),
                                             now: { now })
        return (inst, real, roDir)
    }
    test("installWriteFailureRollsBackAndExplains") {
        let content = "{\"model\":\"opus\"}"
        let (inst, real, roDir) = try readOnlySettingsEnv(content)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roDir.path) }
        var caught: Error?
        do { _ = try inst.install() } catch { caught = error }
        guard let e = caught else { throw TestFailure(description: "写不进 settings.json 应抛错") }
        try check(e is ClaudeStatusLineInstaller.SettingsWriteError, "应是可读的写回错误：\(e)")
        try check(e.localizedDescription.contains("settings.json") && e.localizedDescription.contains("没有改动"), e.localizedDescription)
        try checkEqual(inst.state(), .notInstalled)                  // 不能误报 .replaced
        try check(!FileManager.default.fileExists(atPath: inst.originalURL.path), "original 要撤掉")
        try checkEqual(try String(contentsOf: real, encoding: .utf8), content)
    }
    test("reinstallWriteFailureKeepsPreviousOriginal") {
        let (inst, _, roDir) = try readOnlySettingsEnv("{\"statusLine\":{\"type\":\"command\",\"command\":\"other.sh\"}}")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roDir.path) }
        // 之前装过、被别人换掉了：original 里记的是更早的命令
        try FileManager.default.createDirectory(at: inst.supportDir, withIntermediateDirectories: true)
        let before = Data("{\"statusLine\":{\"command\":\"first.sh\"}}".utf8)
        try before.write(to: inst.originalURL)
        try checkEqual(inst.state(), .replaced)
        do { _ = try inst.install() } catch {}
        try checkEqual(try Data(contentsOf: inst.originalURL), before)
        try checkEqual(inst.state(), .replaced)
    }

    // MARK: C1–C3 文案

    test("onboardingStepButtonLastSaysDone") {
        try checkEqual(OnboardingPlan.stepButton(isLast: true), "完成")
        try checkEqual(OnboardingPlan.stepButton(isLast: false), "下一步")
    }
    test("settingsAddingPlanText") {
        try checkEqual(SettingsLayout.addingText(.codexPlan), "正在添加 Codex 套餐…")
    }
    test("quotaOfflineSaysLocalRecordNotNetwork") {
        try checkEqual(StatusPresenter.offlineTitle(.codexPlan), "读不到本机 Codex 记录")
        try checkEqual(StatusPresenter.offlineTitle(.claudePlan), "读不到本机 Claude 记录")
        try checkEqual(StatusPresenter.offlineTitle(.deepseek), "连不上 DeepSeek")
        let st = PlatformState(id: .codexPlan, snapshot: nil, burn: nil, status: .offline)
        try checkEqual(StatusPresenter.error(for: st, name: "Codex 套餐"), "读不到本机 Codex 记录")
        let i = StatusPresenter.Input(state: st, data: nil, error: nil, now: now, providerName: "Codex 套餐")
        try check(StatusPresenter.freshness(i) == (.offline, "读不到本机 Codex 记录"), "\(StatusPresenter.freshness(i))")
        try checkEqual(AppDataMapping.statusText(st, now: now), "读不到记录")
        try checkEqual(AccountState.offline.label(for: .codexPlan), "读不到本机记录")
        try checkEqual(AccountState.offline.label(for: .deepseek), "连不上")
        // 按量付费平台不变
        let ds = PlatformState(id: .deepseek, snapshot: nil, burn: nil, status: .offline)
        try checkEqual(StatusPresenter.error(for: ds, name: "DeepSeek"), "连不上 DeepSeek，检查网络")
        try checkEqual(AppDataMapping.statusText(ds, now: now), "连不上")
    }
}
