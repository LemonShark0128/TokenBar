import Foundation

@MainActor
func registerRecordingHTTPClientTests() {
    let now = Date(timeIntervalSince1970: 1_792_072_800)
    let shanghai = TimeZone(secondsFromGMT: 28800)!
    // 不带 subjectId：会先抓一次控制台 HTML（含 subject id），录制时不能写出
    let creds = Credentials(values: ["webToken": "tok-test"])
    func inner() -> RoutedFixtureHTTPClient {
        RoutedFixtureHTTPClient(dir: "siliconflow") { url in
            switch url.host ?? "" {
            case "cloud.siliconflow.cn": return (200, "console_bills.html")
            case "walletd.siliconflow.cn": return (200, "wallet.json")
            default:
                if url.path.hasSuffix("aggregate_amount") { return (200, "aggregate_today.json") }
                return (200, "items_single.json")
            }
        }
    }

    testAsync("recordingClientPassesThroughAndRecords") {
        let rec = RecordingHTTPClient(inner: inner())
        let s = try await SiliconFlowProvider(http: rec).fetch(creds, now: now, timeZone: shanghai).get()
        try checkEqual(s.balance?.amount, Decimal(string: "27.07")!)
        // 控制台、钱包、两次汇总、一页明细
        try checkEqual(rec.entries.map(\.name), ["bills", "profile", "aggregate_amount", "aggregate_amount", "items"])
        try checkEqual(rec.entries.first?.status, 200)
    }
    testAsync("recordingClientWritesOnlyJsonBodies") {
        let rec = RecordingHTTPClient(inner: inner())
        _ = await SiliconFlowProvider(http: rec).fetch(creds, now: now, timeZone: shanghai)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try rec.write(to: dir)
        try checkEqual(files.map(\.lastPathComponent),
                       ["2-profile.json", "3-aggregate_amount.json", "4-aggregate_amount.json", "5-items.json"])
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            try check(!text.contains("tok-test") && !text.contains("sid-test-0001"), "录制文件不含 cookie / subject id")
        }
    }
}
