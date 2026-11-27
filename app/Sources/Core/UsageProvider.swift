import Foundation

/// 网络层抽象：真实用 URLSession，测试用按 URL 返回样本的假实现
protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data)
}

/// 默认直连（不走系统代理，与原 Python 采集的 _opener_direct 一致）、无持久缓存、25 秒超时。
/// systemProxy=true 时走系统代理（只给汇率用：直连 frankfurter 在中国网络下常失败）
struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    /// cookies = false：不存、不自动带 Cookie（claude.ai 网页来源自己写 Cookie 头，系统的 Cookie 罐会混进旧的、盖掉新的）
    init(systemProxy: Bool = false, cookies: Bool = true) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        if !systemProxy { cfg.connectionProxyDictionary = [:] }
        if !cookies {
            cfg.httpCookieStorage = nil
            cfg.httpShouldSetCookies = false
            cfg.httpCookieAcceptPolicy = .never
        }
        session = URLSession(configuration: cfg)
    }

    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, resp) = try await session.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// 每个平台一个实现：拿凭据 → 返回统一快照。
/// Sendable：UsageStore 在主线程上持有它，取数（validate / fetch）在后台跑
protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var capabilities: Capabilities { get }
    func validate(_ c: Credentials) async -> ValidationResult
    func fetch(_ c: Credentials, now: Date, timeZone: TimeZone) async -> Result<ProviderSnapshot, ProviderError>
}
