import Foundation

/// PackyAPI（new-api v1.0.253 中转站）：控制台「系统访问令牌」+ 用户 ID 读整个账户（用户 11/9 选甲）。
/// 只用 API Key 读不到账户余额：Key 设了无限额度时 /v1/dashboard/billing/subscription 固定给 1 亿。
/// 接口以 2026-11-09 控制台页面实际请求为准：
/// - GET /api/status（公开）→ data.quota_per_unit（每「美元」多少额度，500000）、data.price（每「美元」充值多少人民币，1）
/// - GET /api/user/self → data.quota（账户余额，额度单位）
/// - GET /api/log/self/stat?type=2&start_timestamp&end_timestamp → data.quota（时间段内花费，实时）
/// - GET /api/data/self?start_timestamp&end_timestamp → [{model_name, created_at（整点）, token_used, count, quota}]
///   （按小时 × 模型汇总，几分钟落一次库；只拉近 7 天，画趋势和今日按模型）
/// 控制台接口都要带 New-Api-User 头（= 用户 ID），不带会被 Cloudflare 直接 403 成 HTML 页。
/// 金额按人民币显示（用户 11/9：充的是人民币就按人民币）：元 = 额度 ÷ quota_per_unit × price。
/// 站点自己按美元写（$1 = 1 单位），充值记录 ¥100 到账 100 单位，和 price = 1 一致
struct PackyAPIProvider: UsageProvider {
    let http: HTTPClient
    /// 换算比例（/api/status 22KB，不必每轮都拉）；同一个 Provider 实例在 App 运行期间一直用
    private let rate = PackyRateCache()
    init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    var id: ProviderID { .packyapi }
    var capabilities: Capabilities { ProviderRegistry.capabilities(.packyapi) }

    static let base = "https://www.packyapi.ai"
    /// 明细只拉近几天（本地日界，含今天）：够画 7 日趋势和今日按模型；今日 / 本月花费走 stat 接口
    static let detailDays = 7
    /// 换算比例多久重新拉一次
    static let rateMaxAge: TimeInterval = 6 * 3600

    // MARK: - 校验

    func validate(_ c: Credentials) async -> ValidationResult {
        switch session(c) {
        case .failure(let e): return .failed(e)
        case .success(let s):
            switch await balance(s, now: Date()) {
            case .success(let (m, _)): return .ok(summary: L("provider.connectedBalance", DeepSeekProvider.fmt2(m.amount)))
            case .failure(let e): return .failed(e)
            }
        }
    }

    // MARK: - 取数

    func fetch(_ c: Credentials, now: Date, timeZone: TimeZone) async -> Result<ProviderSnapshot, ProviderError> {
        let s: Session
        switch session(c) {
        case .success(let v): s = v
        case .failure(let e): return .failure(e)
        }
        let bal: Money, perUnit: Decimal
        switch await balance(s, now: now) {
        case .success(let v): (bal, perUnit) = v
        case .failure(let e): return .failure(e)
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let today0 = cal.startOfDay(for: now)
        let month0 = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? today0
        let end = Int(now.timeIntervalSince1970)
        func sec(_ d: Date) -> Int { Int(d.timeIntervalSince1970) }

        let today: Decimal, month: Decimal
        switch await stat(s, start: sec(today0), end: end) {
        case .success(let q): today = q * perUnit
        case .failure(let e): return .failure(e)
        }
        switch await stat(s, start: sec(month0), end: end) {
        case .success(let q): month = q * perUnit
        case .failure(let e): return .failure(e)
        }
        let detail0 = cal.date(byAdding: .day, value: -(Self.detailDays - 1), to: today0) ?? today0
        let rows: [Row]
        switch await getJSON(s, "/api/data/self?start_timestamp=\(sec(detail0))&end_timestamp=\(end)") {
        case .success(let obj):
            switch Self.parseRows(obj) {
            case .success(let v): rows = v
            case .failure(let e): return .failure(e)
            }
        case .failure(let e): return .failure(e)
        }

        // 明细（近 7 天）→ 本地日桶（31 天，末 7 天做趋势）+ 今日按模型
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        let span = 31
        var days: [DayUsage] = []
        for i in stride(from: span - 1, through: 0, by: -1) {
            let d = cal.date(byAdding: .day, value: -i, to: today0) ?? today0
            days.append(DayUsage(day: fmt.string(from: d), tokens: 0, cost: Money(amount: 0, currency: .cny)))
        }
        var dayIndex: [String: Int] = [:]
        for (i, d) in days.enumerated() { dayIndex[d.day] = i }
        var perDay: [[String: ModelUsage]] = Array(repeating: [:], count: span)
        for r in rows {
            guard let i = dayIndex[fmt.string(from: Date(timeIntervalSince1970: TimeInterval(r.at)))] else { continue }
            let cost = r.quota * perUnit
            days[i].tokens += r.tokens
            days[i].cost!.amount += cost
            // 只有总 token（不分输入 / 输出 / 缓存），和硅基流动一样记在 output 上
            var m = perDay[i][r.model] ?? ModelUsage(model: r.model, cacheHit: 0, cacheMiss: 0, output: 0, requests: 0,
                                                     cost: Money(amount: 0, currency: .cny))
            m.output += r.tokens; m.requests += r.count
            m.cost!.amount += cost
            perDay[i][r.model] = m
        }
        for i in 0..<span { days[i].models = perDay[i].values.sorted { $0.model < $1.model } }

        let monthKey = String(fmt.string(from: now).prefix(7))
        let byModel = perDay[span - 1].values.sorted { $0.output != $1.output ? $0.output > $1.output : $0.model < $1.model }
        return .success(ProviderSnapshot(
            provider: .packyapi, balance: bal,
            today: Money(amount: today, currency: .cny), month: Money(amount: month, currency: .cny),
            byModel: byModel, trend7: Array(days.suffix(7)), source: .bill, fetchedAt: now, credential: .ok,
            monthByModel: ProviderSnapshot.monthByModel(days, month: monthKey),
            monthByModelPartial: detail0 > month0 ? true : nil))
    }

    // MARK: - 请求

    struct Session {
        var headers: [String: String]
    }

    /// session() 本地判出的凭据问题（不用发请求）；验证文案照实显示这几句
    static var localCredentialProblems: [String] { [L("packy.noToken"), L("packy.badUserId")] }

    /// 凭据 → 请求头。用户 ID 只能是数字（New-Api-User 头不对时 Cloudflare 会拦）
    func session(_ c: Credentials) -> Result<Session, ProviderError> {
        let token = (c.values["accessToken"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let user = (c.values["userId"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure(.auth(L("packy.noToken"))) }
        guard !user.isEmpty, user.allSatisfy(\.isASCII), user.allSatisfy(\.isNumber) else {
            return .failure(.auth(L("packy.badUserId")))
        }
        return .success(Session(headers: ["Authorization": "Bearer \(token)", "New-Api-User": user,
                                          "Accept": "application/json"]))
    }

    /// 账户余额（元）和这次用的换算比例（每额度单位多少元）
    private func balance(_ s: Session, now: Date) async -> Result<(Money, Decimal), ProviderError> {
        let perUnit: Decimal
        switch await ratio(now: now) {
        case .success(let v): perUnit = v
        case .failure(let e): return .failure(e)
        }
        switch await getJSON(s, "/api/user/self") {
        case .failure(let e): return .failure(e)
        case .success(let obj):
            guard let d = obj["data"] as? [String: Any], let q = Self.number(d["quota"]) else {
                return .failure(.schemaChanged("PackyAPI /api/user/self 响应里 data.quota 缺失或不是数字"))
            }
            return .success((Money(amount: q * perUnit, currency: .cny), perUnit))
        }
    }

    /// 每额度单位多少元：缓存过期就重拉；重拉失败但有旧值时沿用旧值
    private func ratio(now: Date) async -> Result<Decimal, ProviderError> {
        if let v = rate.get(now: now, maxAge: Self.rateMaxAge) { return .success(v) }
        let fetched: Result<Decimal, ProviderError>
        switch await getJSON(nil, "/api/status") {
        case .success(let obj): fetched = Self.parseRatio(obj)
        case .failure(let e): fetched = .failure(e)
        }
        switch fetched {
        case .success(let v): rate.set(v, at: now); return .success(v)
        case .failure(let e):
            if case .rateLimited = e { return .failure(e) }
            if let old = rate.get(now: now, maxAge: .infinity) { return .success(old) }
            return .failure(e)
        }
    }

    /// 时间段内花费（额度单位）
    private func stat(_ s: Session, start: Int, end: Int) async -> Result<Decimal, ProviderError> {
        switch await getJSON(s, "/api/log/self/stat?type=2&start_timestamp=\(start)&end_timestamp=\(end)") {
        case .failure(let e): return .failure(e)
        case .success(let obj):
            guard let d = obj["data"] as? [String: Any], let q = Self.number(d["quota"]) else {
                return .failure(.schemaChanged("PackyAPI /api/log/self/stat 响应里 data.quota 缺失或不是数字"))
            }
            return .success(q)
        }
    }

    /// GET 一个控制台接口，返回 success 为 true 的 JSON 对象。session 为 nil 时不带凭据（/api/status 是公开的）
    private func getJSON(_ s: Session?, _ path: String) async -> Result<[String: Any], ProviderError> {
        let status: Int, data: Data
        do {
            (status, data) = try await http.get(URL(string: Self.base + path)!,
                                                headers: s?.headers ?? ["Accept": "application/json"])
        } catch { return .failure(.network(error.localizedDescription)) }
        return Self.envelope(status: status, data: data, path: path)
    }

    // MARK: - 解析（纯函数，测试直接喂样本）

    /// 统一处理 HTTP 状态和 new-api 的 {"success":…,"message":…,"data":…} 外壳。
    /// 令牌无效时 new-api 回 HTTP 200 + success=false（「无权进行此操作，access token 无效」）；
    /// Cloudflare 拦截是 403 + HTML，不是凭据问题。不回显服务端原文，避免带出凭据
    static func envelope(status: Int, data: Data, path: String) -> Result<[String: Any], ProviderError> {
        let name = path.split(separator: "?").first.map(String.init) ?? path
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 403 && obj == nil { return .failure(.network("PackyAPI \(name) HTTP 403（Cloudflare 拦截）")) }
        if let e = DeepSeekProvider.httpError(status) { return .failure(e) }
        // 200 但回的是网页（公共 Wi-Fi 登录页、代理出错页）：是网络问题，不是接口变了
        if obj == nil, data.first.map({ $0 == UInt8(ascii: "<") }) == true {
            return .failure(.network("PackyAPI \(name) 回的是网页，不是 JSON"))
        }
        guard let obj else { return .failure(.schemaChanged("PackyAPI \(name) 响应不是 JSON 对象")) }
        if obj["success"] as? Bool == false {
            let message = (obj["message"] as? String ?? "").lowercased()
            let auth = ["无权", "未登录", "access token", "new-api-user", "封禁", "unauthorized"].contains { message.contains($0) }
            return .failure(auth ? .auth("PackyAPI \(name) 拒绝了访问令牌") : .network("PackyAPI \(name) 返回 success=false"))
        }
        return .success(obj)
    }

    /// /api/status → 每额度单位多少元 = price ÷ quota_per_unit
    static func parseRatio(_ obj: [String: Any]) -> Result<Decimal, ProviderError> {
        guard let d = obj["data"] as? [String: Any], let perUnit = number(d["quota_per_unit"]), perUnit > 0,
              let price = number(d["price"]), price > 0 else {
            return .failure(.schemaChanged("PackyAPI /api/status 响应里 quota_per_unit / price 缺失或不是正数"))
        }
        return .success(price / perUnit)
    }

    struct Row: Equatable {
        var model: String
        /// 整点（Unix 秒）
        var at: Int
        var tokens: Int
        var count: Int
        /// 额度单位
        var quota: Decimal
    }

    /// /api/data/self → 明细行。没有数据时 data 可能是 null 或空数组
    static func parseRows(_ obj: [String: Any]) -> Result<[Row], ProviderError> {
        if obj["data"] == nil || obj["data"] is NSNull { return .success([]) }
        guard let list = obj["data"] as? [[String: Any]] else {
            return .failure(.schemaChanged("PackyAPI /api/data/self 响应里 data 不是数组"))
        }
        var out: [Row] = []
        for r in list {
            guard let model = r["model_name"] as? String, let at = number(r["created_at"]), let q = number(r["quota"]) else {
                return .failure(.schemaChanged("PackyAPI /api/data/self 明细缺 model_name / created_at / quota"))
            }
            out.append(Row(model: model, at: NSDecimalNumber(decimal: at).intValue,
                           tokens: number(r["token_used"]).map { NSDecimalNumber(decimal: $0).intValue } ?? 0,
                           count: number(r["count"]).map { NSDecimalNumber(decimal: $0).intValue } ?? 0,
                           quota: q))
        }
        return .success(out)
    }

    /// 只认 JSON 数字（布尔值也是 NSNumber，要排除）
    static func number(_ v: Any?) -> Decimal? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return Decimal(string: n.stringValue)
    }
}

/// PackyAPI 换算比例缓存（Provider 是值类型，拷贝之间共用这一份）。@unchecked Sendable：只在锁里读写
final class PackyRateCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (value: Decimal, at: Date)?
    func get(now: Date, maxAge: TimeInterval) -> Decimal? {
        lock.withLock { stored.flatMap { now.timeIntervalSince($0.at) <= maxAge ? $0.value : nil } }
    }
    func set(_ v: Decimal, at: Date) { lock.withLock { stored = (v, at) } }
}
