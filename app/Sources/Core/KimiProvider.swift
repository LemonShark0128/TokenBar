import Foundation

/// Kimi（月之暗面开放平台，国内站）：官方 API Key 查余额，单位人民币元。
/// 接口：GET https://api.moonshot.cn/v1/users/me/balance（Authorization: Bearer <Key>），
/// 返回 {"code":0,"data":{"available_balance":…,"voucher_balance":…,"cash_balance":…},"scode":"0x0","status":true}。
/// available_balance = 现金 + 代金券（现金欠费为负时等于代金券），≤ 0 时不能再调用推理接口——油箱按它画。
/// 没有今日 / 本月账单接口：今日花费和续航由余额样本推算（同 DeepSeek 未登录控制台）
struct KimiProvider: UsageProvider {
    let http: HTTPClient
    init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    var id: ProviderID { .kimi }
    var capabilities: Capabilities { ProviderRegistry.capabilities(.kimi) }

    static let balanceURL = URL(string: "https://api.moonshot.cn/v1/users/me/balance")!

    func validate(_ c: Credentials) async -> ValidationResult {
        switch await fetchBalance(c.values["apiKey"] ?? "") {
        case .success(let m): return .ok(summary: L("provider.connectedBalance", DeepSeekProvider.fmt2(m.amount)))
        case .failure(let e): return .failed(e)
        }
    }

    func fetch(_ c: Credentials, now: Date, timeZone: TimeZone) async -> Result<ProviderSnapshot, ProviderError> {
        switch await fetchBalance(c.values["apiKey"] ?? "") {
        case .success(let m):
            return .success(ProviderSnapshot(provider: .kimi, balance: m, today: nil, month: nil, byModel: [], trend7: [],
                                             source: .balanceOnly, fetchedAt: now, credential: .ok))
        case .failure(let e): return .failure(e)
        }
    }

    func fetchBalance(_ apiKey: String) async -> Result<Money, ProviderError> {
        guard !apiKey.isEmpty else { return .failure(.auth(L("provider.noApiKey"))) }
        let status: Int, data: Data
        do {
            (status, data) = try await http.get(Self.balanceURL,
                                                headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"])
        } catch { return .failure(.network(error.localizedDescription)) }
        if let e = DeepSeekProvider.httpError(status) { return .failure(e) }
        return Self.parseBalance(data)
    }

    /// 解析余额响应（纯函数，测试直接喂样本）
    static func parseBalance(_ data: Data) -> Result<Money, ProviderError> {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.schemaChanged("Kimi 余额响应不是 JSON 对象"))
        }
        // 业务失败也可能走 HTTP 200：code 非 0 或 status 为 false
        let code = (obj["code"] as? NSNumber)?.intValue
        if (code != nil && code != 0) || (obj["status"] as? Bool == false) {
            let message = [obj["message"], obj["error"]].compactMap { $0 }.map { String(describing: $0) }.joined(separator: " ").lowercased()
            let auth = code == 401 || code == 403 || ["auth", "key", "token"].contains { message.contains($0) }
            // 不回显服务端原文，避免响应中带出凭据。
            let detail = code.map { "Kimi 返回业务码 \($0)" } ?? "Kimi 返回 status=false"
            return .failure(auth ? .auth(detail) : .network(detail))
        }
        guard let d = obj["data"] as? [String: Any], let amount = DeepSeekProvider.decStrict(d["available_balance"]) else {
            return .failure(.schemaChanged("Kimi 余额响应里 data.available_balance 缺失或不是数字"))
        }
        return .success(Money(amount: amount, currency: .cny))
    }
}
