import Foundation

/// 选平台页：已添加的平台自动勾上、不用再验证；只有新勾的平台走连接流程
@MainActor
func registerOnboardingPlanTests() {
    test("onboardingInitialPickedIncludesAdded") {
        try checkEqual(OnboardingPlan.initialPicked(added: [], only: nil), [.deepseek])
        try checkEqual(OnboardingPlan.initialPicked(added: [.deepseek], only: nil), [.deepseek])
        try checkEqual(OnboardingPlan.initialPicked(added: [.siliconflow, .codexPlan], only: nil), [.siliconflow, .codexPlan])
        // 设置里「添加」某个平台：只勾它（已添加的照样勾着，但不重走）
        try checkEqual(OnboardingPlan.initialPicked(added: [.deepseek], only: .claudePlan), [.deepseek, .claudePlan])
    }
    test("onboardingSetsUpOnlyNewPlatforms") {
        // 用户反馈：勾 DeepSeek 加 Claude 套餐时，不该让已登录的 DeepSeek 再验证一次
        try checkEqual(OnboardingPlan.toSetUp(picked: [.deepseek, .claudePlan], added: [.deepseek]), [.claudePlan])
        try checkEqual(OnboardingPlan.toSetUp(picked: [.claudePlan, .deepseek, .siliconflow], added: []),
                       [.deepseek, .siliconflow, .claudePlan])      // 按界面顺序
        try checkEqual(OnboardingPlan.toSetUp(picked: [.deepseek], added: [.deepseek]), [])
    }
    test("onboardingUncheckAddedMeansRemove") {
        // 用户反馈：选平台页要能取消勾选已添加的平台，等于「移除」，点「完成」后才生效
        try checkEqual(OnboardingPlan.toRemove(picked: [.deepseek], added: [.deepseek, .claudePlan, .codexPlan]),
                       [.codexPlan, .claudePlan])           // 按界面顺序
        try checkEqual(OnboardingPlan.toRemove(picked: [.deepseek, .claudePlan], added: [.deepseek]), [])
        try checkEqual(OnboardingPlan.toRemove(picked: [], added: []), [])
    }
    test("onboardingPickButtonTitle") {
        try checkEqual(OnboardingPlan.pickButton(picked: [], added: []), "跳过")
        try checkEqual(OnboardingPlan.pickButton(picked: [.deepseek], added: []), "下一步")
        try checkEqual(OnboardingPlan.pickButton(picked: [.deepseek], added: [.deepseek]), "完成")
        try checkEqual(OnboardingPlan.pickButton(picked: [], added: [.deepseek]), "完成")
        try checkEqual(OnboardingPlan.pickButton(picked: [.claudePlan], added: [.deepseek]), "下一步")
    }
    test("onboardingRemoveConfirmCopy") {
        let one = OnboardingPlan.removeConfirm([.codexPlan])
        try checkEqual(one.title, "移除 Codex 套餐？")
        let two = OnboardingPlan.removeConfirm([.deepseek, .claudePlan])
        try checkEqual(two.title, "移除 DeepSeek、Claude 套餐？")
        try check(two.detail.contains("settings.json"), "移除 Claude 套餐要说明会还原 settings.json")
        try check(two.detail.contains("钥匙串"), "移除按量付费平台要说明会删钥匙串凭据")
    }
}

/// 第四批第 3 条：从选平台页勾上 Claude 套餐、点「允许修改并安装」后，页面变成了 DeepSeek 登录页。
/// 根因：引导页每次界面刷新都按「此刻已添加的平台」重算待连接队列；Claude 一装好就从队列里消失，
/// 当前平台又默认回落到 DeepSeek。修法：队列在进入连接步骤时定下来，之后不随存储变化；队列走完就收尾，不回落
@MainActor
func registerOnboardingFlowTests() {
    test("onboardingFlowKeepsPlatformAfterItBecomesAdded") {
        var f = OnboardingFlow(added: [.deepseek, .siliconflow, .codexPlan], only: nil)
        f.picked.insert(.claudePlan)
        f.startLogin()
        try checkEqual(f.current, .claudePlan)
        // 安装成功后存储里 Claude 套餐已添加；按此刻的已添加平台重算，队列会是空的——这正是出错的写法
        try checkEqual(OnboardingPlan.toSetUp(picked: f.picked, added: [.deepseek, .siliconflow, .codexPlan, .claudePlan]), [])
        // 定下来的队列不受影响：仍是 Claude 套餐，并且是最后一个
        try checkEqual(f.current, .claudePlan)
        try check(f.isLast)
    }
    test("onboardingFlowNeverFallsBackToDeepSeek") {
        var f = OnboardingFlow(added: [.deepseek], only: nil)
        f.startLogin()                       // 没有新勾的平台
        try checkEqual(f.current, nil)
        var g = OnboardingFlow(added: [], only: nil)
        g.picked = [.siliconflow, .claudePlan]
        g.startLogin()
        try checkEqual(g.current, .siliconflow)
        try check(g.advance())
        try checkEqual(g.current, .claudePlan)
        try check(!g.advance())              // 走完：没有下一个，也不回到 DeepSeek
        try checkEqual(g.current, nil)
    }
    test("onboardingFlowOnlyFromSettings") {
        var f = OnboardingFlow(added: [.deepseek, .siliconflow], only: .claudePlan)
        try checkEqual(f.picked, [.deepseek, .siliconflow, .claudePlan])
        f.startLogin()
        try checkEqual(f.current, .claudePlan)
        try check(f.isLast)
    }
    test("onboardingFlowQueueFixedOnceLoginStarts") {
        // 连接 DeepSeek 后存储变化、picked 被改，都不该让后面的平台被跳过
        var f = OnboardingFlow(added: [], only: nil)
        f.picked = [.deepseek, .siliconflow]
        f.startLogin()
        f.picked.remove(.deepseek)
        try check(f.advance())
        try checkEqual(f.current, .siliconflow)
    }
}

/// 第四批第 2 条：选平台页里已经连接成功的平台用绿色勾，不再全是灰色
@MainActor
func registerOnboardingPickCheckTests() {
    test("pickCheckGreenForConnected") {
        try checkEqual(OnboardingPlan.pickCheck(on: true, added: true, state: .ok), .connected)
        try checkEqual(OnboardingPlan.pickCheck(on: true, added: true, state: .balanceOnly), .connected)
        try checkEqual(OnboardingPlan.pickCheck(on: true, added: true, state: .expiring(days: 3)), .connected)
        // 已添加但没连上：灰勾，副标题写原因
        try checkEqual(OnboardingPlan.pickCheck(on: true, added: true, state: .invalid), .addedNotConnected)
        try checkEqual(OnboardingPlan.pickCheck(on: true, added: true, state: .offline), .addedNotConnected)
        try checkEqual(OnboardingPlan.pickCheck(on: true, added: true, state: .connecting), .addedNotConnected)
        try checkEqual(OnboardingPlan.pickCheck(on: true, added: false, state: nil), .new)
        try checkEqual(OnboardingPlan.pickCheck(on: false, added: true, state: .ok), .off)
        try checkEqual(OnboardingPlan.pickCheck(on: false, added: false, state: nil), .off)
    }
    test("pickDetailForAdded") {
        try checkEqual(OnboardingPlan.addedDetail(on: true, state: .ok, id: .deepseek), "已连接")
        try checkEqual(OnboardingPlan.addedDetail(on: true, state: .invalid, id: .deepseek), "已添加 · API Key 无效")
        try checkEqual(OnboardingPlan.addedDetail(on: true, state: .invalid, id: .siliconflow), "已添加 · 登录已过期")
        try checkEqual(OnboardingPlan.addedDetail(on: false, state: .ok, id: .deepseek), "已添加 · 取消勾选后会移除")
    }
    // 用户 11/6 选 proposal-pick-redesign 乙：老用户进「添加 / 移除平台」是管理页，第一次打开仍是勾选
    test("manageShownForReturningUsers") {
        try check(!OnboardingPlan.showsManage(added: [], only: nil), "第一次（什么都没加）走勾选")
        try check(OnboardingPlan.showsManage(added: [.deepseek], only: nil))
        try check(!OnboardingPlan.showsManage(added: [.deepseek], only: .kimi), "从设置添加某一个平台：直接走连接")
    }
    test("manageListsAddedAndAddable") {
        let m = OnboardingPlan.manageLists(added: [.claudePlan, .deepseek])
        try checkEqual(m.added, [.deepseek, .claudePlan])                      // 按界面顺序
        try checkEqual(m.addable, [.siliconflow, .kimi, .openrouter, .packyapi, .codexPlan, .geminiPlan])
        let all = OnboardingPlan.manageLists(added: Set(ProviderRegistry.all))
        try checkEqual(all.addable, [])
        try checkEqual(L("ob.allAdded", ProviderRegistry.all.count), "8 个平台都已添加")
    }
    test("manageStatusShowsReading") {
        func st(_ id: ProviderID, _ s: AccountState?, _ r: AccountReading?) -> (String, Bool) {
            let x = OnboardingPlan.addedStatus(id, state: s, reading: r); return (x.text, x.warn)
        }
        try checkEqual(st(.deepseek, .ok, .money(5.35, currency: "CNY")).0, "已连接 · 余额 ¥5.35")
        try checkEqual(st(.deepseek, .ok, .money(5.35, currency: "CNY")).1, false)
        try checkEqual(st(.claudePlan, .ok, .session(59)).0, "已连接 · 5 小时窗口剩 59%")
        try checkEqual(st(.kimi, .ok, nil).0, "已连接")
        try checkEqual(st(.deepseek, .balanceOnly, .money(5.35, currency: "CNY")).0, "已连接 · 余额 ¥5.35")
        // 没连上：写状态、标成要处理（橙色）
        let bad = st(.siliconflow, .invalid, nil)
        try checkEqual(bad.0, "已添加 · 登录已过期")
        try check(bad.1)
        try check(st(.deepseek, .expiring(days: 2), .money(1, currency: "CNY")).1, "快过期要提醒")
    }
    // 管理页「可添加」每行一句短说明（窗口定高，两行的长说明放不下）
    test("manageShortGain") {
        try checkEqual(ProviderRegistry.all.map(OnboardingPlan.shortGain), [
            "API Key · 余额，登录控制台后有花费明细", "网页登录 · 余额、今日 / 本月花费", "API Key · 余额（花费按余额变化估算）",
            "API Key · 这把 Key 的今日 / 本月花费、余额",
            "访问令牌 · 余额、今日 / 本月花费", "读本机 Codex 记录，不用登录", "登录 claude.ai 或用本机 Claude Code 查", "用本机 Antigravity CLI 查额度，不花 token"])
    }
    test("pickGroupsByMeter") {
        let g = OnboardingPlan.groups
        try checkEqual(g.map(\.ids), [[.deepseek, .siliconflow, .kimi, .openrouter, .packyapi], [.codexPlan, .claudePlan, .geminiPlan]])
        try checkEqual(g.map(\.title), ["按量付费 · 看余额", "套餐 · 看额度"])
    }

}
