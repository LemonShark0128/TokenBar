import Foundation
import SQLite3

@MainActor
func registerSampleStoreTests() {
    // 采样库文件打不开时 AppMain 退到内存库（旧版退回 Python 采集服务，已删）
    test("sampleStoreInMemoryFallback") {
        let s = try SampleStore(path: ":memory:")
        let t = Date(timeIntervalSince1970: 1_792_022_400)
        try s.append(Sample(provider: .deepseek, t: t, balance: 12, cumulativeCost: nil, currency: .cny))
        try checkEqual(try s.latest(.deepseek)?.balance, 12)
    }
    func tempStore() throws -> SampleStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SampleStore(path: dir.appendingPathComponent("samples.sqlite").path)
    }
    let base = Date(timeIntervalSince1970: 1_792_022_400)

    test("appendAndQuery") {
        let s = try tempStore()
        for i in 0..<3 {
            try s.append(Sample(provider: .deepseek, t: base.addingTimeInterval(Double(i) * 60),
                                balance: Decimal(30 - i), cumulativeCost: Decimal(i), currency: .cny))
        }
        try s.append(Sample(provider: .siliconflow, t: base, balance: 9, cumulativeCost: nil, currency: .cny))
        let got = try s.samples(.deepseek, since: base.addingTimeInterval(30))
        try checkEqual(got.map { $0.balance }, [Decimal(29), Decimal(28)])
        try checkEqual(got.map { $0.t }, [base.addingTimeInterval(60), base.addingTimeInterval(120)])
    }
    test("latestIsNewest") {
        let s = try tempStore()
        try s.append(Sample(provider: .deepseek, t: base.addingTimeInterval(120), balance: 1, cumulativeCost: nil, currency: .cny))
        try s.append(Sample(provider: .deepseek, t: base, balance: 2, cumulativeCost: nil, currency: .cny))
        try checkEqual(try s.latest(.deepseek)?.balance, Decimal(1))
        try check(try s.latest(.siliconflow) == nil)
    }
    test("pruneDropsOld") {
        let s = try tempStore()
        let old = base.addingTimeInterval(-46 * 86400), recent = base.addingTimeInterval(-86400)
        try s.append(Sample(provider: .deepseek, t: old, balance: 1, cumulativeCost: nil, currency: .cny))
        try s.append(Sample(provider: .deepseek, t: recent, balance: 2, cumulativeCost: nil, currency: .cny))
        try s.prune(olderThan: base.addingTimeInterval(-45 * 86400))
        try checkEqual(try s.samples(.deepseek, since: .distantPast).map { $0.t }, [recent])
    }
    test("decimalRoundTripsExactly") {
        let s = try tempStore()
        try s.append(Sample(provider: .deepseek, t: base, balance: Decimal(string: "27.0734162")!,
                            cumulativeCost: Decimal(string: "65.84832394")!, currency: .cny))
        let x = try s.latest(.deepseek)
        try checkEqual(x?.balance, Decimal(string: "27.0734162")!)
        try checkEqual(x?.cumulativeCost, Decimal(string: "65.84832394")!)
    }

    test("quotaUsedRoundTrips") {
        let s = try tempStore()
        try s.append(Sample(provider: .deepseek, t: base, balance: nil, cumulativeCost: nil, currency: .cny, quotaUsed: 12.25))
        try checkEqual(try s.latest(.deepseek)?.quotaUsed, 12.25)
    }
    test("oldDatabaseMigrates") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("samples.sqlite").path
        // 第二期的旧库：没有 quota_used 列
        var raw: OpaquePointer?
        try check(sqlite3_open(path, &raw) == SQLITE_OK)
        let sql = """
            CREATE TABLE samples(provider TEXT NOT NULL, t REAL NOT NULL, balance TEXT, cost TEXT, currency TEXT NOT NULL);
            CREATE INDEX samples_pt ON samples(provider, t);
            INSERT INTO samples VALUES('deepseek', 1792022400, '27.5', '3', 'CNY');
            """
        try check(sqlite3_exec(raw, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        let s = try SampleStore(path: path)
        let old = try s.latest(.deepseek)
        try checkEqual(old?.balance, Decimal(string: "27.5")!)
        try check(old?.quotaUsed == nil)
        try s.append(Sample(provider: .deepseek, t: base.addingTimeInterval(60), balance: nil, cumulativeCost: nil,
                            currency: .cny, quotaUsed: 42.5))
        try checkEqual(try s.latest(.deepseek)?.quotaUsed, 42.5)
        _ = try SampleStore(path: path)   // 迁移不能跑两次
    }
}
