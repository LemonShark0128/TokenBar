import Foundation

/// 按 URL 路由到 Fixtures/<dir>/ 下的样本；route 返回 nil → 404 空体。记录所有请求供断言
/// @unchecked Sendable：测试替身，只在一个测试里顺序使用
final class RoutedFixtureHTTPClient: HTTPClient, @unchecked Sendable {
    let dir: URL
    let route: @Sendable (URL) -> (status: Int, file: String)?
    private(set) var requested: [URL] = []
    private(set) var requestHeaders: [[String: String]] = []

    init(dir: String, route: @escaping @Sendable (URL) -> (status: Int, file: String)?) {
        self.dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(dir)
        self.route = route
    }

    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        requested.append(url)
        requestHeaders.append(headers)
        guard let r = route(url) else { return (404, Data()) }
        return (r.status, try Data(contentsOf: dir.appendingPathComponent(r.file)))
    }
}

/// 内联响应体的 HTTP 客户端（合成样本不放进 Fixtures）
/// @unchecked Sendable：测试替身，只在一个测试里顺序使用
final class InlineHTTPClient: HTTPClient, @unchecked Sendable {
    let route: @Sendable (URL) -> (Int, String)
    init(route: @escaping @Sendable (URL) -> (Int, String)) { self.route = route }
    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        let r = route(url)
        return (r.0, Data(r.1.utf8))
    }
}
