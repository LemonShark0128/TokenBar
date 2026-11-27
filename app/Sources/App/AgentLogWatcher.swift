import Foundation
import CoreServices

/// 所有操作都在主队列；FSEvents 只传递文件路径，不读取日志内容。
final class AgentLogWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var paths: [String] = []
    /// 合并窗口里变过的 .jsonl 路径，窗口结束时一起交出去
    private var changedPaths: Set<String> = []
    private let changed: @Sendable (Set<String>) -> Void

    init(changed: @escaping @Sendable (Set<String>) -> Void) { self.changed = changed }
    deinit { stop() }

    func rebuild(dirs: AgentDirs, enabled: Set<ProviderID>, force: Bool = false) {
        var raw: [URL] = []
        if enabled.contains(.claudePlan) { raw.append(dirs.claudeConfig.appendingPathComponent("projects")) }
        if enabled.contains(.codexPlan) { raw.append(dirs.codexSessions) }
        if enabled.contains(.geminiPlan) { raw.append(dirs.antigravityBrain) }
        let wanted = raw.filter { url in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }.map(\.path)
        guard force || wanted != paths else { return }
        stop()
        paths = wanted
        guard !wanted.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<AgentLogWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var hit: [String] = []
            for index in 0..<count {
                let p = String(cString: paths[index])
                if p.hasSuffix(".jsonl") && !p.hasSuffix("/transcript_full.jsonl") { hit.append(p) }
            }
            if !hit.isEmpty { watcher.schedule(hit) }
        }, &context, wanted as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) { stop() }
        }
    }

    private func schedule(_ hit: [String]) {
        changedPaths.formUnion(hit)
        // 固定一秒合并窗口，持续写日志也不会无限推迟。
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            let batch = self.changedPaths
            self.changedPaths = []
            self.changed(batch)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func stop() {
        pending?.cancel()
        pending = nil
        changedPaths = []
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        paths = []
    }
}
