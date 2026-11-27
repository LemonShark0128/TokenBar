import Foundation

// 日志变了之后怎么扫正在跑的任务（11-05：原来每次完整扫描，Agent 持续写日志时每秒列一遍所有会话文件）
@MainActor
func registerRunningScanTriggerTests() {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("tb scan trigger \(UUID().uuidString)")
    let projects = base.appendingPathComponent(".claude/projects")
    let sessions = base.appendingPathComponent(".codex/sessions")
    let mainSession = projects.appendingPathComponent("-Users-a-proj/abc.jsonl").path
    let subagent = projects.appendingPathComponent("-Users-a-proj/abc/subagents/agent-1.jsonl").path
    let codexFile = sessions.appendingPathComponent("2026/11/05/rollout-1.jsonl").path
    func decide(_ changed: [String], known: [String] = []) -> RunningScanTrigger {
        RunningScanTrigger.decide(changed: Set(changed), known: Set(known), claudeProjects: projects, codexSessions: sessions)
    }

    test("scanTriggerKnownSessionOnlyTailsKnownFiles") {
        try checkEqual(decide([mainSession], known: [mainSession]), .known)
        try checkEqual(decide([mainSession, codexFile], known: [mainSession, codexFile]), .known)
    }
    test("scanTriggerNewSessionFileDoesFullScan") {
        try checkEqual(decide([mainSession]), .full)
        try checkEqual(decide([codexFile]), .full)
        try checkEqual(decide([mainSession, codexFile], known: [mainSession]), .full)
    }
    test("scanTriggerIgnoresFilesFullScanNeverReads") {
        // 子代理日志、Codex 非日期层级的文件：完整扫描本来就不看
        try checkEqual(decide([subagent]), .ignore)
        try checkEqual(decide([sessions.appendingPathComponent("2026/11/x.jsonl").path]), .ignore)
        try checkEqual(decide([subagent, mainSession], known: [mainSession]), .known)
    }
    test("scanTriggerUnknownPathIsConservative") {
        try checkEqual(decide(["/somewhere/else/x.jsonl"]), .full)
        try checkEqual(decide([]), .ignore)
    }
    test("scanTriggerNormalizesPaths") {
        let messy = projects.path + "/./-Users-a-proj/abc.jsonl"
        try checkEqual(decide([messy], known: [mainSession]), .known)
    }

    test("fileStatReadsMtimeAndSize") {
        let f = base.appendingPathComponent("stat.jsonl")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: f)
        let when = Date(timeIntervalSince1970: 1_792_022_400.5)
        try fm.setAttributes([.modificationDate: when], ofItemAtPath: f.path)
        let s = FileStat.of(f)
        try checkEqual(s?.size, 6)
        try check(abs((s?.mtime.timeIntervalSince1970 ?? 0) - when.timeIntervalSince1970) < 0.01)
        let a = try fm.attributesOfItem(atPath: f.path)[.modificationDate] as? Date
        try check(a.map { abs($0.timeIntervalSince(s!.mtime)) < 0.001 } ?? false)   // 与原来的取法同口径
        try check(FileStat.of(base) == nil)                                           // 目录不算
        try check(FileStat.of(base.appendingPathComponent("missing")) == nil)
    }
}
