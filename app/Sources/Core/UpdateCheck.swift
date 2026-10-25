import Foundation

/// 检查更新：匿名请求 GitHub Releases 的 releases/latest（不带 token），和本机版本按语义化版本比较。
/// 自动检查每天最多一次（失败也算查过，下次照常隔天再查）；失败（断网、403 限流、JSON 不对）一律静默，只写一行日志。
/// 不自动下载、不弹系统通知：只在设置页和右键菜单里显示「有新版本 x」，点了用浏览器打开 Release 页面。
enum UpdateCheck {
    /// 公开仓库 owner/仓库名；留空则整个功能不发请求
    static let repo = "LemonShark0128/TokenBar"

    static let enabledKey = "updateCheckEnabled"
    static let lastCheckedKey = "updateCheckLastAt"
    static let latestVersionKey = "updateLatestVersion"
    static let latestURLKey = "updateLatestURL"
    static let interval: TimeInterval = 24 * 3600
    /// 设置页这一行没有检查结果时的说明
    static var defaultHelp: String { L("update.defaultHelp") }

    /// 本机版本（Info.plist 的 CFBundleShortVersionString）；测试程序里没有就是空串，空串不会被判为旧
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    struct Release: Equatable {
        var version: String
        var url: URL
    }

    enum Outcome: Equatable {
        case upToDate
        case newer(Release)
        case failed
    }

    static func url(repo: String) -> URL? {
        let r = repo.trimmingCharacters(in: .whitespaces)
        guard !r.isEmpty else { return nil }
        return URL(string: "https://api.github.com/repos/\(r)/releases/latest")
    }

    /// 「1.0.10」→ [1, 0, 10]；带预发布后缀（-beta）或有非数字段的认不出 → nil
    static func components(_ v: String) -> [Int]? {
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), let n = Int(p), n >= 0 else { return nil }
            out.append(n)
        }
        return out
    }

    /// a 比 b 新；少的段按 0 补（1.0 == 1.0.0）。任一边认不出都算不新
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard var x = components(a), var y = components(b) else { return false }
        let n = max(x.count, y.count)
        x += Array(repeating: 0, count: n - x.count)
        y += Array(repeating: 0, count: n - y.count)
        return y.lexicographicallyPrecedes(x)
    }

    /// 解析 releases/latest：取 tag_name（去掉前缀 v）和 html_url；草稿、预发布、不是版本号的 tag、非 https 链接都忽略
    static func parse(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tag = obj["tag_name"] as? String,
              let link = obj["html_url"] as? String,
              let url = URL(string: link), url.scheme == "https" else { return nil }
        if obj["prerelease"] as? Bool == true || obj["draft"] as? Bool == true { return nil }
        if tag.hasPrefix("v") || tag.hasPrefix("V") { tag.removeFirst() }
        guard components(tag) != nil else { return nil }
        return Release(version: tag, url: url)
    }

    static func isEnabled(_ d: UserDefaults) -> Bool {
        d.object(forKey: enabledKey) == nil ? true : d.bool(forKey: enabledKey)
    }
    static func setEnabled(_ on: Bool, _ d: UserDefaults) { d.set(on, forKey: enabledKey) }

    static func lastChecked(_ d: UserDefaults) -> Date? {
        guard d.object(forKey: lastCheckedKey) != nil else { return nil }
        return Date(timeIntervalSince1970: d.double(forKey: lastCheckedKey))
    }

    /// 上次看到的最新版本比本机新才返回（用户装了新版后自然消失）
    static func available(_ d: UserDefaults, current: String) -> Release? {
        guard let v = d.string(forKey: latestVersionKey),
              let s = d.string(forKey: latestURLKey), let u = URL(string: s),
              isNewer(v, than: current) else { return nil }
        return Release(version: v, url: u)
    }

    /// 自动检查：开关开着、从没查过、满 24 小时或上次时间在未来（时钟被往回拨）才查
    static func isDue(_ d: UserDefaults, now: Date) -> Bool {
        guard isEnabled(d) else { return false }
        guard let last = lastChecked(d) else { return true }
        let age = now.timeIntervalSince(last)
        return age < 0 || age >= interval
    }

    /// 需要时请求一次；不需要（开关关、未满 24 小时、仓库常量为空）返回 nil。force = 设置里点「现在检查」，不看开关和时间
    static func check(client: HTTPClient, repo: String = repo, defaults d: UserDefaults, current: String,
                      now: Date, force: Bool = false, log: (String) -> Void) async -> Outcome? {
        guard let u = url(repo: repo) else { return nil }
        guard force || isDue(d, now: now) else { return nil }
        d.set(now.timeIntervalSince1970, forKey: lastCheckedKey)
        var release: Release?
        var status = 0
        do {
            let (s, data) = try await client.get(u, headers: ["Accept": "application/vnd.github+json"])
            status = s
            if s == 200 { release = parse(data) }
        } catch {
            status = 0
        }
        guard let r = release else {
            log(status == 0 ? "检查更新失败：连不上 GitHub" : "检查更新失败：HTTP \(status)")
            return .failed
        }
        d.set(r.version, forKey: latestVersionKey)
        d.set(r.url.absoluteString, forKey: latestURLKey)
        if isNewer(r.version, than: current) {
            log("检查更新：有新版本 \(r.version)（本机 \(current)）")
            return .newer(r)
        }
        log("检查更新：已是最新（本机 \(current)，最新 \(r.version)）")
        return .upToDate
    }

    /// 设置页这一行的说明：刚点过「现在检查」显示结果，否则有新版本就提示，没有就是默认说明
    static func caption(_ outcome: Outcome?, available: Release?) -> String {
        switch outcome {
        case .upToDate: return L("update.upToDate")
        case .newer(let r): return L("update.newer", r.version)
        case .failed: return L("update.failed")
        case nil: return available.map { L("update.newer", $0.version) } ?? defaultHelp
        }
    }

    static func menuTitle(_ r: Release) -> String { L("update.menuTitle", r.version) }
}
