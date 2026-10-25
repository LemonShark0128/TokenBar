import Foundation

/// DeepSeek：官方 API Key 查余额；可选的网页控制台登录（userToken）解锁今日/本月账单与模型明细。
/// 控制台接口未公开，请求形状与错误约定照搬已验证的 token_board.py（2026-10-15），不要随意改。
struct DeepSeekProvider: UsageProvider {
    let http: HTTPClient
    init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    var id: ProviderID { .deepseek }
    var displayName: String { "DeepSeek" }
    var capabilities: Capabilities {
        Capabilities(hasBalance: true, currency: .cny, minPollInterval: 60, dayBoundary: .local)
    }
    var loginSteps: [LoginStep] {
        [.apiKey(required: true), .webLogin(url: URL(string: "https://platform.deepseek.com/sign_in")!, required: false)]
    }

    static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    static let platformBase = "https://platform.deepseek.com/api/v0"
    /// 控制台业务错误也走 HTTP 200：这些 code 或 msg 含 token/authoriz 都算登录失效
    static let authCodes: Set<Int> = [40001, 40002, 40003, 40004, 401, 403]
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36"

    // MARK: - 余额（官方接口）

    func validate(_ c: Credentials) async -> ValidationResult {
        switch await fetchBalance(c.values["apiKey"] ?? "") {
        case .success(let m): return .ok(summary: L("provider.connectedBalance", Self.fmt2(m.amount)))
        case .failure(let e): return .failed(e)
        }
    }

    func fetchBalance(_ apiKey: String) async -> Result<Money, ProviderError> {
        guard !apiKey.isEmpty else { return .failure(.auth(L("provider.noApiKey"))) }
        let status: Int, data: Data
        do {
            (status, data) = try await http.get(Self.balanceURL,
                                                headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"])
        } catch { return .failure(.network(error.localizedDescription)) }
        if let e = Self.httpError(status) { return .failure(e) }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let infos = obj["balance_infos"] as? [[String: Any]], !infos.isEmpty else {
            return .failure(.schemaChanged("余额响应里没有 balance_infos"))
        }
        let info = infos.first { ($0["currency"] as? String) == "CNY" } ?? infos[0]
        guard let amount = Self.decStrict(info["total_balance"]) else {
            return .failure(.schemaChanged("余额响应里 total_balance 缺失或不是数字"))
        }
        return .success(Money(amount: amount, currency: .cny))
    }

    // MARK: - 控制台账单

    func fetch(_ c: Credentials, now: Date, timeZone: TimeZone) async -> Result<ProviderSnapshot, ProviderError> {
        let balance: Money
        switch await fetchBalance(c.values["apiKey"] ?? "") {
        case .success(let m): balance = m
        case .failure(let e): return .failure(e)
        }
        var snap = ProviderSnapshot(provider: .deepseek, balance: balance, today: nil, month: nil,
                                    byModel: [], trend7: [], source: .balanceOnly, fetchedAt: now, credential: .ok)
        guard let token = c.values["webToken"], !token.isEmpty else { return .success(snap) }

        // 控制台出问题时：登录失效 → 提示重新登录；网络/限流 → 本轮失败（保留上次数据、按退避重试）；
        // 其余（认不出 Key、参数错误、格式变了）→ 降级为只有余额并说明原因，余额照常更新
        func degrade(_ e: ProviderError) -> Result<ProviderSnapshot, ProviderError> {
            switch e {
            case .auth: snap.consoleLoginNeeded = true
            case .network, .rateLimited: return .failure(e)
            case .unavailable(let why): snap.consoleProblem = why
            case .badRequest: snap.consoleProblem = L("deepseek.consoleBadRequest")
            case .schemaChanged: snap.consoleProblem = L("deepseek.consoleChanged")
            }
            return .success(snap)
        }

        if case .failure(let e) = await console(token, "users/get_user_summary") { return degrade(e) }

        let keysBiz: [String: Any]
        switch await console(token, "users/get_api_keys") {
        case .success(let b): keysBiz = b
        case .failure(let e): return degrade(e)
        }
        let rawKeys = (keysBiz["api_keys"] ?? keysBiz["apiKeys"]) as? [[String: Any]] ?? []
        let keys = rawKeys.map { (sensitiveId: $0["sensitive_id"] as? String ?? "",
                                  trackingId: $0["tracking_id"] as? String ?? "", name: $0["name"] as? String ?? "") }
        guard let tid = Self.matchKey(apiKey: c.values["apiKey"] ?? "", keys: keys) else {
            return degrade(.unavailable(L("deepseek.keyNotFound")))
        }

        // 长窗口取 31 天：31 号那天也能从 1 号算起「本月」，同时覆盖近 7 天
        let span = 31
        let tzSec = timeZone.secondsFromGMT(for: now)
        let w1 = Self.dayWindow(days: 1, tzSeconds: tzSec, now: now)
        let w30 = Self.dayWindow(days: span, tzSeconds: tzSec, now: now)
        func q(_ w: (start: Int, end: Int, tz: Int)) -> [URLQueryItem] {
            [URLQueryItem(name: "start", value: "\(w.start)"), URLQueryItem(name: "end", value: "\(w.end)"),
             URLQueryItem(name: "tz", value: "\(w.tz)"), URLQueryItem(name: "api_key_tracking_id", value: tid)]
        }
        var biz: [[String: Any]] = []
        for (path, w) in [("usage/by_api_key/amount", w1), ("usage/by_api_key/cost", w1),
                          ("usage/by_api_key/amount", w30), ("usage/by_api_key/cost", w30)] {
            switch await console(token, path, query: q(w)) {
            case .success(let b): biz.append(b)
            case .failure(let e): return degrade(e)
            }
        }
        let amountToday = Self.amountRows(biz[0]), costToday = Self.costRows(biz[1])
        let amount30 = Self.amountRows(biz[2]), cost30 = Self.costRows(biz[3])

        // 今日按模型
        var models: [String: ModelUsage] = [:]
        for r in amountToday {
            var m = models[r.model] ?? ModelUsage(model: r.model, cacheHit: 0, cacheMiss: 0, output: 0, requests: 0, cost: nil)
            m.cacheHit += r.hit; m.cacheMiss += r.miss; m.output += r.resp; m.requests += r.request
            models[r.model] = m
        }
        for r in costToday {
            var m = models[r.model] ?? ModelUsage(model: r.model, cacheHit: 0, cacheMiss: 0, output: 0, requests: 0, cost: nil)
            m.cost = Money(amount: (m.cost?.amount ?? 0) + r.cost, currency: .cny)
            models[r.model] = m
        }
        snap.byModel = models.values.filter(Self.used).sorted { ($0.cacheHit + $0.cacheMiss + $0.output) > ($1.cacheHit + $1.cacheMiss + $1.output) }
        snap.today = Money(amount: costToday.reduce(0) { $0 + $1.cost }, currency: .cny)

        // 31 天日桶 → 本月、近 7 天
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: tzSec)
        fmt.dateFormat = "yyyy-MM-dd"
        var days: [DayUsage] = (0..<span).map { i in
            DayUsage(day: fmt.string(from: Date(timeIntervalSince1970: TimeInterval(w30.start + i * 86400))),
                     tokens: 0, cost: Money(amount: 0, currency: .cny))
        }
        func index(_ t: Int) -> Int? { let i = (t - w30.start) / 86400; return (0..<span).contains(i) ? i : nil }
        var perDay: [[String: ModelUsage]] = Array(repeating: [:], count: span)
        func blank(_ m: String) -> ModelUsage { ModelUsage(model: m, cacheHit: 0, cacheMiss: 0, output: 0, requests: 0, cost: nil) }
        for r in amount30 {
            guard let i = index(r.time) else { continue }
            days[i].tokens += r.hit + r.miss + r.resp
            var m = perDay[i][r.model] ?? blank(r.model)
            m.cacheHit += r.hit; m.cacheMiss += r.miss; m.output += r.resp; m.requests += r.request
            perDay[i][r.model] = m
        }
        for r in cost30 {
            guard let i = index(r.time) else { continue }
            days[i].cost!.amount += r.cost
            var m = perDay[i][r.model] ?? blank(r.model)
            m.cost = Money(amount: (m.cost?.amount ?? 0) + r.cost, currency: .cny)
            perDay[i][r.model] = m
        }
        for i in 0..<span { days[i].models = perDay[i].values.filter(Self.used).sorted { $0.model < $1.model } }
        let month = String(fmt.string(from: now).prefix(7))
        snap.month = Money(amount: days.filter { $0.day.hasPrefix(month) }.reduce(0) { $0 + ($1.cost?.amount ?? 0) },
                           currency: .cny)
        snap.monthByModel = ProviderSnapshot.monthByModel(days, month: month)
        snap.trend7 = Array(days.suffix(7))
        snap.source = .bill
        return .success(snap)
    }

    /// 控制台 GET：返回 data.biz_data；HTTP 401/403、业务码或 msg 判为登录失效；biz_code ≠ 0 是参数错误
    func console(_ token: String, _ path: String, query: [URLQueryItem] = []) async -> Result<[String: Any], ProviderError> {
        var comps = URLComponents(string: "\(Self.platformBase)/\(path)")!
        if !query.isEmpty { comps.queryItems = query }
        let status: Int, data: Data
        do {
            (status, data) = try await http.get(comps.url!, headers: [
                "Authorization": "Bearer \(token)", "Accept": "application/json", "x-client-platform": "web",
                "Referer": "https://platform.deepseek.com/usage", "User-Agent": Self.userAgent])
        } catch { return .failure(.network(error.localizedDescription)) }
        if let e = Self.httpError(status) { return .failure(e) }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.schemaChanged("控制台响应不是 JSON"))
        }
        let code = (obj["code"] as? NSNumber)?.intValue ?? 0
        let msg = (obj["msg"] as? String ?? "").lowercased()
        if Self.authCodes.contains(code) || msg.contains("token") || msg.contains("authoriz") {
            return .failure(.auth("控制台 code=\(code)"))
        }
        let d = obj["data"] as? [String: Any] ?? [:]
        if let bc = (d["biz_code"] as? NSNumber)?.intValue, bc != 0 {
            return .failure(.badRequest("biz_code=\(bc) \(d["biz_msg"] as? String ?? "")"))
        }
        guard let bd = d["biz_data"] as? [String: Any] else { return .failure(.schemaChanged("控制台响应里没有 biz_data")) }
        return .success(bd)
    }

    // MARK: - 纯函数（有单测）

    /// 与站点前端一致：tz 抹到整小时，余数加到 start/end 上；窗口必须对齐到该时区 0 点，否则接口回 INVALID_PARAM
    static func dayWindow(days: Int, tzSeconds tz: Int, now: Date) -> (start: Int, end: Int, tz: Int) {
        let hour = 3600 * Int((Double(tz) / 3600).rounded(.down))
        let r = tz - hour
        let local = Int(now.timeIntervalSince1970) + tz
        let t0 = local - ((local % 86400) + 86400) % 86400 - tz      // 该时区今日 0 点的 epoch
        return (t0 - (days - 1) * 86400 + r, t0 + 86400 + r, hour)
    }

    /// 控制台只回掩码 Key：去掉 * 后前 5 位、后 4 位都对上即为同一把；对不上不按名字猜测
    static func matchKey(apiKey: String, keys: [(sensitiveId: String, trackingId: String, name: String)]) -> String? {
        for k in keys {
            let mask = k.sensitiveId.replacingOccurrences(of: "*", with: "")
            if mask.count >= 9, apiKey.count >= 9, mask.prefix(5) == apiKey.prefix(5), mask.suffix(4) == apiKey.suffix(4) {
                return k.trackingId
            }
        }
        return nil
    }

    /// localStorage.userToken 可能是 {"value":"…"} 包装，也可能是裸字符串
    static func extractUserToken(fromLocalStorageValue raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "null" { return nil }
        if s.hasPrefix("{"), let d = s.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            let v = obj["value"] as? String
            return (v?.isEmpty ?? true) ? nil : v
        }
        let unquoted = s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return unquoted.isEmpty ? nil : unquoted
    }

    /// 控制台对账号下所有模型都返回数据（没用过的全是 0）；有 token、请求或花费才算用过
    static func used(_ m: ModelUsage) -> Bool {
        m.cacheHit + m.cacheMiss + m.output + m.requests > 0 || (m.cost?.amount ?? 0) > 0
    }

    static func httpError(_ status: Int) -> ProviderError? {
        switch status {
        case 200: return nil
        case 401, 403: return .auth("HTTP \(status)")
        case 429: return .rateLimited(retryAfter: nil)
        default: return .network("HTTP \(status)")
        }
    }

    /// 金额必填字段：缺失或解析失败不能当作零。
    static func decStrict(_ v: Any?) -> Decimal? {
        if let s = v as? String { return Decimal(string: s) }
        if let n = v as? NSNumber { return Decimal(string: n.stringValue) }
        return nil
    }

    static func dec(_ v: Any?) -> Decimal {
        if let s = v as? String { return Decimal(string: s) ?? 0 }
        if let n = v as? NSNumber { return Decimal(string: n.stringValue) ?? 0 }
        return 0
    }
    static func int(_ v: Any?) -> Int { NSDecimalNumber(decimal: dec(v)).intValue }

    static func fmt2(_ d: Decimal) -> String { String(format: "%.2f", NSDecimalNumber(decimal: d).doubleValue) }

    struct AmountRow { var model: String; var time: Int; var request, hit, miss, resp: Int }
    struct CostRow { var model: String; var time: Int; var cost: Decimal }

    static func amountRows(_ bd: [String: Any]) -> [AmountRow] {
        var out: [AmountRow] = []
        for s in bd["series"] as? [[String: Any]] ?? [] {
            let model = s["model"] as? String ?? L("source.unknown")
            for b in s["buckets"] as? [[String: Any]] ?? [] {
                let u = b["usage"] as? [String: Any] ?? [:]
                out.append(AmountRow(model: model, time: int(b["time"]), request: int(u["REQUEST"]),
                                     hit: int(u["PROMPT_CACHE_HIT_TOKEN"]), miss: int(u["PROMPT_CACHE_MISS_TOKEN"]),
                                     resp: int(u["RESPONSE_TOKEN"])))
            }
        }
        return out
    }

    /// 只取 CNY
    static func costRows(_ bd: [String: Any]) -> [CostRow] {
        var out: [CostRow] = []
        for cur in bd["data"] as? [[String: Any]] ?? [] where (cur["currency"] as? String ?? "CNY").uppercased() == "CNY" {
            for s in cur["series"] as? [[String: Any]] ?? [] {
                let model = s["model"] as? String ?? L("source.unknown")
                for b in s["buckets"] as? [[String: Any]] ?? [] {
                    out.append(CostRow(model: model, time: int(b["time"]), cost: dec(b["cost"])))
                }
            }
        }
        return out
    }
}
