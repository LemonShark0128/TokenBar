import Foundation

/// 「复制诊断信息」：版本、系统、平台状态、最近日志。用户会把它贴给别人，所以整份输出一律先打码
enum Diagnostics {
    /// 按顺序替换：先整段的 JWT 和 Bearer，再「键=值」（值是 true/false 这类开关时不打码），再 sk- 开头的 key，最后兜底的长随机串
    private static let rules: [(NSRegularExpression, String)] = [
        (#"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+(\.[A-Za-z0-9_\-]+)?"#, "***"),
        (#"(?i)\bBearer\s+[^\s"',;]+"#, "Bearer ***"),
        (#"(?i)\b(api[_-]?key|access[_-]?token|user[_-]?token|web[_-]?token|admin[_-]?key|token|secret|password|passwd|authorization|cookie|session)(\s*["']?\s*[:=]\s*["']?)(?!Bearer\b)(?!\*\*\*)(?!(?:true|false|nil|null)\b)[^\s"',;&]+"#, "$1$2***"),
        (#"(?<![A-Za-z0-9])sk-[A-Za-z0-9_*\-]{4,}"#, "sk-***"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// 32 位以上的字母数字串（含 - _ + =）且同时有字母和数字：多半是 key、token 或 ID，一律打码
    private static let longRun = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_\-+=])[A-Za-z0-9_\-+=]{32,}"#)

    static func redact(_ s: String) -> String {
        var out = s
        for (re, template) in rules {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        let ns = NSMutableString(string: out)
        for m in longRun.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
            let run = ns.substring(with: m.range)
            if run.rangeOfCharacter(from: .decimalDigits) != nil, run.rangeOfCharacter(from: .letters) != nil {
                ns.replaceCharacters(in: m.range, with: "***")
            }
        }
        return ns as String
    }

    /// 系统留下的崩溃报告：只记文件名和时间，不读内容
    struct CrashReport: Equatable {
        var name: String
        var date: Date
    }

    /// ~/Library/Logs/DiagnosticReports/
    static var crashReportsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// 目录里最近 limit 份 TokenBar 的崩溃报告（TokenBar-*.ips / .crash），新的在前；目录不在或读不了返回空
    static func crashReports(in dir: URL = crashReportsDir, limit: Int = 3) -> [CrashReport] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let reports = names.filter { $0.hasPrefix("TokenBar-") && ($0.hasSuffix(".ips") || $0.hasSuffix(".crash")) }
            .compactMap { name -> CrashReport? in
                let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
                return (attrs?[.modificationDate] as? Date).map { CrashReport(name: name, date: $0) }
            }
        return Array(reports.sorted { $0.date > $1.date }.prefix(limit))
    }

    static func report(appVersion: String, osVersion: String, now: Date, timeZone: TimeZone,
                       platforms: [PlatformState], logLines: [String], crashReports: [CrashReport] = []) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        func t(_ d: Date?) -> String { d.map { fmt.string(from: $0) } ?? "—" }

        var lines = ["\(AppName.display) 诊断信息",
                     "生成时间：\(t(now))",
                     "App 版本：\(appVersion)",
                     "macOS：\(osVersion)",
                     "平台："]
        for st in platforms {
            var parts = ["状态 \(st.status)"]
            if let s = st.snapshot {
                parts.append("数据来源 \(s.source.rawValue)")
                parts.append("快照时间 \(t(s.fetchedAt))")
                if s.consoleLoginNeeded { parts.append("控制台登录失效") }
                if let p = s.consoleProblem { parts.append("控制台问题 \(p)") }
            } else {
                parts.append("无快照")
            }
            if st.snapshotFromDisk { parts.append("快照来自磁盘") }
            parts.append("最近采样 \(t(st.lastSampleAt))")
            lines.append("- \(st.id.rawValue)：" + parts.joined(separator: "；"))
        }
        if crashReports.isEmpty {
            lines.append("最近崩溃报告：无")
        } else {
            lines.append("最近崩溃报告（\(crashReports.count) 份）：")
            lines.append(contentsOf: crashReports.map { "- \($0.name)（\(t($0.date))）" })
        }
        let recent = logLines.suffix(50)
        lines.append("最近 \(recent.count) 行日志：")
        lines.append(contentsOf: recent)
        return redact(lines.joined(separator: "\n"))
    }
}
