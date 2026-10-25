import Foundation

/// 追加写的日志文件：超过上限时整份滚动为「<文件名>.1」（只留一份旧的），新文件从空开始
struct LogFile: Sendable {
    let url: URL
    let maxBytes: Int
    var rotatedURL: URL { URL(fileURLWithPath: url.path + ".1") }

    init(url: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// 最后 n 行；当前文件不够时从上一份（.1）补
    func tail(_ n: Int) -> [String] {
        func lines(_ u: URL) -> [String] {
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { return [] }
            return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        var out = Array(lines(url).suffix(n))
        if out.count < n { out = Array(lines(rotatedURL).suffix(n - out.count)) + out }
        return out
    }

    func append(_ line: String) {
        let fm = FileManager.default
        if let a = try? fm.attributesOfItem(atPath: url.path), (a[.size] as? Int ?? 0) > maxBytes {
            try? fm.removeItem(at: rotatedURL)
            try? fm.moveItem(at: url, to: rotatedURL)
        }
        let data = Data(line.utf8)
        // 新装的机器上日志目录还不存在
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// App 日志：时间格式化器只建一个；写文件放在一个串行队列里，不卡调用线程（多半是主线程）。
/// 时间在调用时取，写入顺序 = 调用顺序；flush() 等队列里的都写完（退出前调用，不丢最后几行）
/// @unchecked Sendable：DateFormatter 不是 Sendable，但只在串行 queue 上用；其余属性都是常量
final class AppLogger: @unchecked Sendable {
    /// ~/Library/Logs/TokenBar/app.log（1.0.0 起；「控制台」App 里能直接看），超过 1 MB 滚动为 app.log.1
    /// 启动阶段有几处「记一行再 exit(0)」（让位、重复实例）：exit 会跑 atexit，在那里刷完，不丢最后几行
    static let shared: AppLogger = {
        let l = AppLogger(file: LogFile(url: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/TokenBar/app.log")))
        atexit { AppLogger.shared.flush() }
        return l
    }()

    let file: LogFile
    private let queue = DispatchQueue(label: "com.lemon.deepseek-tokenbar.log")
    /// 只在 queue 上用（DateFormatter 不是线程安全的）
    private let formatter: DateFormatter
    private let now: @Sendable () -> Date

    init(file: LogFile, timeZone: TimeZone = .autoupdatingCurrent, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.now = now
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MM-dd HH:mm:ss"
        formatter = f
    }

    func log(_ s: String) {
        let t = now()
        queue.async { self.file.append("[\(self.formatter.string(from: t))] \(s)\n") }
    }

    func flush() { queue.sync {} }
}

/// 写操作失败留痕（采样库、快照、钥匙串等）：记一行「写入失败（什么）：原因」。
/// 同一处连续失败、原因不变只记第一次（每次刷新都写，免得刷屏）；成功一次后再失败会重新记。不改变调用方的行为
/// @unchecked Sendable：last 只在 lock 里读写，sink 是 @Sendable
final class WriteFailureLog: @unchecked Sendable {
    /// 写进 app.log；测试启动时换成不落盘的（免得故意制造的失败写进真实日志）。
    /// nonisolated(unsafe)：只在测试启动、还没有任何后台任务时换一次，之后只读
    nonisolated(unsafe) static var shared = WriteFailureLog(sink: { AppLogger.shared.log($0) })

    private let sink: @Sendable (String) -> Void
    private let lock = NSLock()
    private var last: [String: String] = [:]

    init(sink: @escaping @Sendable (String) -> Void) { self.sink = sink }

    func failed(_ what: String, _ error: Error) {
        // 系统文件错误用本地化说明（含文件名和原因）；自己的错误类型用 description
        let ns = error as NSError
        let reason = [NSCocoaErrorDomain, NSPOSIXErrorDomain].contains(ns.domain) ? ns.localizedDescription : "\(error)"
        let line = "写入失败（\(what)）：\(reason)"
        lock.lock()
        let fresh = last[what] != line
        last[what] = line
        lock.unlock()
        if fresh { sink(line) }
    }

    func succeeded(_ what: String) {
        lock.lock(); last[what] = nil; lock.unlock()
    }

    /// 包一层：失败记一行再原样抛出
    func run<T>(_ what: String, _ body: () throws -> T) throws -> T {
        do { let r = try body(); succeeded(what); return r } catch { failed(what, error); throw error }
    }
}
