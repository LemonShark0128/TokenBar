import Foundation

/// 调试录制：包一层 HTTPClient，记下每次响应的路径末段、状态码和正文。
/// 不记请求头和查询串（cookie、subject id 都在里面）；写盘时只写 JSON 正文（控制台 HTML 里有 subject id）。
/// 正文里仍可能有账户信息，进仓库前要另行脱敏。
/// @unchecked Sendable：唯一的可变状态 recorded 只在 lock 里读写
final class RecordingHTTPClient: HTTPClient, @unchecked Sendable {
    struct Entry { var name: String; var status: Int; var body: Data }

    let inner: HTTPClient
    private let lock = NSLock()
    private var recorded: [Entry] = []
    var entries: [Entry] { lock.withLock { recorded } }

    init(inner: HTTPClient) { self.inner = inner }

    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        let (status, data) = try await inner.get(url, headers: headers)
        lock.withLock { recorded.append(Entry(name: url.lastPathComponent, status: status, body: data)) }
        return (status, data)
    }

    /// 写成 <序号>-<路径末段>.json（序号从 1 起，跳过的非 JSON 也占号），返回写出的文件
    func write(to dir: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for (i, e) in entries.enumerated() where (try? JSONSerialization.jsonObject(with: e.body)) != nil {
            let f = dir.appendingPathComponent("\(i + 1)-\(e.name).json")
            try e.body.write(to: f)
            out.append(f)
        }
        return out
    }
}
