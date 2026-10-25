import Foundation

/// 硅基流动：官方余额接口已下线，改用网页控制台的内部接口（会话 cookie + subject id）。
/// 请求形状照搬 providers.py（_sf_*），业务成功码 20000。
struct SiliconFlowProvider: UsageProvider {
    let http: HTTPClient
    /// 明细每页条数（正式用 100；测试样本是 2）
    let pageSize: Int
    init(http: HTTPClient = URLSessionHTTPClient(), pageSize: Int = 100) {
        self.http = http
        self.pageSize = pageSize
    }

    var id: ProviderID { .siliconflow }
    var displayName: String { L("provider.siliconflow") }
    var capabilities: Capabilities {
        Capabilities(hasBalance: true, currency: .cny, minPollInterval: 60, dayBoundary: .local)
    }
    var loginSteps: [LoginStep] { [.webLogin(url: Self.consoleURL, required: true)] }

    static let consoleURL = URL(string: "https://cloud.siliconflow.cn/me/bills")!
    static let walletURL = "https://walletd.siliconflow.cn/api/v1/subject/profile"
    static let aggregateURL = "https://bill.siliconflow.cn/api/v1/bill/aggregate_amount"
    static let itemsURL = "https://bill.siliconflow.cn/api/v1/bill/items"
    /// 明细页数上限：真实明细约 5 分钟一行（每模型每计费项），一个模型一周约 4000 行（整分支评审 I-2）
    static let maxPages = 50
    /// 明细只拉近几天（本地日界，含今天）：够画 7 日趋势和今日按模型；本月花费走汇总接口
    static let detailDays = 7
    static var loginExpired: String { L("siliconflow.loginExpired") }
    static let userAgent = DeepSeekProvider.userAgent

    // MARK: - 校验

    func validate(_ c: Credentials) async -> ValidationResult {
        switch await fetchBalance(c, now: Date()) {
        case .success(let m): return .ok(summary: L("provider.connectedBalance", DeepSeekProvider.fmt2(m.amount)))
        case .failure(let e): return .failed(e)
        }
    }

    func fetchBalance(_ c: Credentials, now: Date) async -> Result<Money, ProviderError> {
        switch await session(c, now: now) {
        case .failure(let e): return .failure(e)
        case .success(let s): return await wallet(s)
        }
    }

    // MARK: - 取数

    func fetch(_ c: Credentials, now: Date, timeZone: TimeZone) async -> Result<ProviderSnapshot, ProviderError> {
        let s: Session
        switch await session(c, now: now) {
        case .success(let v): s = v
        case .failure(let e): return .failure(e)
        }
        let balance: Money
        switch await wallet(s) {
        case .success(let m): balance = m
        case .failure(let e): return .failure(e)
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let today0 = cal.startOfDay(for: now)
        let month0 = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? today0
        func ms(_ d: Date) -> Int { Int((d.timeIntervalSince1970 * 1000).rounded(.down)) }
        let endMs = ms(now)

        let today: Decimal, month: Decimal
        switch await aggregate(s, startMs: ms(today0), endMs: endMs) {
        case .success(let v): today = v
        case .failure(let e): return .failure(e)
        }
        switch await aggregate(s, startMs: ms(month0), endMs: endMs) {
        case .success(let v): month = v
        case .failure(let e): return .failure(e)
        }
        let detail0 = cal.date(byAdding: .day, value: -(Self.detailDays - 1), to: today0) ?? today0
        let items: [Item], truncated: Bool
        switch await billItems(s, startMs: ms(detail0), endMs: endMs) {
        case .success(let v): (items, truncated) = v
        case .failure(let e): return .failure(e)
        }

        // 明细（近 7 天）→ 按模型累计 + 本地日桶（31 天，末 7 天做趋势）
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
        func add(_ it: Item, to m: inout ModelUsage) {
            m.output += it.usage; m.requests += 1
            m.cost = Money(amount: (m.cost?.amount ?? 0) + it.cost, currency: .cny)
        }
        for it in items {
            let key = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(it.at) / 1000))
            guard let i = dayIndex[key] else { continue }
            days[i].tokens += it.usage
            days[i].cost!.amount += it.cost
            var m = perDay[i][it.model] ?? Self.blank(it.model)
            add(it, to: &m)
            perDay[i][it.model] = m
        }
        for i in 0..<span { days[i].models = perDay[i].values.sorted { $0.model < $1.model } }

        let monthKey = String(fmt.string(from: now).prefix(7))
        // byModel 是今日（与 DeepSeek 一致，界面拿它算今日 token 和各模型今日花费）；本月见 monthByModel
        let byModel = perDay[span - 1].values.sorted { $0.output != $1.output ? $0.output > $1.output : $0.model < $1.model }
        return .success(ProviderSnapshot(
            provider: .siliconflow, balance: balance,
            today: Money(amount: today, currency: .cny), month: Money(amount: month, currency: .cny),
            byModel: byModel, trend7: Array(days.suffix(7)), source: .bill, fetchedAt: now,
            credential: s.credential, monthByModel: ProviderSnapshot.monthByModel(days, month: monthKey),
            detailTruncated: truncated ? true : nil,
            monthByModelPartial: truncated || detail0 > month0 ? true : nil))
    }

    // MARK: - 会话（cookie、subject id、到期）

    struct Session {
        var headers: [String: String]
        var credential: CredentialState
    }

    func session(_ c: Credentials, now: Date) async -> Result<Session, ProviderError> {
        guard let token = c.values["webToken"], !token.isEmpty else {
            return .failure(.auth(Self.loginExpired))
        }
        // 会话到期时间（Unix 秒，可缺）：已过期 → 登录失效；≤ 3 天 → 提前提醒
        var credential = CredentialState.ok
        if let raw = c.values["webTokenExpiresAt"], let exp = Double(raw) {
            let remain = exp - now.timeIntervalSince1970
            if remain <= 0 { return .failure(.auth(L("siliconflow.loginExpiredPast"))) }
            if remain <= 3 * 86400 { credential = .expiring(days: Int(remain / 86400)) }
        }
        let cookie = "__SF_auth.session-token=\(token)"
        var sid = c.values["subjectId"] ?? ""
        if sid.isEmpty {
            // 凭据里没有：用登录态抓一次控制台页面解析
            let status: Int, data: Data
            do {
                (status, data) = try await http.get(Self.consoleURL, headers: [
                    "Cookie": cookie, "Accept": "text/html", "User-Agent": Self.userAgent])
            } catch { return .failure(.network(error.localizedDescription)) }
            if let e = DeepSeekProvider.httpError(status) { return .failure(e) }
            guard let html = String(data: data, encoding: .utf8), let found = Self.parseSubjectId(html: html) else {
                return .failure(.auth(Self.loginExpired))
            }
            sid = found
        }
        return .success(Session(headers: [
            "Cookie": cookie, "X-Subject-Id": sid, "Accept": "application/json, text/plain, */*",
            "accept-language": "zh-CN", "Origin": "https://cloud.siliconflow.cn",
            "Referer": Self.consoleURL.absoluteString, "User-Agent": Self.userAgent], credential: credential))
    }

    static func parseSubjectId(html: String) -> String? {
        guard let r = html.range(of: #"SF_SUBJECT_ID\s*=\s*'([^']+)'"#, options: .regularExpression) else { return nil }
        let hit = String(html[r])
        guard let a = hit.firstIndex(of: "'"), let b = hit.lastIndex(of: "'"), a < b else { return nil }
        return String(hit[hit.index(after: a)..<b])
    }

    // MARK: - 接口

    /// GET 并校验：HTTP 状态、JSON、业务码 20000（其余业务码按登录失效），返回 data
    func api(_ s: Session, _ urlString: String, query: [URLQueryItem] = []) async -> Result<[String: Any], ProviderError> {
        var comps = URLComponents(string: urlString)!
        if !query.isEmpty { comps.queryItems = query }
        let status: Int, data: Data
        do { (status, data) = try await http.get(comps.url!, headers: s.headers) }
        catch { return .failure(.network(error.localizedDescription)) }
        if let e = DeepSeekProvider.httpError(status) { return .failure(e) }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.schemaChanged("硅基流动响应不是 JSON"))
        }
        let code = (obj["code"] as? NSNumber)?.intValue
        if code != 20000 { return code == nil ? .failure(.schemaChanged("硅基流动响应没有 code")) : .failure(.auth("硅基流动 code=\(code!)")) }
        guard let d = obj["data"] as? [String: Any] else { return .failure(.schemaChanged("硅基流动响应没有 data")) }
        return .success(d)
    }

    func wallet(_ s: Session) async -> Result<Money, ProviderError> {
        switch await api(s, Self.walletURL) {
        case .failure(let e): return .failure(e)
        case .success(let d):
            guard let fin = d["financialInfo"] as? [String: Any], let amount = DeepSeekProvider.decStrict(fin["balance"]) else {
                return .failure(.schemaChanged("钱包响应里 financialInfo.balance 缺失或不是数字"))
            }
            // 余额是整数字符串，单位 10^-12 元
            return .success(Money(amount: amount / Decimal(sign: .plus, exponent: 12, significand: 1),
                                  currency: .cny))
        }
    }

    /// 汇总接口 netAmount（只到分）
    func aggregate(_ s: Session, startMs: Int, endMs: Int) async -> Result<Decimal, ProviderError> {
        switch await api(s, Self.aggregateURL, query: [URLQueryItem(name: "startTime", value: "\(startMs)"),
                                                       URLQueryItem(name: "endTime", value: "\(endMs)")]) {
        case .failure(let e): return .failure(e)
        case .success(let d):
            guard let amount = DeepSeekProvider.decStrict(d["netAmount"]) else {
                return .failure(.schemaChanged("汇总响应里 netAmount 缺失或不是数字"))
            }
            return .success(amount)
        }
    }

    struct Item { var model: String; var usage: Int; var cost: Decimal; var at: Int }

    /// 明细最多 maxPages 页；本页行数 < pageSize 或到最后一页即停。truncated = 到上限时还有没拉的页
    func billItems(_ s: Session, startMs: Int, endMs: Int) async -> Result<(items: [Item], truncated: Bool), ProviderError> {
        var out: [Item] = []
        for cur in 1...Self.maxPages {
            let q = [URLQueryItem(name: "startTime", value: "\(startMs)"), URLQueryItem(name: "endTime", value: "\(endMs)"),
                     URLQueryItem(name: "current", value: "\(cur)"), URLQueryItem(name: "pageSize", value: "\(pageSize)")]
            let d: [String: Any]
            switch await api(s, Self.itemsURL, query: q) {
            case .success(let v): d = v
            case .failure(let e): return .failure(e)
            }
            guard let rows = d["list"] as? [[String: Any]] else { return .failure(.schemaChanged("明细响应里没有 list")) }
            out += rows.map(Self.item)
            let pg = d["pagination"] as? [String: Any] ?? [:]
            // 真实响应只有 total（Task 10 录制），没有 pages：按 total / pageSize 向上取整
            var pages = DeepSeekProvider.int(pg["pages"] ?? pg["totalPages"])
            if pages == 0 {
                let size = max(DeepSeekProvider.int(pg["pageSize"]), pageSize, 1)
                pages = (DeepSeekProvider.int(pg["total"]) + size - 1) / size
            }
            pages = max(pages, 1)
            if rows.count < pageSize || cur >= pages { break }
            if cur == Self.maxPages { return .success((out, true)) }
        }
        return .success((out, false))
    }

    // MARK: - 纯函数

    static func blank(_ m: String) -> ModelUsage {
        ModelUsage(model: m, cacheHit: 0, cacheMiss: 0, output: 0, requests: 0, cost: nil)
    }

    /// 多语言名字段 {"zh-CN": "…"}：取中文
    static func cn(_ v: Any?) -> String {
        guard let s = v as? String else { return "" }
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("{"), let d = t.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return s }
        return (obj["zh-CN"] as? String) ?? (obj["zh-cn"] as? String) ?? (obj.values.first as? String) ?? s
    }

    static func item(_ r: [String: Any]) -> Item {
        let obj = cn(r["objectName"])
        return Item(model: modelName(obj), usage: DeepSeekProvider.int(r["grossUsage"]),
                    cost: DeepSeekProvider.dec(r["netAmount"]), at: DeepSeekProvider.int(r["incurredAt"] ?? r["createdAt"]))
    }

    /// objectName → 模型名。真实格式「模型.服务方式.计费项」，模型名自身可带点
    /// （qwen/qwen3-asr-1.7b.online.input-audio-seconds → qwen/qwen3-asr-1.7b）；
    /// 没有服务方式段时去掉最后一段计费项（test-model-a.输入 → test-model-a）
    static func modelName(_ obj: String) -> String {
        if let r = obj.range(of: #"\.(online|offline|batch)(\.|$)"#, options: .regularExpression) {
            return String(obj[..<r.lowerBound])
        }
        guard let dot = obj.lastIndex(of: ".") else { return obj }
        return String(obj[..<dot])
    }
}
