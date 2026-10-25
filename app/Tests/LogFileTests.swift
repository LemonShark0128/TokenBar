import Foundation

@MainActor
func registerLogFileTests() {
    func tempLog(maxBytes: Int) throws -> LogFile {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LogFile(url: dir.appendingPathComponent("app.log"), maxBytes: maxBytes)
    }
    func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
    let line = String(repeating: "x", count: 39) + "\n"     // 40 字节一行

    // 1.0.0 起日志在 ~/Library/Logs/TokenBar：新装的机器上目录还不存在，第一次写时要自己建
    test("logCreatesMissingDirectory") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-log-\(UUID().uuidString)/Logs/TokenBar")
        let log = LogFile(url: dir.appendingPathComponent("app.log"))
        log.append("a\n")
        try checkEqual(read(log.url), "a\n")
    }
    test("logAppendsUnderLimit") {
        let log = try tempLog(maxBytes: 100)
        log.append("a\n")
        log.append("b\n")
        try checkEqual(read(log.url), "a\nb\n")
        try check(read(log.rotatedURL) == nil, "没到上限不应滚动")
    }
    test("logRotatesWhenFull") {
        let log = try tempLog(maxBytes: 100)
        for _ in 0..<3 { log.append(line) }          // 120 字节，超过上限
        log.append("new\n")
        try checkEqual(read(log.rotatedURL), String(repeating: line, count: 3))
        try checkEqual(read(log.url), "new\n")      // 新文件从空开始
    }
    test("logKeepsOnlyOneRotatedCopy") {
        let log = try tempLog(maxBytes: 100)
        for _ in 0..<3 { log.append(line) }
        log.append("second\n")
        for _ in 0..<3 { log.append(line) }
        log.append("third\n")
        try checkEqual(read(log.url), "third\n")
        try check(read(log.rotatedURL)?.hasPrefix("second\n") == true, "app.log.1 应是上一份")
        let files = try FileManager.default.contentsOfDirectory(atPath: log.url.deletingLastPathComponent().path)
        try checkEqual(files.sorted(), ["app.log", "app.log.1"])
    }
    test("logDefaultLimitIsOneMegabyte") {
        try checkEqual(LogFile(url: URL(fileURLWithPath: "/dev/null")).maxBytes, 1_000_000)
    }
}
