import Foundation

@MainActor
func registerUpdateCheckTests() {
    let now = Date(timeIntervalSince1970: 1_792_108_800)   // 2026-10-16 00:00:00 UTC
    let release = #"{"tag_name":"v1.0.1","html_url":"https://github.com/lemon/TokenBar/releases/tag/v1.0.1","prerelease":false,"draft":false}"#

    test("updateVersionCompare") {
        try check(UpdateCheck.isNewer("1.0.10", than: "1.0.9"), "1.0.10 > 1.0.9")
        try check(UpdateCheck.isNewer("1.1", than: "1.0.9"))
        try check(UpdateCheck.isNewer("2.0.0", than: "1.99.99"))
        try check(!UpdateCheck.isNewer("1.0.0", than: "1.0.0"))
        try check(!UpdateCheck.isNewer("1.0", than: "1.0.0"), "少一段当 0")
        try check(!UpdateCheck.isNewer("1.0.9", than: "1.0.10"))
        try check(!UpdateCheck.isNewer("abc", than: "1.0.0"), "认不出的版本号不算新")
        try check(!UpdateCheck.isNewer("1.0.1", than: "—"), "本机版本认不出也不提示")
    }
    test("updateParseRelease") {
        let r = UpdateCheck.parse(Data(release.utf8))
        try checkEqual(r?.version, "1.0.1")
        try checkEqual(r?.url.absoluteString, "https://github.com/lemon/TokenBar/releases/tag/v1.0.1")
        // 不带 v 前缀也行
        try checkEqual(UpdateCheck.parse(Data(#"{"tag_name":"1.2.0","html_url":"https://github.com/x/y/releases/tag/1.2.0"}"#.utf8))?.version, "1.2.0")
    }
    test("updateParseIgnoresPrereleaseAndJunk") {
        func p(_ s: String) -> UpdateCheck.Release? { UpdateCheck.parse(Data(s.utf8)) }
        try check(p(#"{"tag_name":"v1.1.0-beta.1","html_url":"https://github.com/x/y/releases/tag/v1.1.0-beta.1"}"#) == nil, "预发布 tag 忽略")
        try check(p(#"{"tag_name":"v1.1.0","html_url":"https://github.com/x/y","prerelease":true}"#) == nil, "标了预发布的忽略")
        try check(p(#"{"tag_name":"v1.1.0","html_url":"https://github.com/x/y","draft":true}"#) == nil)
        try check(p("not json") == nil)
        try check(p(#"{"message":"API rate limit exceeded"}"#) == nil)
        try check(p(#"{"tag_name":"nightly","html_url":"https://github.com/x/y"}"#) == nil, "不是版本号的 tag 忽略")
        try check(p(#"{"tag_name":"v1.1.0","html_url":"javascript:alert(1)"}"#) == nil, "只认 https 链接")
    }
    test("updateURLFromRepo") {
        try checkEqual(UpdateCheck.url(repo: "lemon/TokenBar")?.absoluteString,
                       "https://api.github.com/repos/lemon/TokenBar/releases/latest")
        try check(UpdateCheck.url(repo: "") == nil, "仓库常量为空时不发请求")
        try check(UpdateCheck.url(repo: "  ") == nil)
        try checkEqual(UpdateCheck.url(repo: UpdateCheck.repo)?.absoluteString,
                       "https://api.github.com/repos/LemonShark0128/TokenBar/releases/latest")
    }
    test("updateEnabledDefaultsOn") {
        let d = freshDefaults()
        try check(UpdateCheck.isEnabled(d), "默认开")
        UpdateCheck.setEnabled(false, d)
        try check(!UpdateCheck.isEnabled(d))
    }

    testAsync("updateCheckFindsNewerAndStores") {
        let d = freshDefaults()
        let c = FakeRateClient(); c.body = release
        let logs = LogLines()
        let o = await UpdateCheck.check(client: c, repo: "lemon/TokenBar", defaults: d, current: "1.0.0", now: now) { @Sendable in logs.add($0) }
        let r = UpdateCheck.Release(version: "1.0.1", url: URL(string: "https://github.com/lemon/TokenBar/releases/tag/v1.0.1")!)
        try checkEqual(o, .newer(r))
        try checkEqual(c.requested.map(\.absoluteString), ["https://api.github.com/repos/lemon/TokenBar/releases/latest"])
        try checkEqual(UpdateCheck.lastChecked(d), now)
        try checkEqual(UpdateCheck.available(d, current: "1.0.0"), r)
        // 用户装了新版后不再提示
        try check(UpdateCheck.available(d, current: "1.0.1") == nil)
        try checkEqual(logs.lines.count, 1)
    }
    testAsync("updateCheckUpToDate") {
        let d = freshDefaults()
        let c = FakeRateClient(); c.body = release
        let o = await UpdateCheck.check(client: c, repo: "lemon/TokenBar", defaults: d, current: "1.0.1", now: now) { @Sendable _ in }
        try checkEqual(o, .upToDate)
        try check(UpdateCheck.available(d, current: "1.0.1") == nil)
    }
    testAsync("updateCheckAtMostOncePerDay") {
        let d = freshDefaults()
        let c = FakeRateClient(); c.body = release
        _ = await UpdateCheck.check(client: c, repo: "a/b", defaults: d, current: "1.0.0", now: now) { @Sendable _ in }
        let again = await UpdateCheck.check(client: c, repo: "a/b", defaults: d, current: "1.0.0", now: now.addingTimeInterval(23 * 3600)) { @Sendable _ in }
        try check(again == nil, "不满 24 小时不查")
        try checkEqual(c.requested.count, 1)
        _ = await UpdateCheck.check(client: c, repo: "a/b", defaults: d, current: "1.0.0", now: now.addingTimeInterval(24 * 3600)) { @Sendable _ in }
        try checkEqual(c.requested.count, 2)
        // 时钟往回拨：照样查
        _ = await UpdateCheck.check(client: c, repo: "a/b", defaults: d, current: "1.0.0", now: now.addingTimeInterval(-3600)) { @Sendable _ in }
        try checkEqual(c.requested.count, 3)
        // 「现在检查」不受 24 小时限制
        let forced = await UpdateCheck.check(client: c, repo: "a/b", defaults: d, current: "1.0.0", now: now.addingTimeInterval(-3500), force: true) { @Sendable _ in }
        try check(forced != nil)
        try checkEqual(c.requested.count, 4)
    }
    testAsync("updateCheckRespectsSwitchAndEmptyRepo") {
        let d = freshDefaults()
        let c = FakeRateClient(); c.body = release
        UpdateCheck.setEnabled(false, d)
        let off = await UpdateCheck.check(client: c, repo: "a/b", defaults: d, current: "1.0.0", now: now) { @Sendable _ in }
        try check(off == nil, "关掉开关后自动检查不发请求")
        try checkEqual(c.requested.count, 0)
        // 关着开关也能手动「现在检查」
        let manual = await UpdateCheck.check(client: c, repo: "a/b", defaults: d, current: "1.0.0", now: now, force: true) { @Sendable _ in }
        try check(manual != nil)
        try checkEqual(c.requested.count, 1)
        // 仓库常量为空：手动也不发请求
        UpdateCheck.setEnabled(true, d)
        let empty = await UpdateCheck.check(client: c, repo: "", defaults: freshDefaults(), current: "1.0.0", now: now, force: true) { @Sendable _ in }
        try check(empty == nil)
        try checkEqual(c.requested.count, 1)
    }
    testAsync("updateCheckFailuresAreSilent") {
        for setup in [{ (c: FakeRateClient) in c.throwing = true },
                      { (c: FakeRateClient) in c.status = 403; c.body = #"{"message":"API rate limit exceeded for 1.2.3.4"}"# },
                      { (c: FakeRateClient) in c.status = 404; c.body = #"{"message":"Not Found"}"# },
                      { (c: FakeRateClient) in c.body = "not json" }] {
            let d = freshDefaults()
            // 之前看到过的新版本不因一次失败丢掉
            let c0 = FakeRateClient(); c0.body = release
            _ = await UpdateCheck.check(client: c0, repo: "a/b", defaults: d, current: "1.0.0", now: now.addingTimeInterval(-86400)) { @Sendable _ in }
            let c = FakeRateClient(); setup(c)
            let logs = LogLines()
            let o = await UpdateCheck.check(client: c, repo: "a/b", defaults: d, current: "1.0.0", now: now) { @Sendable in logs.add($0) }
            try checkEqual(o, .failed)
            try checkEqual(logs.lines.count, 1)
            try check(logs.lines.allSatisfy { !$0.contains("1.2.3.4") && !$0.contains("message") }, "日志不带响应内容")
            try checkEqual(UpdateCheck.lastChecked(d), now)    // 失败也算查过：下次照常隔天再查
            try checkEqual(UpdateCheck.available(d, current: "1.0.0")?.version, "1.0.1")
        }
    }
    test("updateCaption") {
        let r = UpdateCheck.Release(version: "1.0.1", url: URL(string: "https://github.com/x/y")!)
        try checkEqual(UpdateCheck.caption(.upToDate, available: nil), "已是最新")
        try checkEqual(UpdateCheck.caption(.newer(r), available: r), "有新版本 1.0.1")
        try checkEqual(UpdateCheck.caption(.failed, available: nil), "检查失败，稍后再试")
        try checkEqual(UpdateCheck.caption(nil, available: r), "有新版本 1.0.1")
        try checkEqual(UpdateCheck.caption(nil, available: nil), UpdateCheck.defaultHelp)
        try checkEqual(UpdateCheck.menuTitle(r), "有新版本 1.0.1…")
    }
    test("settingsGeneralPageHasUpdateRow") {
        let s = SettingsLayout.sections(.general, added: [.deepseek], main: .deepseek, customOpen: [])
        try checkEqual(s.first?.rows.contains(.updateCheck), true)
    }
}
