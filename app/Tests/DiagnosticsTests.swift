import Foundation

/// 诊断信息：必须把任何 key / token 片段打码。测试里的「凭据」都是假的
@MainActor
func registerDiagnosticsTests() {
    let now = Date(timeIntervalSince1970: 1_792_022_400)

    test("redactMasksSkAndBearer") {
        let raw = "请求头 Authorization: Bearer abc.def-123XYZ ，换了 key sk-test000000000000abcd 和 sk-ab12********9999"
        let out = Diagnostics.redact(raw)
        for leak in ["abc.def-123XYZ", "test000", "abcd", "ab12", "9999"] {
            try check(!out.contains(leak), "打码后不应出现 \(leak)：\(out)")
        }
        try check(out.contains("sk-***"), out)
        try check(out.contains("Bearer ***"), out)
    }
    test("redactMasksKeyValueJwtAndLongSecrets") {
        let raw = """
        token=tok-test-123456 api_key: "fake-key-777" userToken=xyz987abc
        cookie: session=abcdef0123
        eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJl
        tracking 9f8e7d6c5b4a39281706f5e4d3c2b1a0ffeeddcc
        """
        let out = Diagnostics.redact(raw)
        for leak in ["tok-test-123456", "fake-key-777", "xyz987abc", "abcdef0123", "eyJhbGci", "c2lnbmF0dXJl",
                     "9f8e7d6c5b4a3928"] {
            try check(!out.contains(leak), "打码后不应出现 \(leak)：\(out)")
        }
    }
    test("redactKeepsOrdinaryLines") {
        let lines = ["[10-15 10:55:10] 已恢复刷新：余额 ¥27.07",
                     "[10-15 10:52:36] dumpstore：已写 debug-dump.json（取数时间 2026-10-15 17:51:55 +0000）",
                     "采样库：/Users/test/Library/Application Support/TokenBar/samples.sqlite",
                     "[10-15 10:55:10] 状态栏就绪：左键开面板，右键出菜单（含真正退出）",
                     "[10-14 21:19:27] 状态栏显示：余额=true token=true 花费=true 滚动=false"]
        for l in lines { try checkEqual(Diagnostics.redact(l), l) }
    }
    test("reportHasVersionStatusAndLast50RedactedLines") {
        let logs = (1...60).map { "[10-15 08:00:00] 第 \($0) 行" + ($0 == 59 ? " Bearer secret-bearer-0001 sk-test-0000xyz" : "") }
        var st = PlatformState(id: .deepseek, snapshot: snap(now), burn: nil, status: .ok)
        st.lastSampleAt = now
        let r = Diagnostics.report(appVersion: "1.2 (34)", osVersion: "Version 26.5 (Build 25F00)", now: now,
                                   timeZone: TimeZone(secondsFromGMT: 28800)!, platforms: [st], logLines: logs)
        try check(r.contains("1.2 (34)"), "应含 App 版本")
        try check(r.contains("Version 26.5"), "应含 macOS 版本")
        try check(r.contains("deepseek") && r.contains("ok"), "应含平台状态：\(r)")
        try check(!r.contains("第 10 行") && r.contains("第 11 行") && r.contains("第 60 行"), "只要最后 50 行")
        try check(!r.contains("secret-bearer-0001") && !r.contains("0000xyz"), "日志里的凭据要打码")
    }
    test("logTailFillsFromRotatedFile") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = LogFile(url: dir.appendingPathComponent("app.log"), maxBytes: 1_000_000)
        try (1...40).map { "old \($0)\n" }.joined().write(to: log.rotatedURL, atomically: true, encoding: .utf8)
        try (1...20).map { "new \($0)\n" }.joined().write(to: log.url, atomically: true, encoding: .utf8)
        let t = log.tail(50)
        try checkEqual(t.count, 50)
        try checkEqual(t.first, "old 11")
        try checkEqual(t.last, "new 20")
        try checkEqual(log.tail(5), ["new 16", "new 17", "new 18", "new 19", "new 20"])
    }
}
