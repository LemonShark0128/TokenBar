import Foundation

/// 轻量取文件修改时间和大小：直接 stat()，不像 FileManager.attributesOfItem 那样顺带读扩展属性。
/// 正在跑的任务每秒扫几百个日志文件，采样显示 attributesOfItem 的 getxattr 是主要开销（11-05 实测）
enum FileStat {
    static func of(_ url: URL) -> (mtime: Date, size: UInt64)? {
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let t = st.st_mtimespec
        return (Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1_000_000_000),
                UInt64(max(0, st.st_size)))
    }

    static func mtime(_ url: URL) -> Date? { of(url)?.mtime }
}

/// 日志文件变了之后怎么扫正在跑的任务（纯函数，可测）：
/// - ignore：变的都是完整扫描本来就不看的文件（如 Claude 子代理日志 projects/<项目>/<会话>/subagents/*.jsonl），不扫
/// - known：变的都是已知在跑的会话文件，只追读它们
/// - full：出现了新会话文件（或认不出的路径，保守起见），完整扫描一次
enum RunningScanTrigger: Equatable {
    case ignore, known, full

    static func decide(changed: Set<String>, known: Set<String>, claudeProjects: URL, codexSessions: URL,
                       antigravityBrain: URL? = nil) -> RunningScanTrigger {
        let claudeRoot = norm(claudeProjects.path)
        let codexRoot = norm(codexSessions.path)
        let geminiRoot = antigravityBrain.map { norm($0.path) }
        let knownPaths = Set(known.map(norm))
        var sawKnown = false
        for raw in changed {
            let p = norm(raw)
            if knownPaths.contains(p) { sawKnown = true; continue }
            // 完整扫描只看 projects/<项目>/*.jsonl、sessions/yyyy/MM/dd/*.jsonl、brain/<会话>/.system_generated/logs/transcript.jsonl；
            // 先查全部已匹配的根（防止自定义目录嵌套时被外层根提前短路）：任一根放行即 .full，均命中但都不放行才 .ignore
            var matchedRoot = false
            if let depth = depth(p, under: claudeRoot) {
                matchedRoot = true
                if depth == 2 { return .full }
            }
            if let depth = depth(p, under: codexRoot) {
                matchedRoot = true
                if depth == 4 { return .full }
            }
            if let geminiRoot, let depth = depth(p, under: geminiRoot) {
                matchedRoot = true
                if depth == 4 && p.hasSuffix("/.system_generated/logs/transcript.jsonl") { return .full }
            }
            if matchedRoot { continue }
            return .full
        }
        return sawKnown ? .known : .ignore
    }

    /// p 在 root 下第几层（root/a/b.jsonl 为 2）；不在 root 下为 nil
    private static func depth(_ p: String, under root: String) -> Int? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard p.hasPrefix(prefix) else { return nil }
        return p.dropFirst(prefix.count).split(separator: "/").count
    }

    /// 统一成解析过符号链接的绝对路径（FSEvents 报的是真实路径，比如 /private/var 而不是 /var）
    private static func norm(_ p: String) -> String {
        URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
