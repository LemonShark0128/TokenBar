import Foundation
import SQLite3

/// 一次采样：用于算时速、7 天趋势；金额以字符串存进 SQLite，保证 Decimal 精确
struct Sample: Equatable {
    var provider: ProviderID
    var t: Date
    var balance: Decimal?
    var cumulativeCost: Decimal?
    var currency: Currency
    /// 套餐平台：窗口已用百分点（有效已用）；按量付费平台为 nil
    var quotaUsed: Double? = nil
    /// quotaUsed 是哪个窗口的（`QuotaWindow.Kind.sampleKey`）；老库里的采样和按量付费平台为 nil
    var quotaWindow: String? = nil
}

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var description: String { "SQLite：\(message)" }
}

/// 本地采样历史（保留 45 天由调用方 prune）
final class SampleStore {
    private var db: OpaquePointer?
    let path: String
    /// 写入 / 清理失败时记一行（调用方多半 try? 吞掉错误）
    private let failures: WriteFailureLog
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, failures: WriteFailureLog = .shared, readOnly: Bool = false) throws {
        self.path = path
        self.failures = failures
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else { throw SQLiteError(message: "打不开 \(path)") }
        // 别的连接（如另一个进程）正在写时等一会儿，不立刻报「database is locked」
        sqlite3_busy_timeout(db, 5000)
        if readOnly { return }
        try exec("""
            CREATE TABLE IF NOT EXISTS samples(provider TEXT NOT NULL, t REAL NOT NULL,
                balance TEXT, cost TEXT, currency TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS samples_pt ON samples(provider, t);
            """)
        try migrateColumns()
    }

    /// 老库没有 quota_used / quota_window 列：用 PRAGMA 检查，缺哪列补哪列（只会补一次）。
    /// 缺列时在写锁（BEGIN IMMEDIATE）里重查再补，两个连接同时打开老库时不会重复补列；列齐了不加锁
    private func migrateColumns() throws {
        let wanted: Set<String> = ["quota_used", "quota_window"]
        guard !wanted.isSubset(of: try columns()) else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            let have = try columns()
            if !have.contains("quota_used") { try exec("ALTER TABLE samples ADD COLUMN quota_used REAL") }
            if !have.contains("quota_window") { try exec("ALTER TABLE samples ADD COLUMN quota_window TEXT") }
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func columns() throws -> Set<String> {
        let stmt = try prepare("PRAGMA table_info(samples)")
        defer { sqlite3_finalize(stmt) }
        var have: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) { have.insert(String(cString: c)) }
        }
        return have
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer?, _ i: Int32, _ s: String?) {
        if let s = s { sqlite3_bind_text(stmt, i, s, -1, Self.transient) } else { sqlite3_bind_null(stmt, i) }
    }

    func append(_ s: Sample) throws {
        try failures.run("采样库写入") { try insert(s) }
    }

    private func insert(_ s: Sample) throws {
        let stmt = try prepare("INSERT INTO samples(provider, t, balance, cost, currency, quota_used, quota_window) VALUES(?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, s.provider.rawValue)
        sqlite3_bind_double(stmt, 2, s.t.timeIntervalSince1970)
        bindText(stmt, 3, s.balance.map { "\($0)" })
        bindText(stmt, 4, s.cumulativeCost.map { "\($0)" })
        bindText(stmt, 5, s.currency.rawValue)
        if let q = s.quotaUsed { sqlite3_bind_double(stmt, 6, q) } else { sqlite3_bind_null(stmt, 6) }
        bindText(stmt, 7, s.quotaWindow)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteError(message: String(cString: sqlite3_errmsg(db))) }
    }

    private func rows(_ sql: String, _ bind: (OpaquePointer?) -> Void) throws -> [Sample] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var out: [Sample] = []
        func text(_ i: Int32) -> String? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, i))
        }
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            defer { result = sqlite3_step(stmt) }
            guard let p = text(0).flatMap(ProviderID.init(rawValue:)),
                  let c = text(4).flatMap(Currency.init(rawValue:)) else { continue }
            out.append(Sample(provider: p, t: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                              balance: text(2).flatMap { Decimal(string: $0) },
                              cumulativeCost: text(3).flatMap { Decimal(string: $0) }, currency: c,
                              quotaUsed: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5),
                              quotaWindow: text(6)))
        }
        guard result == SQLITE_DONE else { throw SQLiteError(message: String(cString: sqlite3_errmsg(db))) }
        return out
    }

    /// since 之后（不含）的采样，按时间升序
    func samples(_ p: ProviderID, since: Date) throws -> [Sample] {
        try rows("SELECT provider, t, balance, cost, currency, quota_used, quota_window FROM samples WHERE provider = ? AND t > ? ORDER BY t") {
            self.bindText($0, 1, p.rawValue)
            sqlite3_bind_double($0, 2, since.timeIntervalSince1970)
        }
    }

    private func costSamples(_ p: ProviderID, in range: DateInterval) throws -> [Sample] {
        try rows("""
            SELECT provider, t, balance, cost, currency, quota_used, quota_window FROM samples
            WHERE provider = ? AND t >= ? AND t <= ? AND cost IS NOT NULL ORDER BY t
            """) {
            self.bindText($0, 1, p.rawValue)
            sqlite3_bind_double($0, 2, range.start.timeIntervalSince1970)
            sqlite3_bind_double($0, 3, range.end.timeIntervalSince1970)
        }
    }

    static func loadCostHistory(path: String, ids: [ProviderID], range: DateInterval) throws -> [ProviderID: [Sample]] {
        let reader = try SampleStore(path: path, readOnly: true)
        return try Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, try reader.costSamples(id, in: range))
        })
    }

    /// 估算窗口含边界，并补上之前最后一个有效余额；长停机也只额外读一行。
    func balanceSamples(_ p: ProviderID, since: Date) throws -> [Sample] {
        let before = try rows("SELECT provider, t, balance, cost, currency, quota_used, quota_window FROM samples WHERE provider = ? AND t < ? AND balance IS NOT NULL ORDER BY t DESC LIMIT 1") {
            self.bindText($0, 1, p.rawValue)
            sqlite3_bind_double($0, 2, since.timeIntervalSince1970)
        }
        let after = try rows("SELECT provider, t, balance, cost, currency, quota_used, quota_window FROM samples WHERE provider = ? AND t >= ? AND balance IS NOT NULL ORDER BY t") {
            self.bindText($0, 1, p.rawValue)
            sqlite3_bind_double($0, 2, since.timeIntervalSince1970)
        }
        return before + after
    }

    /// 判断「正在用」用的采样：有余额或有本月累计花费的（同 balanceSamples，多算只有花费的那些）
    func activitySamples(_ p: ProviderID, since: Date) throws -> [Sample] {
        let has = "(balance IS NOT NULL OR cost IS NOT NULL)"
        let before = try rows("SELECT provider, t, balance, cost, currency, quota_used, quota_window FROM samples WHERE provider = ? AND t < ? AND \(has) ORDER BY t DESC LIMIT 1") {
            self.bindText($0, 1, p.rawValue)
            sqlite3_bind_double($0, 2, since.timeIntervalSince1970)
        }
        let after = try rows("SELECT provider, t, balance, cost, currency, quota_used, quota_window FROM samples WHERE provider = ? AND t >= ? AND \(has) ORDER BY t") {
            self.bindText($0, 1, p.rawValue)
            sqlite3_bind_double($0, 2, since.timeIntervalSince1970)
        }
        return before + after
    }

    func latest(_ p: ProviderID) throws -> Sample? {
        try rows("SELECT provider, t, balance, cost, currency, quota_used, quota_window FROM samples WHERE provider = ? ORDER BY t DESC LIMIT 1") {
            self.bindText($0, 1, p.rawValue)
        }.first
    }

    /// 这个平台最早一条采样的时间（TokenBar 从那时开始记它）；没有采样时 nil
    func earliest(_ p: ProviderID) throws -> Date? {
        let stmt = try prepare("SELECT MIN(t) FROM samples WHERE provider = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, p.rawValue)
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
    }

    func remove(_ p: ProviderID) throws {
        try failures.run("采样库删除平台") {
            let stmt = try prepare("DELETE FROM samples WHERE provider = ?")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, p.rawValue)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteError(message: String(cString: sqlite3_errmsg(db))) }
        }
    }

    func prune(olderThan: Date) throws {
        try failures.run("采样库清理") {
            let stmt = try prepare("DELETE FROM samples WHERE t < ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, olderThan.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteError(message: String(cString: sqlite3_errmsg(db))) }
        }
    }
}
