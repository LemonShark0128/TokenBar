import Foundation

enum ExchangeRateError: Error, Equatable {
    case http(Int)
    case badFormat
    /// 窗口内没有任何一天带 CNY
    case noData
    /// 有数值 ≤ 0 或不在 1–20 之间，宁可不用
    case outOfRange
}

/// 美元兑人民币汇率：取 Frankfurter（欧洲央行参考汇率，免 key）近 7 天的平均，存进 ProviderSettings.usdToCny。
/// 24 小时内成功更新过就不再请求；失败时沿用旧值，只写一行日志，6 小时后再试。
enum ExchangeRate {
    static let updatedAtKey = "usdToCnyUpdatedAt"
    static let failedAtKey = "usdToCnyFailedAt"
    static let refreshInterval: TimeInterval = 24 * 3600
    static let retryAfterFailure: TimeInterval = 6 * 3600
    /// 成功过、但之后一直失败超过这么久，界面改说「暂时无法获取」
    static let staleAfter: TimeInterval = 48 * 3600
    /// api.frankfurter.app 现在会 301 到这里，直接请求新地址省一跳
    static let base = "https://api.frankfurter.dev/v1/"
    static let windowDays = 7

    private static func utcDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// 今天往前 7 天（含今天，按 UTC 日期）
    static func window(now: Date) -> (from: String, to: String) {
        (utcDay(now.addingTimeInterval(-Double(windowDays - 1) * 86400)), utcDay(now))
    }

    static func url(now: Date) -> URL {
        let w = window(now: now)
        return URL(string: "\(base)\(w.from)..\(w.to)?from=USD&to=CNY")!
    }

    /// 解析时间序列并求平均（保留 4 位小数）。接口会多给一个窗口之前的工作日，按日期过滤掉；周末、假日本来就没有数据
    static func average(_ data: Data, from: String, to: String) -> Result<Decimal, ExchangeRateError> {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = obj["rates"] as? [String: Any] else { return .failure(.badFormat) }
        var values: [Decimal] = []
        for (day, v) in rates where day >= from && day <= to {
            guard let n = (v as? [String: Any])?["CNY"] as? NSNumber else { continue }
            guard let d = Decimal(string: n.stringValue, locale: Locale(identifier: "en_US_POSIX")) else { return .failure(.badFormat) }
            guard d >= 1, d <= 20 else { return .failure(.outOfRange) }
            values.append(d)
        }
        guard !values.isEmpty else { return .failure(.noData) }
        var avg = values.reduce(0, +) / Decimal(values.count)
        var out = Decimal()
        NSDecimalRound(&out, &avg, 4, .plain)
        return .success(out)
    }

    private static func date(_ d: UserDefaults, _ key: String) -> Date? {
        guard d.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSince1970: d.double(forKey: key))
    }
    static func lastUpdated(_ d: UserDefaults) -> Date? { date(d, updatedAtKey) }
    static func lastFailed(_ d: UserDefaults) -> Date? { date(d, failedAtKey) }

    /// 上次失败不到 6 小时不请求；否则从没成功过、已满 24 小时、或上次时间在未来（时钟被往回拨）都要刷新
    static func needsRefresh(_ d: UserDefaults, now: Date) -> Bool {
        if let f = lastFailed(d) {
            let age = now.timeIntervalSince(f)
            if age >= 0 && age < retryAfterFailure { return false }
        }
        guard let last = lastUpdated(d) else { return true }
        let age = now.timeIntervalSince(last)
        return age < 0 || age >= refreshInterval
    }

    /// 需要时请求一次；成功返回新汇率并写入 usdToCny 和更新时间，不需要或失败返回 nil（失败只记一行日志，不带响应内容）
    static func refresh(client: HTTPClient, defaults d: UserDefaults, now: Date,
                        log: (String) -> Void) async -> Decimal? {
        guard needsRefresh(d, now: now) else { return nil }
        let w = window(now: now)
        let result: Result<Decimal, ExchangeRateError>
        do {
            let (status, data) = try await client.get(url(now: now), headers: [:])
            result = status == 200 ? average(data, from: w.from, to: w.to) : .failure(.http(status))
        } catch {
            result = .failure(.http(0))
        }
        switch result {
        case .success(let rate):
            d.set("\(rate)", forKey: ProviderSettings.usdToCnyKey)
            d.set(now.timeIntervalSince1970, forKey: updatedAtKey)
            d.removeObject(forKey: failedAtKey)
            log("汇率已更新：近 7 天平均 ¥\(rate)")
            return rate
        case .failure:
            d.set(now.timeIntervalSince1970, forKey: failedAtKey)
            log("汇率更新失败，沿用 ¥\(ProviderSettings.load(d).usdToCny)")
            return nil
        }
    }

    /// 设置里汇率那一行下方的灰字。manual = 老用户手填过汇率（存着的值不是默认值；save 每次都会写这个键，不能只看键在不在）
    static func caption(rate: Decimal, updated: Date?, failedAt: Date?, manual: Bool,
                        now: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = L10n.isZh ? "MM-dd" : "MMM d"
        let failedLater = failedAt.map { fa in updated.map { fa > $0 } ?? true } ?? false
        if let u = updated {
            if failedLater && now.timeIntervalSince(u) > staleAfter { return L("fx.staleUsing", f.string(from: u)) }
            return L("fx.caption", f.string(from: u))
        }
        if failedLater { return L("fx.staleUsingRate", NSDecimalNumber(decimal: rate).stringValue) }
        return manual ? L("fx.manual") : L("fx.default")
    }

    static func caption(_ d: UserDefaults, now: Date) -> String {
        caption(rate: ProviderSettings.load(d).usdToCny, updated: lastUpdated(d), failedAt: lastFailed(d),
                manual: ProviderSettings.load(d).usdToCny != ProviderSettings().usdToCny, now: now)
    }
}
