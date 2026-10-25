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
}

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var description: String { "SQLite：\(message)" }
}

/// 本地采样历史（保留 45 天由调用方 prune）
final class SampleStore {
    private var db: OpaquePointer?
    /// 写入 / 清理失败时记一行（调用方多半 try? 吞掉错误）
    private let failures: WriteFailureLog
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, failures: WriteFailureLog = .shared) throws {
        self.failures = failures
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw SQLiteError(message: "打不开 \(path)") }
        try exec("""
            CREATE TABLE IF NOT EXISTS samples(provider TEXT NOT NULL, t REAL NOT NULL,
                balance TEXT, cost TEXT, currency TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS samples_pt ON samples(provider, t);
            """)
        try migrateQuotaUsed()
    }

    /// 老库没有 quota_used 列：用 PRAGMA 检查，缺就补上（只会补一次）
    private func migrateQuotaUsed() throws {
        let stmt = try prepare("PRAGMA table_info(samples)")
        var has = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1), String(cString: c) == "quota_used" { has = true }
        }
        sqlite3_finalize(stmt)
        if !has { try exec("ALTER TABLE samples ADD COLUMN quota_used REAL") }
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
        let stmt = try prepare("INSERT INTO samples(provider, t, balance, cost, currency, quota_used) VALUES(?,?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, s.provider.rawValue)
        sqlite3_bind_double(stmt, 2, s.t.timeIntervalSince1970)
        bindText(stmt, 3, s.balance.map { "\($0)" })
        bindText(stmt, 4, s.cumulativeCost.map { "\($0)" })
        bindText(stmt, 5, s.currency.rawValue)
        if let q = s.quotaUsed { sqlite3_bind_double(stmt, 6, q) } else { sqlite3_bind_null(stmt, 6) }
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
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let p = text(0).flatMap(ProviderID.init(rawValue:)),
                  let c = text(4).flatMap(Currency.init(rawValue:)) else { continue }
            out.append(Sample(provider: p, t: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                              balance: text(2).flatMap { Decimal(string: $0) },
                              cumulativeCost: text(3).flatMap { Decimal(string: $0) }, currency: c,
                              quotaUsed: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)))
        }
        return out
    }

    /// since 之后（不含）的采样，按时间升序
    func samples(_ p: ProviderID, since: Date) throws -> [Sample] {
        try rows("SELECT provider, t, balance, cost, currency, quota_used FROM samples WHERE provider = ? AND t > ? ORDER BY t") {
            self.bindText($0, 1, p.rawValue)
            sqlite3_bind_double($0, 2, since.timeIntervalSince1970)
        }
    }

    func latest(_ p: ProviderID) throws -> Sample? {
        try rows("SELECT provider, t, balance, cost, currency, quota_used FROM samples WHERE provider = ? ORDER BY t DESC LIMIT 1") {
            self.bindText($0, 1, p.rawValue)
        }.first
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
