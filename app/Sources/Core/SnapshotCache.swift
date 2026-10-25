import Foundation

/// 最近一次成功的快照存到磁盘（快照里只有金额和用量，不含凭据），断网冷启动时用它显示完整数据。
/// 文件按平台存一份：{"deepseek": {...}}；读写失败都不影响正常刷新。
struct SnapshotCache: Sendable {
    let url: URL
    /// 写失败时记一行（调用方 try? 吞掉错误）
    var failures: WriteFailureLog = .shared

    /// 逐条解码：认不出的平台（如已删的 claude / openai）或解不开的条目单独跳过，不连累别的平台
    func load() -> [ProviderID: ProviderSnapshot] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: Lenient].self, from: data) else { return [:] }
        var out: [ProviderID: ProviderSnapshot] = [:]
        for (k, v) in raw { if let id = ProviderID(rawValue: k), let s = v.value { out[id] = s } }
        return out
    }

    private struct Lenient: Decodable {
        let value: ProviderSnapshot?
        init(from decoder: Decoder) throws { value = try? ProviderSnapshot(from: decoder) }
    }

    func save(_ s: ProviderSnapshot) throws {
        var all = load()
        all[s.provider] = s
        try write(all)
    }

    func remove(_ id: ProviderID) throws {
        var all = load()
        guard all.removeValue(forKey: id) != nil else { return }
        try write(all)
    }

    private func write(_ all: [ProviderID: ProviderSnapshot]) throws {
        try failures.run("快照写入") { try writeFile(all) }
    }

    private func writeFile(_ all: [ProviderID: ProviderSnapshot]) throws {
        let raw = Dictionary(uniqueKeysWithValues: all.map { ($0.key.rawValue, $0.value) })
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(raw).write(to: url, options: .atomic)
    }
}
