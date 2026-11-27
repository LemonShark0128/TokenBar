import Foundation

/// OpenRouter：普通 API Key，金额单位美元（credits）。字段以官方文档为准（2026-11-06 核对）：
/// - GET https://openrouter.ai/api/v1/key（Bearer）→ data.usage_daily / usage_monthly（UTC 当日 / 当月花费）、
///   limit / limit_remaining（Key 的花费上限，无上限时为 null）。https://openrouter.ai/docs/api/api-reference/api-keys/get-current-key
/// - GET https://openrouter.ai/api/v1/credits → data.total_credits - total_usage = 账户余额。官方写明要 Management Key，
///   普通 Key 返回 403（第三方说普通 Key 也行）：两种都兼容。403 不算失败，余额退回 Key 剩余上限，再没有就不显示；
///   偶尔出错（5xx / 断网 / 格式不对）沿用上次读到的账户余额，免得在账户余额和 Key 上限之间来回跳。
///   https://openrouter.ai/docs/api/api-reference/credits/get-credits
/// - 两个接口都有按 IP 的突发限流（不带 X-RateLimit 头）：任一个 429 都整次返回 .rateLimited，由 UsageStore 翻倍退避。
///   https://openrouter.ai/docs/api/reference/limits
/// 今日 / 本月花费直接用接口给的数（不按余额差估算，是这把 Key 的花费）；没有逐日账单和按模型 / token 明细，
/// 日均用本周 / 本月累计 ÷ UTC 已过天数（取覆盖天数多的那个）
struct OpenRouterProvider: UsageProvider {
    let http: HTTPClient
    /// 上次读到的账户余额（/credits 偶尔出错时沿用）；同一个 Provider 实例在 App 运行期间一直用
    private let lastAccount = LastAccountBalance()
    init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    var id: ProviderID { .openrouter }
    var capabilities: Capabilities { ProviderRegistry.capabilities(.openrouter) }

    static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!
    static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!

    struct KeyInfo: Equatable {
        var today: Money
        var month: Money
        /// 本周（UTC 周一起）累计；接口没给为 nil
        var week: Money?
        /// Key 剩余花费上限；Key 没设上限为 nil
        var limitRemaining: Money?
    }

    func validate(_ c: Credentials) async -> ValidationResult {
        switch await read(c) {
        case .success(let (key, account)):
            let fmt = { (m: Money) in DeepSeekProvider.fmt2(m.amount) }
            let balance = Self.spendable(account: account, keyLimit: key.limitRemaining)
            if let balance {
                let keyLimit = Self.showsKeyLimit(account: account, keyLimit: key.limitRemaining)
                return .ok(summary: L(keyLimit ? "provider.connectedKeyLimitUsd" : "provider.connectedBalanceUsd", fmt(balance)))
            }
            return .ok(summary: L("provider.connectedMonthUsd", fmt(key.month)))
        case .failure(let e): return .failed(e)
        }
    }

    func fetch(_ c: Credentials, now: Date, timeZone: TimeZone) async -> Result<ProviderSnapshot, ProviderError> {
        switch await read(c) {
        case .failure(let e): return .failure(e)
        case .success(let (key, account)):
            var s = ProviderSnapshot(provider: .openrouter, balance: Self.spendable(account: account, keyLimit: key.limitRemaining),
                                     today: key.today, month: key.month, byModel: [], trend7: [], source: .bill,
                                     fetchedAt: now, credential: .ok)
            s.dailyAverage = Self.dailyAverage(key, now: now)
            if Self.showsKeyLimit(account: account, keyLimit: key.limitRemaining) { s.balanceIsKeyLimit = true }
            return .success(s)
        }
    }

    /// 能花的钱：账户余额和 Key 剩余上限取小的；只有一个就用那一个
    static func spendable(account: Money?, keyLimit: Money?) -> Money? {
        switch (account, keyLimit) {
        case let (a?, l?): return a.amount <= l.amount ? a : l
        case let (a?, nil): return a
        case let (nil, l?): return l
        case (nil, nil): return nil
        }
    }

    /// spendable 选中的是 Key 剩余上限（没有账户余额，或 Key 上限比账户余额小）
    static func showsKeyLimit(account: Money?, keyLimit: Money?) -> Bool {
        guard let l = keyLimit else { return false }
        return account.map { l.amount < $0.amount } ?? true
    }

    /// 日均：本周累计 ÷ 本周已过天数、本月累计 ÷ 本月已过天数（都按 UTC、今天按一整天算，UTC 当天早些时候会偏低一点），
    /// 取覆盖天数多的那个
    static func dailyAverage(_ k: KeyInfo, now: Date) -> DailyAverage {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let monthDays = cal.component(.day, from: now)
        let weekDays = (cal.component(.weekday, from: now) + 5) % 7 + 1     // 周一 = 1 … 周日 = 7
        if let week = k.week, weekDays > monthDays {
            return DailyAverage(perDay: week.amount / Decimal(weekDays), days: weekDays)
        }
        return DailyAverage(perDay: k.month.amount / Decimal(monthDays), days: monthDays)
    }

    /// 读 /key 和 /credits：返回 Key 信息和账户余额（读不到为 nil）
    private func read(_ c: Credentials) async -> Result<(KeyInfo, Money?), ProviderError> {
        let apiKey = c.values["apiKey"] ?? ""
        guard !apiKey.isEmpty else { return .failure(.auth(L("provider.noApiKey"))) }
        let headers = ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"]

        let key: KeyInfo
        switch await get(Self.keyURL, headers) {
        case .failure(let e): return .failure(e)
        case .success(let (status, data)):
            if let e = DeepSeekProvider.httpError(status) { return .failure(e) }
            switch Self.parseKey(data) {
            case .success(let k): key = k
            case .failure(let e): return .failure(e)
            }
        }

        // 账户余额拿不到都不算失败：403（普通 Key）= 确定读不到；其他出错沿用上次读到的。只有限流要退避
        switch await get(Self.creditsURL, headers) {
        case .success((429, _)): return .failure(.rateLimited)
        case .success((403, _)): lastAccount.set(nil, for: apiKey)
        case .success((200, let data)):
            if case .success(let m) = Self.parseCredits(data) { lastAccount.set(m, for: apiKey) }
        default: break
        }
        return .success((key, lastAccount.get(for: apiKey)))
    }

    private func get(_ url: URL, _ headers: [String: String]) async -> Result<(Int, Data), ProviderError> {
        do { return .success(try await http.get(url, headers: headers)) }
        catch { return .failure(.network(error.localizedDescription)) }
    }

    /// 解析 /key 响应（纯函数）。花费字段缺失或不是数字判格式变化，不能当 0
    static func parseKey(_ data: Data) -> Result<KeyInfo, ProviderError> {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let d = obj["data"] as? [String: Any] else {
            return .failure(.schemaChanged("OpenRouter /key 响应里没有 data 对象"))
        }
        guard let daily = number(d["usage_daily"]), let monthly = number(d["usage_monthly"]) else {
            return .failure(.schemaChanged("OpenRouter /key 响应里 usage_daily / usage_monthly 缺失或不是数字"))
        }
        // Key 没设上限时 limit / limit_remaining 都是 null
        let remaining = number(d["limit_remaining"])
        return .success(KeyInfo(today: Money(amount: daily, currency: .usd), month: Money(amount: monthly, currency: .usd),
                                week: number(d["usage_weekly"]).map { Money(amount: $0, currency: .usd) },
                                limitRemaining: remaining.map { Money(amount: max(0, $0), currency: .usd) }))
    }

    /// 解析 /credits 响应：余额 = 总充值 - 总用量
    static func parseCredits(_ data: Data) -> Result<Money, ProviderError> {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let total = number(d["total_credits"]), let used = number(d["total_usage"]) else {
            return .failure(.schemaChanged("OpenRouter /credits 响应里 total_credits / total_usage 缺失或不是数字"))
        }
        return .success(Money(amount: total - used, currency: .usd))
    }

    /// 只认 JSON 数字（布尔值也是 NSNumber，要排除）
    private static func number(_ v: Any?) -> Decimal? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return Decimal(string: n.stringValue)
    }
}

/// 上次读到的 OpenRouter 账户余额（Provider 是值类型，拷贝之间共用这一份）。只对读到它的那把 Key 有效：
/// 换了 Key（可能是别的账户）就不沿用。@unchecked Sendable：只在锁里读写
final class LastAccountBalance: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (apiKey: String, balance: Money)?
    func get(for apiKey: String) -> Money? {
        lock.withLock { stored?.apiKey == apiKey ? stored?.balance : nil }
    }
    func set(_ balance: Money?, for apiKey: String) {
        lock.withLock { stored = balance.map { (apiKey, $0) } }
    }
}
