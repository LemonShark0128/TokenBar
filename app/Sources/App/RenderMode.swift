import AppKit
import SwiftUI

// ---------------------------------------------------------------- 离屏渲染（自检用）

@MainActor
enum RenderMode {
    static var renderScale: CGFloat {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--render-scale"),
              index + 1 < args.count,
              let value = Double(args[index + 1]),
              value >= 1, value <= 8 else { return 2 }
        return CGFloat(value)
    }

    static func run() {
        let args = CommandLine.arguments
        // --out <目录>：预览写到指定目录（默认 ~/Library/Logs/TokenBar/preview）
        let outDir = args.firstIndex(of: "--out").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let dir = URL(fileURLWithPath: outDir ?? (kLogDir + "/preview"))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = UsageModel()
        let originalTheme = model.themeMode
        // 渲染会改主题、小组件页等；渲染时这些 didSet 不写偏好（savePref），这里只把内存里的值改回去
        let saved = (full: model.fuelFullCny, mb: model.mbMode, page: model.widgetPage, glass: Glass.shared.transparency,
                     style: model.mbStyle, slots: model.mbSlots, running: model.mbShowRunning)
        // 注意不能用 defer：exit() 会直接结束进程，defer 不会执行
        let restore = {
            model.fuelFullCny = saved.full; model.mbMode = saved.mb; model.widgetPage = saved.page
            Glass.shared.transparency = saved.glass
            model.mbStyle = saved.style; model.mbSlots = saved.slots; model.mbShowRunning = saved.running
            model.themeMode = originalTheme
            UserDefaults.standard.synchronize()
            forgetDevCopy()
        }
        // 预览只用默认设置画，不随用户真实的刷新间隔、突增提醒、提醒间隔、开机启动、面板首页、菜单栏样式变化
        //（渲染时这些 didSet 不写偏好，见 savePref）
        model.refreshSeconds = 60; model.spikeAlertsOn = false; model.alertRepeatHours = AlertRepeat.defaultHours
        model.launchAtLogin = true; model.panelHome = "today"
        model.mbStyle = "bars"; model.mbSlots = "single"; model.mbShowRunning = true
        model.fuelFullCny = 50; model.mbMode = "balance"; Glass.shared.transparency = 0.55
        let checkDir = args.firstIndex(of: "--render-check").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        if checkDir != nil {
            // 截图对比用固定数据（设置已在上面固定），结果才可重复
            model.data = sampleData()
            renderAll(model: model, dir: dir, originalTheme: originalTheme)
            restore()
            compare(dir: dir, baseline: URL(fileURLWithPath: checkDir!))
            return
        }

        model.data = sampleData()
        model.error = nil
        renderAll(model: model, dir: dir, originalTheme: originalTheme)
        restore()
        exit(0)
    }

    static func renderMenuBarStyles(dir: URL) {
        let now = sampleSnapshot().fetchedAt
        let ds = deepseekMainState(now: now)
        var sf = ds
        sf.id = .siliconflow; sf.snapshot?.provider = .siliconflow
        sf.snapshot?.balance = Money(amount: 12, currency: .cny)
        var codex = quotaMainState(now: now)
        codex.snapshot?.quota = Quota(plan: nil, windows: [
            QuotaWindow(kind: .session, usedPercent: 99, resetsAt: now.addingTimeInterval(11640), windowMinutes: 300),
            QuotaWindow(kind: .weekly, usedPercent: 95, resetsAt: now.addingTimeInterval(4 * 86400), windowMinutes: 10080)
        ], observedAt: now)
        var claude = codex
        claude.id = .claudePlan; claude.snapshot?.provider = .claudePlan
        claude.snapshot?.quota = Quota(plan: nil, windows: [
            QuotaWindow(kind: .session, usedPercent: 31, resetsAt: now.addingTimeInterval(11640), windowMinutes: 300),
            QuotaWindow(kind: .weekly, usedPercent: 80, resetsAt: now.addingTimeInterval(4 * 86400), windowMinutes: 10080)
        ], observedAt: now)
        let d = AppDataMapping.appData(main: ds, others: [sf, codex, claude], now: now, timeZone: .current)
        let cells = MenuBarCells.cells(d, main: .deepseek, now: now)
        for dark in [true, false] {
            let preview = MenuBarStylesPreview(cells: cells, dark: dark)
            render(preview, name: "menubar-styles-\(dark ? "dark" : "light")", size: CGSize(width: 520, height: 360), dir: dir)
            if dark { render(preview, name: "menubar-styles", size: CGSize(width: 520, height: 360), dir: dir) }
        }
    }

    /// 运行渲染时系统会登记这份开发副本；跑完去掉，免得通知中心挑中它（见 DevCopy）
    static func forgetDevCopy() {
        let bundle = Bundle.main.bundleURL
        guard DevCopy.shouldForget(bundle: bundle, home: URL(fileURLWithPath: NSHomeDirectory())) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: DevCopy.lsregister)
        p.arguments = ["-u", bundle.path]
        try? p.run()
        p.waitUntilExit()
    }

    static func renderAll(model: UsageModel, dir: URL, originalTheme: UsageModel.ThemeMode) {

        renderMenuBarStyles(dir: dir)
        let detailDay = model.data?.trend7.last(where: { ($0.detail?.isEmpty == false) })
        let detailKey = model.trendModelKey      // 与真 App 同口径：传模型 key，不是 label

        for dark in [true, false] {
            model.themeMode = dark ? .dark : .light
            let tag = dark ? "dark" : "light"
            let p = Palette.of(dark)
            let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)

            renderFit(PanelView(model: model, p: p), name: "panel-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            // 用户反馈的场景：余额 ¥44.84、指针在 85% 附近时不能压到数字；两端和最长的数字也画一张
            renderFit(HStack(spacing: 40) {
                FuelGauge(level: 0.85, balance: "¥44.84", caption: "约可用 9 天 · 近 1 小时 ¥0.00/时", p: p)
                FuelGauge(level: 0.02, balance: "¥1,234.56", caption: "约可用 30 天", p: p)
            }.padding(20), name: "gauge-needle-\(tag)", width: 560, bg: bg, dir: dir)
            model.detailOpen = true
            renderFit(PanelView(model: model, p: p), name: "panel-open-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            model.detailOpen = false
            for page in ["balance", "tokens"] {
                model.widgetPage = page
                renderFit(WidgetView(model: model), name: "widget-\(page)-\(tag)", width: 270, bg: bg, dir: dir)
            }
            // 设置四页（方案 A 侧栏）：DeepSeek（主）正常、硅基流动 3 天后过期、Codex 套餐正常、Claude 套餐未添加
            let settingsInput = multiPlatformInput(snap: sampleSnapshot())
            renderSettings(model, page: .platform, input: settingsInput, name: "settings-platform-\(tag)", p: p, bg: bg, dir: dir)
            model.mbStyle = "bars"
            model.mbShowRunning = true
            model.mbSlots = "single"
            renderSettings(model, page: .display, input: settingsInput, name: "settings-menubar-\(tag)", p: p, bg: bg, dir: dir)
            renderSettings(model, page: .alerts, input: settingsInput, name: "settings-alerts-\(tag)", p: p, bg: bg, dir: dir)
            // 代理提醒：DeepSeek 每小时花费超过 ¥2（硅基流动保持默认「关」），套餐重置前会用完默认开
            var agent = settingsInput
            agent.settings.hourlyAlerts[.deepseek] = 2
            renderSettings(model, page: .alerts, input: agent, name: "settings-alerts-agent-\(tag)", p: p, bg: bg, dir: dir)
            renderSettings(model, page: .general, input: settingsInput, name: "settings-general-\(tag)", p: p, bg: bg, dir: dir)
            if !dark {
                var customDirectory = settingsInput
                customDirectory.customDirs[.codex] = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Codex Data").path
                renderSettings(model, page: .platform, input: customDirectory, name: "settings-platform-custom-codex", p: p, bg: bg, dir: dir)
                let savedLang = L10n.lang
                L10n.lang = .zh
                renderFit(WebLoadErrorBar(text: WebLoadFailure.message(domain: NSURLErrorDomain, code: -1001, host: nil), onRetry: {}),
                          name: "weblogin-error-zh", width: 480, bg: bg, dir: dir)
                L10n.lang = savedLang
                // 4 个平台都添加：平台行和菜单栏平台下拉（固定到最长的「Claude 套餐」）都要放得下
                var four = settingsInput
                var claude = quotaMainState(now: sampleSnapshot().fetchedAt)
                claude.id = .claudePlan; claude.snapshot?.provider = .claudePlan; claude.snapshot?.quota?.plan = nil
                four.platforms.append(claude)
                four.auto = false
                renderSettings(model, page: .platform, input: four, name: "settings-four-platforms", p: p, bg: bg, dir: dir)
                renderSettings(model, page: .display, input: four, name: "settings-four-platforms-display", p: p, bg: bg, dir: dir)
                renderSettings(model, page: .alerts, input: four, name: "settings-four-platforms-alerts", p: p, bg: bg, dir: dir)
                // 各种账号状态：DeepSeek 只有余额（主）、硅基流动已失效、Codex 套餐正在连接
                var states = settingsInput
                var bo = sampleSnapshot(); bo.source = .balanceOnly
                states.platforms = [PlatformState(id: .deepseek, snapshot: bo, burn: nil, status: .ok),
                                    PlatformState(id: .siliconflow, snapshot: nil, burn: nil, status: .credentialInvalid),
                                    PlatformState(id: .codexPlan, snapshot: nil, burn: nil, status: .loading)]
                renderSettings(model, page: .platform, input: states, name: "settings-platform-states", p: p, bg: bg, dir: dir)
                renderSettings(model, page: .alerts, input: states, name: "settings-alerts-states", p: p, bg: bg, dir: dir)
            }
            // 「今日/本月费用」卡片单独渲染：口径徽标（账单/估算）要看得到才算验过
            // 旧的 CostPair 单卡自检已随 A 版移除（口径改为 SourceTag，随面板一起渲染）
            // 右键菜单信息卡：画在模拟的菜单底色上（真菜单截不到）
            render(MenuInfoCard(model: model, hover: HoverState())
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .padding(.vertical, 6)
                    .background(dark ? Color(white: 0.17) : Color(white: 0.965)),
                   name: "menucard-\(tag)", size: CGSize(width: MenuCardHost.width, height: 150), dir: dir)
            if dark {
                // 菜单栏自检：与 StatusBarController.refresh 同一套图标/字号/槽位，画在深色菜单栏底上
                render(MenuBarPreview(model: model), name: "menubar", size: CGSize(width: 430, height: 286), dir: dir)
                // 平台标志：菜单栏大小（16pt）和放大（48pt），浅色 / 深色底
                render(HStack(spacing: 0) {
                    ForEach([false, true], id: \.self) { dark in
                        VStack(spacing: 14) {
                            ForEach(ProviderRegistry.all, id: \.self) { id in
                                HStack(spacing: 14) {
                                    Image(nsImage: PlatformGlyph.image(id, size: 48, tint: dark ? .white : .black))
                                    Image(nsImage: PlatformGlyph.image(id, size: 16, tint: dark ? .white : .black))
                                    Image(nsImage: PlatformGlyph.image(id, size: 16, tint: AlertColor.danger(dark: dark)))
                                    Text(ProviderRegistry.displayName(id)).font(.system(size: 11))
                                        .foregroundColor(dark ? .white : .black)
                                    Spacer()
                                }
                            }
                        }
                        .padding(14).frame(width: 260).background(dark ? Color(white: 0.12) : Color(white: 0.95))
                    }
                }, name: "platform-glyphs", size: CGSize(width: 520, height: 512), dir: dir)
            }
            render(LogoBoard(model: model, p: p),
                   name: "logo-\(tag)", size: CGSize(width: 470, height: 300), dir: dir)
            // 明细截断时趋势条标「不完整」（硅基流动重度用户，整分支评审 I-2）
            if let days = model.data?.trend7 {
                renderFit(TrendStrip(chart: model.data!.tokenChart(main: .deepseek), days: days, onPick: { _ in }, p: p,
                                     incomplete: true).padding(16),
                          name: "trend-incomplete-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            }
            if let day = detailDay {
                let labels = Dictionary(uniqueKeysWithValues: (model.data?.models ?? []).map { ($0.key, $0.label) })
                renderFit(DayDetail(day: day, modelKey: detailKey, labels: labels, p: p),
                          name: "detail-\(tag)", width: 320, bg: bg, dir: dir)
            }
        }
        // 未登录控制台（只有余额）的面板
        if var d = model.data {
            d.today = AppData.CostTok(costCny: 0, tokens: 0, source: "只有余额")
            d.month = AppData.CostTok(costCny: 0, tokens: 0, source: "只有余额")
            d.models = []; d.trend7 = []
            let keep = model.data
            model.data = d
            for dark in [false, true] {
                model.themeMode = dark ? .dark : .light
                let p = Palette.of(dark)
                renderFit(PanelView(model: model, p: p), name: "panel-balanceonly-\(dark ? "dark" : "light")",
                          width: kPanelWidth, bg: LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom),
                          dir: dir)
            }
            model.data = keep
        }
        // 冷启动断网：显示磁盘上 25 分钟前的完整快照，标为离线旧数据
        do {
            let keepData = model.data, keepState = model.mainState
            let now = Date()
            let base = sampleData()
            var cached = PlatformState(id: .deepseek, snapshot: nil, burn: nil, status: .offline)
            cached.snapshot = ProviderSnapshot(provider: .deepseek, balance: Money(amount: 27.07, currency: .cny),
                                               today: Money(amount: Decimal(string: "6.27")!, currency: .cny),
                                               month: Money(amount: Decimal(string: "38.99")!, currency: .cny),
                                               byModel: [], trend7: [], source: .bill,
                                               fetchedAt: now.addingTimeInterval(-1500), credential: .ok)
            cached.snapshotFromDisk = true
            var d = previewData(main: cached, others: [], now: now, timeZone: .autoupdatingCurrent)
            d.models = base.models; d.trend7 = base.trend7      // 趋势与模型沿用示例数据，只为看版面
            model.data = d; model.mainState = cached
            for dark in [false, true] {
                model.themeMode = dark ? .dark : .light
                let tag = dark ? "dark" : "light"
                let p = Palette.of(dark)
                renderFit(PanelView(model: model, p: p), name: "panel-offline-cached-\(tag)", width: kPanelWidth,
                          bg: LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom), dir: dir)
                render(MenuInfoCard(model: model, hover: HoverState())
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .padding(.vertical, 6)
                        .background(dark ? Color(white: 0.17) : Color(white: 0.965)),
                       name: "menucard-offline-cached-\(tag)", size: CGSize(width: MenuCardHost.width, height: 150), dir: dir)
            }
            model.data = keepData; model.mainState = keepState
        }
        // 首次引导 5 步 + 设置「平台」页（没有平台、重新登录结果）
        let keepState = model.mainState, keepSetup = model.needsSetup
        let snap = ProviderSnapshot(provider: .deepseek, balance: Money(amount: 27.07, currency: .cny),
                                    today: nil, month: nil, byModel: [], trend7: [], source: .bill,
                                    fetchedAt: Date(timeIntervalSince1970: 1_792_000_000), credential: .ok)
        for dark in [false, true] {
            model.themeMode = dark ? .dark : .light
            let tag = dark ? "dark" : "light"
            let p = Palette.of(dark)
            let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)
            for step in [OnboardingStep.welcome, .pick, .menubar, .login, .done] {
                renderFit(OnboardingView(model: model, initialStep: step, p: p), name: "onboarding-\(step.rawValue)-\(tag)",
                          width: 420, bg: bg, dir: dir)
            }
            // 第二期新增：所有平台都勾选的选平台页
            renderFit(OnboardingView(model: model, initialStep: .pick, p: p,
                                     preview: OnboardingPreview(picked: Set(ProviderRegistry.all))),
                      name: "onboarding-pick-\(tag)", width: 420, bg: bg, dir: dir)
            // 用户 11/6 选乙：老用户进来是管理页（已添加写读数 + 移除，可添加写说明 + 添加）
            let readings: [ProviderID: AccountReading] = [.deepseek: .money(5.35, currency: "CNY"), .siliconflow: .money(9.05, currency: "CNY"),
                                                          .kimi: .money(15, currency: "CNY"), .openrouter: .keyLimit(12.4, currency: "USD"),
                                                          .packyapi: .money(108.32, currency: "CNY"),
                                                          .codexPlan: .session(90), .claudePlan: .session(59), .geminiPlan: .session(92)]
            renderFit(OnboardingView(model: model, initialStep: .pick, p: p,
                                     preview: OnboardingPreview(picked: Set(ProviderRegistry.all), added: Set(ProviderRegistry.all),
                                                                readings: readings)),
                      name: "onboarding-manage-all-\(tag)", width: 420, bg: bg, dir: dir)
            renderFit(OnboardingView(model: model, initialStep: .pick, p: p,
                                     preview: OnboardingPreview(picked: [.deepseek, .claudePlan], added: [.deepseek], readings: readings)),
                      name: "onboarding-manage-mixed-\(tag)", width: 420, bg: bg, dir: dir)
            // 管理页：已添加 DeepSeek、Codex 套餐
            renderFit(OnboardingView(model: model, initialStep: .pick, p: p,
                                     preview: OnboardingPreview(picked: [.deepseek], added: [.deepseek, .codexPlan], readings: readings)),
                      name: "onboarding-manage-two-\(tag)", width: 420, bg: bg, dir: dir)
            // 管理页：硅基流动登录失效时写橙色原因
            renderFit(OnboardingView(model: model, initialStep: .pick, p: p,
                                     preview: OnboardingPreview(picked: Set(ProviderRegistry.all),
                                                                added: [.deepseek, .siliconflow, .codexPlan],
                                                                states: [.siliconflow: .invalid], readings: readings)),
                      name: "onboarding-manage-states-\(tag)", width: 420, bg: bg, dir: dir)
            // 管理页：Kimi 暂时隐藏（用户 11/6 选 proposal-hide-platform 乙）：写「已隐藏 · 不刷新」，多一个「显示」
            renderFit(OnboardingView(model: model, initialStep: .pick, p: p,
                                     preview: OnboardingPreview(picked: Set(ProviderRegistry.all),
                                                                added: [.deepseek, .kimi, .codexPlan],
                                                                states: [.kimi: .hidden], readings: readings)),
                      name: "onboarding-manage-hidden-\(tag)", width: 420, bg: bg, dir: dir)
            // OpenRouter（11/6 新平台）：管理页已添加写美元读数；登录页只填 API Key，底部说明 UTC 日界和普通 Key 看不到余额
            renderFit(OnboardingView(model: model, initialStep: .pick, p: p,
                                     preview: OnboardingPreview(picked: [.deepseek, .openrouter], added: [.deepseek, .openrouter],
                                                                readings: readings)),
                      name: "onboarding-manage-openrouter-\(tag)", width: 420, bg: bg, dir: dir)
            renderFit(OnboardingView(model: model, initialStep: .login, p: p, only: .openrouter),
                      name: "onboarding-login-openrouter-\(tag)", width: 420, bg: bg, dir: dir)
            // PackyAPI（11/9 新平台，用户选甲）：登录页填用户 ID + 系统访问令牌，底部说明为什么不用 API Key、按人民币显示
            renderFit(OnboardingView(model: model, initialStep: .login, p: p, only: .packyapi),
                      name: "onboarding-login-packyapi-\(tag)", width: 420, bg: bg, dir: dir)
            renderFit(OnboardingView(model: model, initialStep: .login, p: p, only: .geminiPlan),
                      name: "onboarding-login-gemini-\(tag)", width: 420, bg: bg, dir: dir)
            // 没有添加任何平台的设置（平台页只有「＋ 添加平台」）
            model.mainState = nil; model.needsSetup = true
            renderSettings(model, page: .platform, input: nil, name: "settings-platform-empty-\(tag)", p: p, bg: bg, dir: dir)
            model.mainState = keepState; model.needsSetup = keepSetup
            let multi = multiPlatformInput(snap: snap)
            // 四个平台都勾上时的「菜单栏显示哪个平台」：自动跟随在最前、默认选中，五行要放得下
            renderFit(OnboardingView(model: model, initialStep: .menubar, p: p,
                                     preview: OnboardingPreview(picked: Set(ProviderRegistry.all))),
                      name: "onboarding-menubar-all-\(tag)", width: 420, bg: bg, dir: dir)
            // 重新登录的结果：硅基流动验证没通过（橙）、DeepSeek 控制台重新登录成功（绿）
            model.reloginNotes = [
                .siliconflow: ReloginNote.make(ok: false, message: L("valid.sfLoginFailed")),
                .deepseek: ReloginNote.make(ok: true, message: L("relogin.signedIn"))]
            renderSettings(model, page: .platform, input: multi, name: "settings-relogin-\(tag)", p: p, bg: bg, dir: dir)
            model.reloginNotes = [:]
            model.mainState = nil; model.needsSetup = true
            let keepData = model.data; model.data = nil
            renderFit(PanelView(model: model, p: p), name: "panel-empty-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            // 添加过的平台全都隐藏了：写「平台都隐藏了」+ 显示入口，不是「添加第一个平台」
            model.hiddenIDs = [.deepseek, .kimi]
            renderFit(PanelView(model: model, p: p), name: "panel-allhidden-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            model.hiddenIDs = []
            model.data = keepData
        }
        model.mainState = keepState; model.needsSetup = keepSetup
        model.themeMode = originalTheme
        renderMultiPlatform(model: model, dir: dir, originalTheme: originalTheme)
        renderQuota(model: model, dir: dir, originalTheme: originalTheme)
        renderExhausted(model: model, dir: dir, originalTheme: originalTheme)
        renderRunway(model: model, dir: dir)
        renderRunningTasks(model: model, dir: dir)
        renderAstryxCards(model: model, dir: dir)
        renderClaudePlan(model: model, dir: dir, originalTheme: originalTheme)
    }

    private static func renderAstryxCards(model: UsageModel, dir: URL) {
        let saved = (model.data, model.mainState, model.fixedNow, model.runningTasks, model.menuBarPaygActive)
        defer { (model.data, model.mainState, model.fixedNow, model.runningTasks, model.menuBarPaygActive) = saved }

        let now = sampleSnapshot().fetchedAt
        let zone = TimeZone(secondsFromGMT: 8 * 3600)!
        var deepseek = deepseekMainState(now: now)
        deepseek.burn?.runwayDays = 4
        var codex = quotaMainState(now: now)
        codex.snapshot?.quota?.windows[0].usedPercent = 100
        var claude = quotaMainState(now: now)
        claude.id = .claudePlan
        claude.snapshot?.provider = .claudePlan

        var data = AppDataMapping.appData(main: deepseek, others: [codex, claude], now: now, timeZone: zone)
        data.yesterdaySameTimeCny = data.totalTodayCny.map { $0 / 1.32 }
        model.data = data
        model.mainState = deepseek
        model.fixedNow = now
        model.menuBarPaygActive = [.deepseek]
        model.runningTasks = [
            RunningTask(provider: .claudePlan, sessionKey: "astryx", project: "token-bar", model: "opus",
                        startedAt: now.addingTimeInterval(-480), lastActivity: now.addingTimeInterval(-8), tokens: 12_300)
        ]
        for dark in [false, true] {
            let p = Palette.of(dark)
            let tag = dark ? "dark" : "light"
            let scheme: ColorScheme = dark ? .dark : .light
            renderFit(TodayGrid(model: model, d: data, p: p).padding(12).environment(\.colorScheme, scheme),
                      name: "astryx-today-\(tag)", width: kPanelWidth, bg: p.bgTop, dir: dir)
            renderFit(MenuInfoCard(model: model, hover: HoverState()).environment(\.colorScheme, scheme),
                      name: "astryx-menu-\(tag)", width: MenuCardHost.width,
                      bg: dark ? Color(white: 0.17) : Color(white: 0.965), dir: dir)
        }
    }

    /// 第三期 Task 8 新增预览：Claude 套餐的安装确认页 / settings.json 解析不了 / 状态栏钩子不在了，
    /// 以及账号行（钩子不在了、移除后没能还原的说明）。全部用预览数据，不运行安装器
    static func renderClaudePlan(model: UsageModel, dir: URL, originalTheme: UsageModel.ThemeMode) {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let tz = TimeZone(secondsFromGMT: 28800)!
        var claude = quotaMainState(now: now)
        claude.id = .claudePlan
        claude.snapshot?.provider = .claudePlan
        claude.snapshot?.quota?.plan = nil
        let deepseek = deepseekMainState(now: now)

        let keepData = model.data, keepState = model.mainState, keepSide = model.menuBarSide
        let keepAlert = model.renderAlert, keepHook = model.claudeHookState, keepNotes = model.reloginNotes
        model.renderAlert = 10
        model.fixedNow = now
        model.menuBarSide = nil
        model.themeMode = .light
        let p = Palette.of(false)
        let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)

        // 选了「终端版」之后的三页（安装确认 / 已安装还差一步 / settings.json 解析不了）
        renderFit(OnboardingView(model: model, initialStep: .login, p: p, only: .claudePlan,
                                 preview: OnboardingPreview(picked: [.claudePlan], claudeChoice: .terminal)),
                  name: "claude-install-confirm", width: 420, bg: bg, dir: dir)
        renderFit(OnboardingView(model: model, initialStep: .login, p: p, only: .claudePlan,
                                 preview: OnboardingPreview(picked: [.claudePlan], claudeInstalled: true, claudeChoice: .terminal)),
                  name: "claude-terminal-step", width: 420, bg: bg, dir: dir)
        renderFit(OnboardingView(model: model, initialStep: .login, p: p, only: .claudePlan,
                                 preview: OnboardingPreview(picked: [.claudePlan], claudeSnippet: ClaudeStatusLineInstaller.preview.manualSnippet,
                                                            claudeChoice: .terminal)),
                  name: "claude-unparseable", width: 420, bg: bg, dir: dir)

        model.claudeHookState = .replaced
        model.data = previewData(main: claude, others: [deepseek], now: now, timeZone: tz); model.mainState = claude
        renderFit(PanelView(model: model, p: p), name: "claude-hook-gone", width: kPanelWidth, bg: bg, dir: dir)
        // 保留旧额度：15 分钟变灰，3 分钟仍可用；这里只注册预览，不触发查询。
        let beforeStaleHook = model.claudeHookState
        model.claudeHookState = .installed
        for minutes in [15, 3] {
            var stale = claude
            stale.status = .stale(minutes: minutes)
            stale.snapshot?.fetchedAt = now.addingTimeInterval(Double(-minutes * 60))
            model.data = previewData(main: stale, others: [deepseek], now: now, timeZone: tz)
            model.mainState = stale
            renderFit(PanelView(model: model, p: p), name: minutes == 15 ? "claude-stale" : "claude-stale-fresh",
                      width: kPanelWidth, bg: bg, dir: dir)
            if minutes == 15 {
                render(MenuInfoCard(model: model, hover: HoverState()).environment(\.colorScheme, .light)
                        .padding(.vertical, 6).background(Color(white: 0.965)),
                       name: "claude-stale-menucard", size: CGSize(width: MenuCardHost.width, height: 180), dir: dir)
            }
        }
        model.claudeHookState = beforeStaleHook
        // 每周额度比 5 小时更紧：保留各窗口重置时间，并在预览后恢复现场。
        do {
            let beforeWeeklyData = model.data, beforeWeeklyState = model.mainState
            let beforeWeeklyHook = model.claudeHookState
            defer {
                model.data = beforeWeeklyData; model.mainState = beforeWeeklyState
                model.claudeHookState = beforeWeeklyHook
            }
            var weeklyTighter = claude
            weeklyTighter.snapshot?.quota?.windows = claude.snapshot?.quota?.windows.map { window in
                var updated = window
                switch window.kind {
                case .session: updated.usedPercent = 20
                case .weekly: updated.usedPercent = 85
                case .weeklyModel: break
                }
                return updated
            } ?? []
            model.claudeHookState = .installed
            model.data = previewData(main: weeklyTighter, others: [deepseek], now: now, timeZone: tz)
            model.mainState = weeklyTighter
            renderFit(PanelView(model: model, p: p), name: "claude-weekly-tighter",
                      width: kPanelWidth, bg: bg, dir: dir)
            render(MenuInfoCard(model: model, hover: HoverState()).environment(\.colorScheme, .light)
                    .padding(.vertical, 6).background(Color(white: 0.965)),
                   name: "claude-weekly-tighter-menucard", size: CGSize(width: MenuCardHost.width, height: 180), dir: dir)
            render(MenuBarPreview(model: model, quota: true), name: "claude-weekly-tighter-menubar",
                   size: CGSize(width: 300, height: 286), dir: dir)
            // DeepSeek 作主平台，检查其他平台行里的 Claude 每周额度。
            model.data = previewData(main: deepseek, others: [weeklyTighter], now: now, timeZone: tz)
            model.mainState = deepseek
            renderFit(PanelView(model: model, p: p), name: "claude-weekly-tighter-side",
                      width: kPanelWidth, bg: bg, dir: dir)
        }
        model.data = previewData(main: claude, others: [deepseek], now: now, timeZone: tz)
        model.mainState = claude
        // 第三批反馈第 4 条：Claude 套餐在菜单栏写当前会话已用百分比（余额/用量、今日花费两种模式一样）
        render(MenuBarPreview(model: model, quota: true), name: "claude-menubar", size: CGSize(width: 300, height: 286), dir: dir)

        var settings = ProviderSettings()
        settings.lowAlerts = [.deepseek: 10, .claudePlan: 10]
        let added = AccountsInput(platforms: [deepseek, claude], mainID: .claudePlan, auto: true, settings: settings)
        renderSettings(model, page: .platform, input: added, name: "claude-settings-platform", p: p, bg: bg, dir: dir)
        // 移除时状态栏设置已被改过：没有还原，说明留在（已未添加的）账号行下
        model.claudeHookState = .notInstalled
        model.reloginNotes = [.claudePlan: ReloginNote(text: L("claude.sw.changedElsewhere"), isError: true)]
        let removed = AccountsInput(platforms: [deepseek], mainID: .deepseek, auto: true, settings: settings)
        renderSettings(model, page: .platform, input: removed, name: "claude-removed-note", p: p, bg: bg, dir: dir)

        model.reloginNotes = [:]
        renderClaudeDesktop(model: model, dir: dir, now: now, tz: tz, deepseek: deepseek, settings: settings)

        model.renderAlert = keepAlert
        model.fixedNow = nil
        model.claudeHookState = keepHook; model.reloginNotes = keepNotes
        model.data = keepData; model.mainState = keepState; model.menuBarSide = keepSide
        model.themeMode = originalTheme
    }

    /// 第七批：Claude 套餐的额度来源二选一。选来源页、桌面来源的添加结果、设置行、面板（推算的重置时间）、小组件。
    /// 钩子状态设成「被换掉了」：桌面来源时不该出现「状态栏钩子不在了」
    static func renderClaudeDesktop(model: UsageModel, dir: URL, now: Date, tz: TimeZone, deepseek: PlatformState,
                                    settings: ProviderSettings) {
        let keepSource = model.claudeSource, keepHook = model.claudeHookState, keepPage = model.widgetPage
        model.claudeSource = .desktop
        model.claudeHookState = .replaced
        let q = Quota(plan: nil, windows: [
            QuotaWindow(kind: .session, usedPercent: 41, resetsAt: now.addingTimeInterval(2 * 3600 + 13 * 60), windowMinutes: 300,
                        resetIsEstimated: true),
            QuotaWindow(kind: .weekly, usedPercent: 23, resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600), windowMinutes: 10080,
                        resetIsEstimated: true),
        ], observedAt: now.addingTimeInterval(-9 * 60))
        var snap = ProviderSnapshot(provider: .claudePlan, balance: nil, today: nil, month: nil, byModel: [], trend7: [],
                                    source: .quota, fetchedAt: now, credential: .ok)
        snap.quota = q
        let claude = PlatformState(id: .claudePlan, snapshot: snap, burn: nil, status: .ok, lastSampleAt: now, lastSample: nil)
        var noSnap = snap
        noSnap.quota = nil
        noSnap.quotaNote = ClaudePlanProvider.desktopWaitingNote
        let waiting = PlatformState(id: .claudePlan, snapshot: noSnap, burn: nil, status: .ok, lastSampleAt: now, lastSample: nil)

        for dark in [false, true] {
            model.themeMode = dark ? .dark : .light
            let tag = dark ? "dark" : "light"
            let p = Palette.of(dark)
            let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)
            renderFit(OnboardingView(model: model, initialStep: .login, p: p, only: .claudePlan),
                      name: "claude-source-pick-\(tag)", width: 420, bg: bg, dir: dir)
            renderFit(OnboardingView(model: model, initialStep: .login, p: p, only: .claudePlan,
                                     preview: OnboardingPreview(picked: [.claudePlan], claudeChoice: .desktop, claudeDesktopAdded: true)),
                      name: "claude-desktop-added-\(tag)", width: 420, bg: bg, dir: dir)
            // 用户 11/6：「登录 claude.ai」来源（登录前 / 登录好）；「用本机 Claude Code 查」没登录时的结果页（proposal-claude-source-copy 乙）
            renderFit(OnboardingView(model: model, initialStep: .login, p: p, only: .claudePlan,
                                     preview: OnboardingPreview(picked: [.claudePlan], claudeChoice: .web)),
                      name: "claude-web-login-\(tag)", width: 420, bg: bg, dir: dir)
            renderFit(OnboardingView(model: model, initialStep: .login, p: p, only: .claudePlan,
                                     preview: OnboardingPreview(picked: [.claudePlan], claudeChoice: .web, claudeWebDone: true)),
                      name: "claude-web-done-\(tag)", width: 420, bg: bg, dir: dir)
            renderFit(OnboardingView(model: model, initialStep: .login, p: p, only: .claudePlan,
                                     preview: OnboardingPreview(picked: [.claudePlan], claudeChoice: .desktop, claudeDesktopAdded: true,
                                                                claudeCLIResult: .needsLogin)),
                      name: "claude-desktop-needslogin-\(tag)", width: 420, bg: bg, dir: dir)
            let added = AccountsInput(platforms: [deepseek, claude], mainID: .claudePlan, auto: true, settings: settings)
            renderSettings(model, page: .platform, input: added, name: "claude-desktop-settings-\(tag)", p: p, bg: bg, dir: dir)
            let keepSource = model.claudeSource
            model.claudeSource = .web
            renderSettings(model, page: .platform, input: added, name: "claude-web-settings-\(tag)", p: p, bg: bg, dir: dir)
            model.claudeSource = keepSource
            model.data = previewData(main: claude, others: [deepseek], now: now, timeZone: tz); model.mainState = claude
            renderFit(PanelView(model: model, p: p), name: "claude-desktop-panel-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            model.widgetPage = "balance"
            renderFit(WidgetView(model: model), name: "claude-desktop-widget-\(tag)", width: 270, bg: bg, dir: dir)
        }
        model.themeMode = .light
        let p = Palette.of(false)
        let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)
        renderFit(OnboardingView(model: model, initialStep: .login, p: p, only: .claudePlan,
                                 preview: OnboardingPreview(picked: [.claudePlan], claudeChoice: .desktop, claudeDesktopAdded: true,
                                                            claudeDesktopHasData: true)),
                  name: "claude-desktop-added-hasdata", width: 420, bg: bg, dir: dir)
        renderFit(OnboardingView(model: model, initialStep: .login, p: p, only: .claudePlan,
                                 preview: OnboardingPreview(picked: [.claudePlan], claudeChoice: .desktop, claudeDesktopAdded: true,
                                                            claudeDesktopHasData: true, claudeDesktopViaCLI: true)),
                  name: "claude-desktop-added-cli", width: 420, bg: bg, dir: dir)
        // 固定示例时间；不读取本机记录，也不运行命令行。
        var staleSnap = noSnap
        staleSnap.quotaNote = ClaudePlanProvider.staleNote(Date(timeIntervalSince1970: 1_791_988_620), now: now, timeZone: tz)
            + L("common.sentenceSep") + ClaudePlanProvider.cliMissingHint
        let stale = PlatformState(id: .claudePlan, snapshot: staleSnap, burn: nil, status: .ok, lastSampleAt: now, lastSample: nil)
        model.data = previewData(main: stale, others: [deepseek], now: now, timeZone: tz); model.mainState = stale
        renderFit(PanelView(model: model, p: p), name: "claude-desktop-stale", width: kPanelWidth, bg: bg, dir: dir)
        let addedWaiting = AccountsInput(platforms: [deepseek, waiting], mainID: .claudePlan, auto: true, settings: settings)
        renderSettings(model, page: .platform, input: addedWaiting, name: "claude-desktop-settings-nodata", p: p, bg: bg, dir: dir)
        model.data = previewData(main: waiting, others: [deepseek], now: now, timeZone: tz); model.mainState = waiting
        renderFit(PanelView(model: model, p: p), name: "claude-desktop-nodata", width: kPanelWidth, bg: bg, dir: dir)
        render(MenuInfoCard(model: model, hover: HoverState()).environment(\.colorScheme, .light)
                .padding(.vertical, 6).background(Color(white: 0.965)),
               name: "claude-desktop-nodata-menucard", size: CGSize(width: MenuCardHost.width, height: 180), dir: dir)
        model.claudeSource = keepSource; model.claudeHookState = keepHook; model.widgetPage = keepPage
    }

    /// 第三期 Task 5 新增预览：Codex 套餐作主平台的大油箱 / 没有额度数据 / 辅助行 / 菜单栏 / 右键卡 / 小组件 / 设置 / 引导
    static func renderQuota(model: UsageModel, dir: URL, originalTheme: UsageModel.ThemeMode) {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let tz = TimeZone(secondsFromGMT: 28800)!
        let codex = quotaMainState(now: now), deepseek = deepseekMainState(now: now)
        var noData = codex
        noData.snapshot?.quota = nil
        noData.snapshot?.quotaNote = CodexPlanProvider.noDataNote
        let mainOnly = previewData(main: codex, others: [], now: now, timeZone: tz)
        let withSide = previewData(main: codex, others: [deepseek], now: now, timeZone: tz)

        let keepData = model.data, keepState = model.mainState, keepSide = model.menuBarSide, keepPage = model.widgetPage
        let keepAlert = model.renderAlert
        // 预警线按套餐的默认 10%；只改镜像，不回写用户设置
        model.renderAlert = 10
        model.fixedNow = now
        model.menuBarSide = nil
        for dark in [false, true] {
            model.themeMode = dark ? .dark : .light
            let p = Palette.of(dark)
            let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)
            model.data = mainOnly; model.mainState = codex
            renderFit(PanelView(model: model, p: p), name: "quota-main-\(dark ? "dark" : "light")", width: kPanelWidth, bg: bg, dir: dir)
        }
        model.themeMode = .light
        let p = Palette.of(false)
        let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)

        model.data = previewData(main: noData, others: [], now: now, timeZone: tz); model.mainState = noData
        renderFit(PanelView(model: model, p: p), name: "quota-nodata", width: kPanelWidth, bg: bg, dir: dir)

        // 主平台 DeepSeek，辅助行里有 Codex 套餐
        model.data = previewData(main: deepseek, others: [codex], now: now, timeZone: tz); model.mainState = deepseek
        renderFit(PanelView(model: model, p: p), name: "quota-side-row", width: kPanelWidth, bg: bg, dir: dir)

        model.data = withSide; model.mainState = codex
        render(MenuBarPreview(model: model, quota: true), name: "quota-menubar", size: CGSize(width: 300, height: 286), dir: dir)
        render(MenuInfoCard(model: model, hover: HoverState()).environment(\.colorScheme, .light)
                .padding(.vertical, 6).background(Color(white: 0.965)),
               name: "quota-menucard", size: CGSize(width: MenuCardHost.width, height: 150), dir: dir)
        model.widgetPage = "balance"
        renderFit(WidgetView(model: model), name: "quota-widget", width: 270, bg: bg, dir: dir)
        model.themeMode = .dark
        let pd = Palette.of(true)
        renderFit(WidgetView(model: model), name: "quota-widget-dark", width: 270,
                  bg: LinearGradient(colors: [pd.bgTop, pd.bgBottom], startPoint: .top, endPoint: .bottom), dir: dir)
        model.themeMode = .light
        // 只有一个窗口、没有套餐名（类似 Claude 套餐）
        var single = codex
        single.snapshot?.quota?.plan = nil
        single.snapshot?.quota?.windows.removeLast()
        model.data = previewData(main: single, others: [deepseek], now: now, timeZone: tz); model.mainState = single
        renderFit(WidgetView(model: model), name: "quota-widget-single", width: 270, bg: bg, dir: dir)
        model.data = withSide; model.mainState = codex

        var settings = ProviderSettings()
        settings.lowAlerts = [.deepseek: 10, .codexPlan: 10]
        let accounts = AccountsInput(platforms: [deepseek, codex], mainID: .codexPlan, auto: true, settings: settings)
        // 主平台是套餐：油箱按百分比，没有「油箱满盘」
        model.data = mainOnly
        renderSettings(model, page: .alerts, input: accounts, name: "settings-alerts-quota", p: p, bg: bg, dir: dir, alert: 10)
        renderFit(OnboardingView(model: model, initialStep: .login, p: p, only: .codexPlan), name: "quota-onboarding-login",
                  width: 420, bg: bg, dir: dir)

        model.renderAlert = keepAlert
        model.fixedNow = nil
        model.data = keepData; model.mainState = keepState; model.menuBarSide = keepSide; model.widgetPage = keepPage
        model.themeMode = originalTheme
    }

    /// 预览只使用合成状态；涨幅直接传给纯函数，不读取 UsageStore 的采样或本机记录。
    static func previewData(main: PlatformState, others: [PlatformState], now: Date, timeZone: TimeZone,
                            localUsage: [ProviderID: DailyModelTokens] = [:],
                            quotaRise: [ProviderID: Double] = [:], below: Set<ProviderID> = []) -> AppData {
        var d = AppDataMapping.appData(main: main, others: others, now: now, timeZone: timeZone, localUsage: localUsage)
        let risks = RiskRanker.rank(([main] + others).map { st in
            RiskInput(id: st.id, status: st.status,
                      payg: Runway.payg(balance: st.snapshot?.balance?.amount, burn: st.burn),
                      quota: Runway.quota(st.snapshot?.quota, risePP: quotaRise[st.id], now: now), belowThreshold: below.contains(st.id))
        })
        AppDataMapping.applyRisks(&d, main: main.id, risks: risks, now: now, timeZone: timeZone, currency: d.balance.currency)
        return d
    }

    static func renderRunway(model: UsageModel, dir: URL) {
        let keepData = model.data, keepState = model.mainState, keepSide = model.menuBarSide
        let keepNow = model.fixedNow, keepTheme = model.themeMode, keepNotice = model.switchNotice
        let keepPinned = model.mainPinned, keepDetail = model.detailOpen
        defer {
            model.data = keepData; model.mainState = keepState; model.menuBarSide = keepSide
            model.fixedNow = keepNow; model.themeMode = keepTheme; model.switchNotice = keepNotice
            model.mainPinned = keepPinned; model.detailOpen = keepDetail
        }
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let tz = TimeZone(secondsFromGMT: 28800)!
        var deepseek = deepseekMainState(now: now)
        deepseek.burn = BurnStats(perHourRecent: Decimal(string: "4.80"), perHourDay: Decimal(string: "0.225"),
                                 avgPerDayWeek: Decimal(string: "5.40")!, runwayDays: 5, spike: true)
        var normal = deepseek
        normal.burn?.perHourRecent = Decimal(string: "0.225"); normal.burn?.spike = false
        var claude = quotaMainState(now: now)
        claude.id = .claudePlan; claude.snapshot?.provider = .claudePlan
        claude.snapshot?.quota = Quota(plan: nil, windows: [
            QuotaWindow(kind: .session, usedPercent: 88, resetsAt: now.addingTimeInterval(7200), windowMinutes: 300),
            QuotaWindow(kind: .weekly, usedPercent: 39, resetsAt: now.addingTimeInterval(3 * 86400), windowMinutes: 10080)
        ], observedAt: now)
        let codex = quotaMainState(now: now)
        let sfSnap = ProviderSnapshot(provider: .siliconflow, balance: Money(amount: 12, currency: .cny),
                                      today: Money(amount: 0.5, currency: .cny), month: Money(amount: 18.4, currency: .cny),
                                      byModel: [], trend7: [], source: .bill, fetchedAt: now, credential: .ok)
        let sf = PlatformState(id: .siliconflow, snapshot: sfSnap,
                               burn: BurnStats(perHourRecent: 0.05, perHourDay: 0.075, avgPerDayWeek: 1.8,
                                               runwayDays: 6.7, spike: false), status: .ok)
        var sfLow = sf
        sfLow.burn?.perHourRecent = 4; sfLow.burn?.spike = true   // 用量突增 ¥4/时：¥12 约 3 小时用完 → 按量付费风险出横幅
        model.fixedNow = now; model.menuBarSide = nil; model.switchNotice = nil
        model.mainPinned = false; model.detailOpen = false
        for dark in [false, true] {
            model.themeMode = dark ? .dark : .light
            let tag = dark ? "dark" : "light"
            let p = Palette.of(dark)
            let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)
            for (name, main, others) in [
                ("panel-runway-spike", deepseek, [sf, codex, claude]),
                ("panel-runway-quota", claude, [normal, sf, codex]),
                // 2026-11-06 起套餐平台不出顶部横幅：用快没钱的硅基流动验证横幅样式
                ("panel-risk-banner", normal, [sfLow, codex, claude])
            ] {
                model.mainState = main
                model.data = previewData(main: main, others: others, now: now, timeZone: tz,
                                         quotaRise: [.claudePlan: 18, .codexPlan: 2])
                renderFit(PanelView(model: model, p: p), name: "\(name)-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
                if name == "panel-runway-spike" {
                    renderFit(MenuInfoCard(model: model, hover: HoverState())
                        .environment(\.colorScheme, dark ? .dark : .light),
                        name: "menucard-risk-\(tag)", width: MenuCardHost.width,
                        bg: dark ? Color(white: 0.17) : Color(white: 0.965), dir: dir)
                }
            }
        }
        // 套餐低于预警线、近 1 小时没用（11/6 round7-scout 第 2 条乙）：表盘下胶囊写「低于预警线」（红）
        model.themeMode = .light
        let keepPage = model.widgetPage
        model.widgetPage = "balance"
        model.mainState = claude
        model.data = previewData(main: claude, others: [normal], now: now, timeZone: tz, below: [.claudePlan])
        renderFit(WidgetView(model: model), name: "quota-below-widget", width: 270, bg: Color(white: 0.95), dir: dir)
        model.widgetPage = keepPage
    }

    /// 正在跑的任务：面板 1 个 / 4 个（含停住、「还有 1 个」）、右键卡
    static func renderRunningTasks(model: UsageModel, dir: URL) {
        let keepData = model.data, keepState = model.mainState, keepSide = model.menuBarSide
        let keepNow = model.fixedNow, keepTheme = model.themeMode, keepNotice = model.switchNotice
        let keepPinned = model.mainPinned, keepDetail = model.detailOpen, keepTasks = model.runningTasks
        defer {
            model.data = keepData; model.mainState = keepState; model.menuBarSide = keepSide
            model.fixedNow = keepNow; model.themeMode = keepTheme; model.switchNotice = keepNotice
            model.mainPinned = keepPinned; model.detailOpen = keepDetail; model.runningTasks = keepTasks
        }
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let tz = TimeZone(secondsFromGMT: 28800)!
        func task(_ id: ProviderID, _ key: String, _ project: String, _ model: String?, started: TimeInterval,
                  last: TimeInterval, tokens: Int) -> RunningTask {
            RunningTask(provider: id, sessionKey: key, project: project, model: model, startedAt: now.addingTimeInterval(-started),
                        lastActivity: now.addingTimeInterval(-last), tokens: tokens)
        }
        let one = [task(.claudePlan, "a", "token-bar", "opus 4.7", started: 724, last: 8, tokens: 18_234)]
        let four = [task(.claudePlan, "b", "token-bar", "opus 4.7", started: 2530, last: 8, tokens: 41_320),
                    task(.codexPlan, "c", "api-server", "gpt-5.5", started: 1260, last: 420, tokens: 6_870),
                    task(.claudePlan, "d", "notes", "sonnet 4.5", started: 221, last: 3, tokens: 950),
                    task(.codexPlan, "e", "my-site", "gpt-5.5", started: 40, last: 2, tokens: 0)]
        let deepseek = deepseekMainState(now: now)
        let codex = quotaMainState(now: now)
        let sfSnap = ProviderSnapshot(provider: .siliconflow, balance: Money(amount: 12, currency: .cny),
                                      today: Money(amount: 0.5, currency: .cny), month: Money(amount: 18.4, currency: .cny),
                                      byModel: [], trend7: [], source: .bill, fetchedAt: now, credential: .ok)
        let sf = PlatformState(id: .siliconflow, snapshot: sfSnap,
                               burn: BurnStats(perHourRecent: 0.05, perHourDay: 0.075, avgPerDayWeek: 1.8,
                                               runwayDays: 6.7, spike: false), status: .ok)
        model.fixedNow = now; model.menuBarSide = nil; model.switchNotice = nil
        model.mainPinned = false; model.detailOpen = false
        for dark in [false, true] {
            model.themeMode = dark ? .dark : .light
            let tag = dark ? "dark" : "light"
            let p = Palette.of(dark)
            let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)
            for (name, main, others, tasks) in [
                ("running-panel-1", codex, [PlatformState](), one),
                ("running-panel-4", deepseek, [sf, codex], four)
            ] {
                model.mainState = main
                model.runningTasks = tasks
                model.data = previewData(main: main, others: others, now: now, timeZone: tz)
                renderFit(PanelView(model: model, p: p), name: "\(name)-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
                if name == "running-panel-4" {
                    renderFit(MenuInfoCard(model: model, hover: HoverState())
                        .environment(\.colorScheme, dark ? .dark : .light),
                        name: "running-menucard-\(tag)", width: MenuCardHost.width,
                        bg: dark ? Color(white: 0.17) : Color(white: 0.965), dir: dir)
                }
            }
        }
    }

    /// 预览用的 Codex 套餐：5 小时窗口已用 41%（2 小时 13 分后重置）、本周已用 23%（3 天后重置），12 分钟前用过
    static func quotaMainState(now: Date) -> PlatformState {
        let q = Quota(plan: "plus", windows: [
            QuotaWindow(kind: .session, usedPercent: 41, resetsAt: now.addingTimeInterval(2 * 3600 + 13 * 60), windowMinutes: 300),
            QuotaWindow(kind: .weekly, usedPercent: 23, resetsAt: now.addingTimeInterval(3 * 86400), windowMinutes: 10080),
        ], observedAt: now.addingTimeInterval(-12 * 60))
        var s = ProviderSnapshot(provider: .codexPlan, balance: nil, today: nil, month: nil, byModel: [], trend7: [],
                                 source: .quota, fetchedAt: now, credential: .ok)
        s.quota = q
        return PlatformState(id: .codexPlan, snapshot: s, burn: nil, status: .ok, lastSampleAt: now, lastSample: nil)
    }

    /// 第二期 Task 8 新增预览：多平台面板 / 切换提示 / 右键卡 / 小组件无模型明细
    static func renderMultiPlatform(model: UsageModel, dir: URL, originalTheme: UsageModel.ThemeMode) {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let tz = TimeZone(secondsFromGMT: 28800)!
        func m(_ v: String) -> Money { Money(amount: Decimal(string: v)!, currency: .cny) }
        func st(_ id: ProviderID, _ status: PlatformStatus, balance: Money? = nil, today: Money?,
                credential: CredentialState = .ok) -> PlatformState {
            let s = ProviderSnapshot(provider: id, balance: balance, today: today, month: m("18.40"),
                                     byModel: [], trend7: [], source: .bill, fetchedAt: now, credential: credential)
            return PlatformState(id: id, snapshot: s, burn: nil, status: status, lastSampleAt: now, lastSample: nil)
        }
        let sf = st(.siliconflow, .ok, balance: m("12.00"), today: m("0.50"), credential: .expiring(days: 2))
        let codex = quotaMainState(now: now)
        let claudePlan = PlatformState(id: .claudePlan, snapshot: nil, burn: nil, status: .offline)
        // 多平台：主 DeepSeek（示例数据），辅助 硅基流动（登录快到期）/ Codex 套餐（额度）/ Claude 套餐（连不上）
        let multi = previewData(main: deepseekMainState(now: now), others: [sf, codex, claudePlan], now: now, timeZone: tz)
        // 硅基流动为主（自动切过去之后），有模型明细与趋势
        let qm = ModelUsage(model: "Qwen/Qwen3-Coder-480B", cacheHit: 0, cacheMiss: 3_900_000, output: 96_000, requests: 58, cost: m("1.20"))
        var ss = sf.snapshot!
        ss.today = m("1.20")
        ss.byModel = [qm]
        ss.trend7 = ["2026-10-09", "2026-10-10", "2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15"].enumerated().map {
            DayUsage(day: $1, tokens: $0 == 6 ? 3_996_000 : 1_000_000 * Int($0), cost: m($0 == 6 ? "1.20" : "0.\($0)0"))
        }
        var sfMain = sf; sfMain.snapshot = ss
        sfMain.burn = BurnStats(perHourRecent: Decimal(string: "0.05"), perHourDay: Decimal(string: "0.08"),
                                avgPerDayWeek: Decimal(string: "1.80")!, runwayDays: Decimal(string: "6.7"), spike: false)
        var sfData = previewData(main: sfMain, others: [deepseekMainState(now: now), codex], now: now, timeZone: tz)
        sfData.trend7 = sfData.trend7.map { var d = $0; d.byModel = [qm.model: d.totalTokens]; return d }
        // 硅基流动为主、没有模型明细（小组件 Token 页）
        var noModels = previewData(main: st(.siliconflow, .ok, balance: m("12.00"), today: m("1.20")),
                                              others: [], now: now, timeZone: tz)
        noModels.models = []

        let keepData = model.data, keepState = model.mainState, keepSide = model.menuBarSide, keepPage = model.widgetPage
        for dark in [true, false] {
            model.themeMode = dark ? .dark : .light
            let tag = dark ? "dark" : "light"
            let p = Palette.of(dark)
            let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)
            let cardBG = dark ? Color(white: 0.17) : Color(white: 0.965)

            model.data = multi; model.mainState = deepseekMainState(now: now)
            renderFit(PanelView(model: model, p: p), name: "panel-multi-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            render(MenuInfoCard(model: model, hover: HoverState()).environment(\.colorScheme, dark ? .dark : .light)
                    .padding(.vertical, 6).background(cardBG),
                   name: "menucard-multi-\(tag)", size: CGSize(width: MenuCardHost.width, height: 230), dir: dir)
            model.widgetPage = "balance"
            renderFit(WidgetView(model: model), name: "widget-multi-\(tag)", width: 270, bg: bg, dir: dir)
            // 多平台时主平台出问题：标题后面照样写出状态文字，不只靠色点
            var badMain = deepseekMainState(now: now); badMain.status = .credentialInvalid
            model.mainState = badMain
            renderFit(WidgetView(model: model), name: "widget-multi-relogin-\(tag)", width: 270, bg: bg, dir: dir)
            model.mainState = deepseekMainState(now: now)
            // 读不到钥匙串（11/6 proposal-keychain-error-ui 乙）：横幅带「重试」；只是锁着时不带
            let denied = [PlatformState(id: .deepseek, snapshot: nil, burn: nil, status: .keychainUnreadable(status: -128)),
                          PlatformState(id: .kimi, snapshot: nil, burn: nil, status: .keychainUnreadable(status: -128))]
            model.keychainBanner = StatusPresenter.keychainBanner(denied)
            renderFit(PanelView(model: model, p: p), name: "panel-keychain-denied-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            if !dark {
                model.keychainBanner = StatusPresenter.keychainBanner([PlatformState(id: .deepseek, snapshot: nil, burn: nil,
                                                                                     status: .keychainUnreadable(status: -25308))])
                renderFit(PanelView(model: model, p: p), name: "panel-keychain-locked-light", width: kPanelWidth, bg: bg, dir: dir)
            }
            model.keychainBanner = nil

            // 切换提示（自动切到硅基流动后第一次打开面板）与「已固定」
            model.data = sfData; model.mainState = sfMain
            model.switchNotice = L("switch.noticePayg", ProviderRegistry.displayName(.siliconflow))  // 同 UsageStore.pendingSwitchNotice
            renderFit(PanelView(model: model, p: p), name: "panel-switch-notice-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            model.switchNotice = nil
            model.mainPinned = true
            renderFit(PanelView(model: model, p: p), name: "panel-pinned-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            model.mainPinned = false

            model.data = noModels; model.mainState = st(.siliconflow, .ok, balance: m("12.00"), today: m("1.20"))
            model.widgetPage = "tokens"
            renderFit(WidgetView(model: model), name: "widget-tokens-nomodels-\(tag)", width: 270, bg: bg, dir: dir)
            model.widgetPage = keepPage
        }
        model.data = keepData; model.mainState = keepState; model.menuBarSide = keepSide; model.widgetPage = keepPage
        model.themeMode = originalTheme
        renderToday(model: model, dir: dir)
        renderTokenChart(model: model, dir: dir, originalTheme: originalTheme)
        renderTrendPick(model: model, dir: dir, originalTheme: originalTheme)
        renderTrendAllModels(model: model, dir: dir, originalTheme: originalTheme)
        renderClaudeLogin(model: model, dir: dir, originalTheme: originalTheme)
    }

    /// 今天首页与小组件总览；只用合成数据，不读取本机任务。
    static func renderToday(model: UsageModel, dir: URL) {
        let savedData = model.data, savedState = model.mainState, savedTasks = model.runningTasks
        let savedPage = model.widgetPage, savedHome = model.panelHome, savedNow = model.fixedNow, savedTheme = model.themeMode
        let savedLayout = model.todayLayout, savedEditing = model.todayEditing
        let savedResize = model.todayResizePreview
        let savedDetail = model.panelDetailModel, savedID = model.detailPlatform
        let savedWidgetDetail = model.widgetDetailModel, savedWidgetID = model.widgetDetailPlatform
        defer {
            model.todayLayout = savedLayout; model.todayEditing = savedEditing; model.todayResizePreview = savedResize
            model.data = savedData; model.mainState = savedState; model.runningTasks = savedTasks
            model.widgetPage = savedPage; model.panelHome = savedHome; model.fixedNow = savedNow; model.themeMode = savedTheme
            model.panelDetailModel = savedDetail; model.detailPlatform = savedID
            model.widgetDetailModel = savedWidgetDetail; model.widgetDetailPlatform = savedWidgetID
        }
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let tz = TimeZone(secondsFromGMT: 28800)!
        let deepseek = deepseekMainState(now: now), codex = quotaMainState(now: now)
        var claude = codex
        claude.id = .claudePlan; claude.snapshot?.provider = .claudePlan; claude.snapshot?.quota?.plan = "max"
        var sf = deepseek
        sf.id = .siliconflow; sf.snapshot?.provider = .siliconflow
        sf.snapshot?.balance = Money(amount: 28, currency: .cny)
        sf.snapshot?.today = Money(amount: Decimal(string: "0.50")!, currency: .cny)
        var d = previewData(main: deepseek, others: [codex, claude, sf], now: now, timeZone: tz)
        if let i = d.sides.firstIndex(where: { $0.id == "codexPlan" }) {
            d.sides[i].riskText = L("today.previewRisk"); d.sides[i].riskSeverity = 1
            d.sides[i].resetCreditsCount = 1
            d.sides[i].resetCredits = ResetCredits(available: 1, expiresAt: now.addingTimeInterval(47 * 86400)).text(timeZone: tz)
        }
        if let i = d.sides.firstIndex(where: { $0.id == "siliconflow" }) { d.sides[i].runwayDays = 3008 }
        d.totalTodayCny = 6.77; d.totalIsApprox = true
        d.apiValue = ApiValue(todayUSD: 23.1, weekUSD: 148, perProvider: ["codexPlan": 8.1, "claudePlan": 15], partial: true)
        let tasks = [ProviderID.claudePlan, .codexPlan].enumerated().map { i, id in
            RunningTask(provider: id, sessionKey: "preview-\(i)", project: i == 0 ? "token-bar" : "api-server",
                        model: i == 0 ? "opus 4.7" : "gpt-5.5", startedAt: now.addingTimeInterval(-724 - Double(i) * 40),
                        lastActivity: now.addingTimeInterval(-5), tokens: 18234,
                        usage: TokenBreakdown(input: 10000, output: 18234), rawModel: i == 0 ? "claude-opus-4-7" : "gpt-5.5")
        }
        model.panelHome = "today"; model.fixedNow = now; model.panelDetailModel = nil; model.detailPlatform = nil
        model.widgetDetailModel = nil; model.widgetDetailPlatform = nil
        for dark in [true, false] {
            model.themeMode = dark ? .dark : .light
            let tag = dark ? "dark" : "light", p = Palette.of(dark)
            let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)
            model.todayLayout = TodayLayout.defaultLayout(platformIDs: ["deepseek", "siliconflow", "codexPlan", "claudePlan"])
            model.mainState = deepseek; model.data = d; model.runningTasks = tasks
            renderFit(PanelView(model: model, p: p), name: "panel-today-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            let mixed: [TodayLayoutItem] = [
                .init(id: "codexPlan", size: .medium), .init(id: "claudePlan", size: .small),
                .init(id: "spend", size: .small), .init(id: "running", size: .large),
                .init(id: "trend", size: .medium), .init(id: "deepseek", size: .small)
            ]
            model.data = previewData(main: deepseek, others: [codex, claude], now: now, timeZone: tz)
            model.data?.apiValue = d.apiValue
            model.todayLayout = mixed
            renderFit(PanelView(model: model, p: p), name: "panel-today-mixed-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            // 暂时隐藏了 Kimi：「添加 / 移除平台」右边「已隐藏 1 ⌄」（用户 11/6 选 proposal-hidden-bottom 丁）
            model.data = d
            model.todayLayout = TodayLayout.defaultLayout(platformIDs: ["deepseek", "siliconflow", "codexPlan", "claudePlan"])
            model.hiddenIDs = [.kimi]
            renderFit(PanelView(model: model, p: p), name: "panel-today-hidden-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            model.hiddenIDs = []
            // 点「已隐藏 2 ⌄」弹出的列表（弹窗本身离屏画不出，单独画内容；用户 11/6 选 proposal-hidden-bottom 丁）
            renderFit(HiddenPlatformsList(ids: [.siliconflow, .kimi], p: p, onShow: { _ in }).padding(12),
                      name: "hidden-popover-\(tag)", width: 220, bg: p.dark ? Color(white: 0.2) : Color.white, dir: dir)
            model.data = previewData(main: deepseek, others: [codex, claude], now: now, timeZone: tz)
            model.data?.apiValue = d.apiValue
            model.todayLayout = mixed
            if dark {
                model.todayEditing = true
                renderFit(PanelView(model: model, p: p), name: "panel-today-edit-dark", width: kPanelWidth, bg: bg, dir: dir)
                model.todayEditing = false
                model.mainState = codex
                model.data = previewData(main: codex, others: [deepseek, claude], now: now, timeZone: tz)
                model.data?.apiValue = d.apiValue
                renderFit(PanelView(model: model, p: p), name: "panel-today-mainswitch-dark", width: kPanelWidth, bg: bg, dir: dir)
            }
            model.mainState = deepseek
            model.data = previewData(main: deepseek, others: [codex], now: now, timeZone: tz)
            model.data?.apiValue = d.apiValue
            model.data?.tokenSources = [.init(provider: .codexPlan, byDay: ["2026-10-15": ["gpt-5.5": 18000], "2026-10-14": ["gpt-5.5": 12000]])]
            model.runningTasks = tasks
            model.todayLayout = [.init(id: "codexPlan", size: .large), .init(id: "deepseek", size: .medium),
                                 .init(id: "spend", size: .medium), .init(id: "running", size: .small), .init(id: "trend", size: .medium)]
            renderFit(PanelView(model: model, p: p), name: "panel-today-large-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            if dark {
                model.todayLayout = [.init(id: "deepseek", size: .large), .init(id: "spend", size: .large),
                                     .init(id: "codexPlan", size: .small), .init(id: "running", size: .small), .init(id: "trend", size: .medium)]
                renderFit(PanelView(model: model, p: p), name: "panel-today-large-payg-dark", width: kPanelWidth, bg: bg, dir: dir)
                model.todayLayout = TodayLayout.defaultLayout(platformIDs: ["codexPlan", "deepseek"])
                model.todayEditing = true; model.todayResizePreview = "codexPlan"
                renderFit(PanelView(model: model, p: p), name: "panel-today-resize-dark", width: kPanelWidth, bg: bg, dir: dir)
                model.todayEditing = false; model.todayResizePreview = nil
            }
            // OpenRouter（11/6 新平台，美元）：今天页一张卡；单独作主平台时只写今日 / 本月，没有 token 柱图和缓存命中
            var openrouter = deepseek
            openrouter.id = .openrouter
            openrouter.snapshot = ProviderSnapshot(provider: .openrouter, balance: Money(amount: Decimal(string: "18.42")!, currency: .usd),
                                                   today: Money(amount: Decimal(string: "0.86")!, currency: .usd),
                                                   month: Money(amount: Decimal(string: "12.30")!, currency: .usd),
                                                   byModel: [], trend7: [], source: .bill, fetchedAt: now, credential: .ok)
            // 普通 Key 读不到账户余额：显示的是 Key 剩余额度（用户 11/7 选乙：卡片底注、表盘上方小字都写明）
            openrouter.snapshot?.balanceIsKeyLimit = true
            openrouter.burn = BurnStats(perHourRecent: 0, perHourDay: Decimal(string: "0.04"), avgPerDayWeek: Decimal(string: "0.95")!,
                                        runwayDays: Decimal(string: "19.4"), spike: false)
            model.mainState = deepseek
            model.data = previewData(main: deepseek, others: [openrouter, codex], now: now, timeZone: tz)
            model.todayLayout = TodayLayout.defaultLayout(platformIDs: ["deepseek", "openrouter", "codexPlan"])
            renderFit(PanelView(model: model, p: p), name: "panel-today-openrouter-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            // 人民币主平台 + 美元辅助平台：表盘刻度按 ¥，OpenRouter 的 $18.42 先换成约 ¥131 再画（审查后续 2）
            model.panelHome = "single"
            model.data = previewData(main: deepseek, others: [openrouter], now: now, timeZone: tz)
            renderFit(PanelView(model: model, p: p), name: "panel-mixed-usd-side-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            model.panelHome = "today"
            model.mainState = openrouter
            model.data = previewData(main: openrouter, others: [], now: now, timeZone: tz)
            model.todayLayout = TodayLayout.defaultLayout(platformIDs: ["openrouter"])
            renderFit(PanelView(model: model, p: p), name: "panel-openrouter-only-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            // PackyAPI（11/9 新平台，人民币）：单独作主平台，有按模型明细（只有总 token，没有缓存命中）和近 7 天趋势
            var packy = deepseek
            packy.id = .packyapi
            func yuan(_ v: String) -> Money { Money(amount: Decimal(string: v)!, currency: .cny) }
            let opus = ModelUsage(model: "claude-opus-5-5", cacheHit: 0, cacheMiss: 0, output: 1_840_000, requests: 61, cost: yuan("2.10"))
            let sonnet = ModelUsage(model: "claude-sonnet-5", cacheHit: 0, cacheMiss: 0, output: 920_000, requests: 109, cost: yuan("1.14"))
            let packyDays = ["2026-10-09", "2026-10-10", "2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15"]
                .enumerated().map { i, day in
                    DayUsage(day: day, tokens: [0, 0, 0, 0, 1_200_000, 2_100_000, 2_760_000][i],
                             cost: yuan(["0", "0", "0", "0", "1.62", "2.95", "3.24"][i]), models: i == 6 ? [opus, sonnet] : [])
                }
            packy.snapshot = ProviderSnapshot(provider: .packyapi, balance: yuan("108.32"), today: yuan("3.24"), month: yuan("12.68"),
                                              byModel: [opus, sonnet], trend7: packyDays, source: .bill, fetchedAt: now, credential: .ok)
            packy.burn = BurnStats(perHourRecent: Decimal(string: "0.31"), perHourDay: Decimal(string: "0.27"), avgPerDayWeek: Decimal(string: "2.60")!,
                                   runwayDays: Decimal(string: "41.7"), spike: false)
            model.mainState = packy
            model.data = previewData(main: packy, others: [], now: now, timeZone: tz)
            model.todayLayout = TodayLayout.defaultLayout(platformIDs: ["packyapi"])
            renderFit(PanelView(model: model, p: p), name: "panel-packyapi-only-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            // Gemini 套餐（通过 agy CLI 查额度）：5 小时 + 每周 + Claude/GPT 组周窗口
            let geminiQuota = Quota(plan: "pro", windows: [
                QuotaWindow(kind: .session, usedPercent: 7.84, resetsAt: now.addingTimeInterval(4 * 3600 + 53 * 60), windowMinutes: 300),
                QuotaWindow(kind: .weekly, usedPercent: 2.46, resetsAt: now.addingTimeInterval(6 * 86400 + 23 * 3600), windowMinutes: 10080),
                QuotaWindow(kind: .weeklyModel("Claude / GPT"), usedPercent: 0, resetsAt: now.addingTimeInterval(7 * 86400), windowMinutes: 10080)
            ], observedAt: now)
            let gemini = PlatformState(id: .geminiPlan,
                                       snapshot: ProviderSnapshot(provider: .geminiPlan, balance: nil, today: nil, month: nil,
                                                                  byModel: [], trend7: [], source: .quota, fetchedAt: now,
                                                                  credential: .ok, quota: geminiQuota),
                                       burn: nil, status: .ok)
            model.mainState = gemini
            model.data = previewData(main: gemini, others: [], now: now, timeZone: tz)
            model.todayLayout = TodayLayout.defaultLayout(platformIDs: ["geminiPlan"])
            renderFit(PanelView(model: model, p: p), name: "panel-gemini-only-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            model.mainState = deepseek; model.data = d
            model.todayLayout = TodayLayout.defaultLayout(platformIDs: ["deepseek", "siliconflow", "codexPlan", "claudePlan"])
            model.widgetPage = "overview"
            renderFit(WidgetView(model: model), name: "widget-overview-\(tag)", width: 270, bg: bg, dir: dir)
            if !dark {
                var kimi = sf
                kimi.id = .kimi; kimi.snapshot?.provider = .kimi
                kimi.snapshot?.balance = Money(amount: Decimal(string: "45.30")!, currency: .cny)
                kimi.snapshot?.today = Money(amount: Decimal(string: "1.20")!, currency: .cny)
                model.data = previewData(main: deepseek, others: [codex, claude, sf, kimi], now: now, timeZone: tz)
                renderFit(WidgetView(model: model), name: "widget-overview-5-light", width: 270, bg: bg, dir: dir)
                model.data = d
                let peek = UsageModel(passive: true)
                peek.mainState = codex; peek.fixedNow = now
                peek.data = previewData(main: codex, others: [deepseek, claude, sf], now: now, timeZone: tz)
                model.widgetDetailModel = peek; model.widgetDetailPlatform = .codexPlan
                renderFit(WidgetView(model: model), name: "widget-peek-light", width: 270, bg: bg, dir: dir)
                model.widgetDetailModel = nil; model.widgetDetailPlatform = nil
            }
            if dark {
                var three = previewData(main: claude, others: [codex, deepseek], now: now, timeZone: tz)
                if let codexCard = d.sides.first(where: { $0.id == "codexPlan" }),
                   let i = three.sides.firstIndex(where: { $0.id == "codexPlan" }) { three.sides[i] = codexCard }
                if let i = three.sides.firstIndex(where: { $0.id == "deepseek" }) { three.sides[i].runwayDays = 4 }
                three.apiValue = d.apiValue
                model.mainState = claude; model.data = three
                renderFit(PanelView(model: model, p: p), name: "panel-today-3-dark", width: kPanelWidth, bg: bg, dir: dir)
                // 隐藏了两个：「添加 / 移除平台」右边写「已隐藏 2 ⌄」
                model.hiddenIDs = [.siliconflow, .kimi]
                renderFit(PanelView(model: model, p: p), name: "panel-today-hidden2-dark", width: kPanelWidth, bg: bg, dir: dir)
                model.hiddenIDs = []
                model.mainState = deepseek; model.data = d
                model.runningTasks = []
                renderFit(PanelView(model: model, p: p), name: "panel-today-notasks-dark", width: kPanelWidth, bg: bg, dir: dir)
                // 5 个任务：小号「正在跑」和旁边等高，放不下的收进左下角「显示全部」
                let projects = ["token-bar", "api-server", "scratchpad", "个人站点", "docs"]
                var many: [RunningTask] = []
                for i in 0..<5 {
                    let claudeTask = i % 2 == 0
                    let started: Date = now.addingTimeInterval(Double(-900 - i * 60))
                    let active: Date = now.addingTimeInterval(i < 2 ? -5 : -1500)
                    let written: Int = 5200 * (i + 1)
                    many.append(RunningTask(provider: claudeTask ? .claudePlan : .codexPlan, sessionKey: "many-\(i)",
                                            project: projects[i], model: claudeTask ? "opus 5.5" : "gpt-5.5",
                                            startedAt: started, lastActivity: active, tokens: written,
                                            usage: TokenBreakdown(input: 1000, output: written),
                                            rawModel: claudeTask ? "claude-opus-4-7" : "gpt-5.5"))
                }
                model.runningTasks = many
                renderFit(PanelView(model: model, p: p), name: "panel-today-running-many-dark", width: kPanelWidth, bg: bg, dir: dir)
                model.runningTasks = []
                let detail = UsageModel(passive: true)
                detail.mainState = codex
                detail.data = previewData(main: codex, others: [deepseek, claude, sf], now: now, timeZone: tz)
                detail.fixedNow = now; detail.runningTasks = tasks
                model.detailPlatform = .codexPlan; model.panelDetailModel = detail
                renderFit(PanelView(model: model, p: p), name: "panel-today-detail-dark", width: kPanelWidth, bg: bg, dir: dir)
                model.panelDetailModel = nil; model.detailPlatform = nil
            }
        }
    }

    /// 第二批第 8 条：近 7 天 token 合并图。多平台堆叠柱（DeepSeek 主 + 硅基流动 + 本机 Claude Code / Codex，用量都是编的）、
    /// 只有 DeepSeek 的单平台柱、Claude 套餐作主平台时的合并图；深浅色各一张
    static func renderTokenChart(model: UsageModel, dir: URL, originalTheme: UsageModel.ThemeMode) {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let tz = TimeZone(secondsFromGMT: 28800)!
        func m(_ v: String) -> Money { Money(amount: Decimal(string: v)!, currency: .cny) }
        let qwen = ModelUsage(model: "Qwen/Qwen3-Coder-480B", cacheHit: 0, cacheMiss: 9_000_000, output: 200_000, requests: 40, cost: m("1.20"))
        var sfSnap = ProviderSnapshot(provider: .siliconflow, balance: m("12.00"), today: m("1.20"), month: m("8.00"),
                                      byModel: [qwen], trend7: [], source: .bill, fetchedAt: now, credential: .ok)
        sfSnap.trend7 = ["2026-10-12", "2026-10-13", "2026-10-15"].map { DayUsage(day: $0, tokens: 9_200_000, cost: m("1.20"), models: [qwen]) }
        let sf = PlatformState(id: .siliconflow, snapshot: sfSnap, burn: nil, status: .ok, lastSampleAt: now, lastSample: nil)
        let codex = quotaMainState(now: now)
        var claude = quotaMainState(now: now)
        claude.id = .claudePlan; claude.snapshot?.provider = .claudePlan; claude.snapshot?.quota?.plan = nil
        let local: [ProviderID: DailyModelTokens] = [
            .claudePlan: ["2026-10-11": ["claude-opus-5-5": 41_000_000], "2026-10-13": ["claude-opus-5-5": 88_000_000, "claude-haiku-5": 3_000_000],
                          "2026-10-14": ["claude-opus-5-5": 120_000_000], "2026-10-15": ["claude-opus-5-5": 52_340_000, "claude-haiku-5": 1_200_000]],
            .codexPlan: ["2026-10-10": ["gpt-5": 18_000_000], "2026-10-14": ["gpt-5": 26_000_000], "2026-10-15": ["gpt-5": 7_600_000]],
        ]
        let multi = previewData(main: deepseekMainState(now: now), others: [sf, codex, claude], now: now, timeZone: tz,
                                           localUsage: local)
        let claudeMain = previewData(main: claude, others: [deepseekMainState(now: now), codex], now: now, timeZone: tz,
                                                localUsage: local)
        let single = sampleData()
        let keepData = model.data, keepState = model.mainState, keepSide = model.menuBarSide
        model.fixedNow = now
        model.menuBarSide = nil
        for dark in [false, true] {
            model.themeMode = dark ? .dark : .light
            let tag = dark ? "dark" : "light"
            let p = Palette.of(dark)
            let bg = LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom)
            renderFit(TrendStrip(chart: multi.tokenChart(main: .deepseek), days: multi.trend7, onPick: { _ in }, p: p).padding(20),
                      name: "trend-multi-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            renderFit(TrendStrip(chart: single.tokenChart(main: .deepseek), days: single.trend7, onPick: { _ in }, p: p).padding(20),
                      name: "trend-single-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            model.data = multi; model.mainState = deepseekMainState(now: now)
            renderFit(PanelView(model: model, p: p), name: "panel-trend-multi-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
            model.data = claudeMain; model.mainState = claude
            renderFit(PanelView(model: model, p: p), name: "panel-trend-claude-main-\(tag)", width: kPanelWidth, bg: bg, dir: dir)
        }
        model.fixedNow = nil
        model.data = keepData; model.mainState = keepState; model.menuBarSide = keepSide
        model.themeMode = originalTheme
    }

    /// 多平台预览里的 DeepSeek 主平台状态（与 sampleData 同一份快照）
    static func deepseekMainState(now: Date) -> PlatformState {
        PlatformState(id: .deepseek, snapshot: sampleSnapshot(), burn: sampleBurn(), status: .ok, lastSampleAt: now, lastSample: nil)
    }

    static func multiPlatformInput(snap: ProviderSnapshot) -> AccountsInput {
        func state(_ id: ProviderID, _ status: PlatformStatus, credential: CredentialState = .ok) -> PlatformState {
            var s = snap; s.provider = id; s.credential = credential
            return PlatformState(id: id, snapshot: status == .credentialInvalid ? nil : s, burn: nil, status: status)
        }
        var settings = ProviderSettings()
        settings.lowAlerts = [.deepseek: 10, .siliconflow: 5, .codexPlan: 10]
        return AccountsInput(platforms: [state(.deepseek, .ok), state(.siliconflow, .ok, credential: .expiring(days: 3)),
                                         quotaMainState(now: snap.fetchedAt)],
                             mainID: .deepseek, auto: true, settings: settings)
    }

    /// 截图对比：基准目录里的每张图都要与刚渲染的同名图逐字节一致
    static func compare(dir: URL, baseline: URL) {
        guard renderScale == 2 else {
            print("--render-scale 非 2，跳过基准对比")
            return
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: baseline.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
        var bad: [String] = []
        for n in names {
            let a = try? Data(contentsOf: baseline.appendingPathComponent(n))
            let b = try? Data(contentsOf: dir.appendingPathComponent(n))
            if a == nil || a != b { bad.append(n) }
        }
        bad.forEach { print("snapshot 不一致：\($0)") }
        print("snapshots: \(names.count - bad.count)/\(names.count) 一致")
        exit(bad.isEmpty && !names.isEmpty ? 0 : 1)
    }

    /// 固定的演示数据（与测试样本同一组数：2026-10-15 08:00 +08:00）
    static func sampleSnapshot() -> ProviderSnapshot {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let cny = { (v: String) in Money(amount: Decimal(string: v)!, currency: .cny) }
        let flash = ModelUsage(model: "deepseek-flash", cacheHit: 55_182_976, cacheMiss: 698_425, output: 206_416,
                               requests: 276, cost: cny("2.68"))
        let pro = ModelUsage(model: "deepseek-v4-pro", cacheHit: 6_500_000, cacheMiss: 600_000, output: 102_991,
                             requests: 34, cost: cny("3.59"))
        let days = ["2026-10-09", "2026-10-10", "2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15"]
        let trend = days.map { d -> DayUsage in
            switch d {
            case "2026-10-14":
                return DayUsage(day: d, tokens: 394_667_538, cost: cny("32.72"),
                                models: [ModelUsage(model: "deepseek-flash", cacheHit: 384_801_407, cacheMiss: 6_513_656,
                                                    output: 3_352_475, requests: 900, cost: cny("32.72"))])
            case "2026-10-15": return DayUsage(day: d, tokens: 63_290_808, cost: cny("6.27"), models: [flash, pro])
            default: return DayUsage(day: d, tokens: 0, cost: cny("0"))
            }
        }
        let snap = ProviderSnapshot(provider: .deepseek, balance: cny("27.07"), today: cny("6.27"),
                                    month: cny("38.99"), byModel: [flash, pro], trend7: trend, source: .bill,
                                    fetchedAt: now, credential: .ok)
        return snap
    }

    static func sampleBurn() -> BurnStats {
        BurnStats(perHourRecent: 0, perHourDay: Decimal(string: "1.37"), avgPerDayWeek: Decimal(string: "5.57")!,
                  runwayDays: Decimal(string: "4.9"), spike: false)
    }

    static func sampleData() -> AppData {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let st = PlatformState(id: .deepseek, snapshot: sampleSnapshot(), burn: sampleBurn(), status: .ok, lastSampleAt: now, lastSample: nil)
        return previewData(main: st, others: [], now: now, timeZone: TimeZone(secondsFromGMT: 28800)!)

    }

    /// 设置窗的某一页。主平台预警线固定按 alert 画（只改镜像，不回写用户设置）；
    /// 平台行的套餐读数按示例快照自己的时间算（不随渲染当天变），画完恢复
    static func renderSettings<B: View>(_ model: UsageModel, page: SettingsPage, input: AccountsInput?,
                                        name: String, p: Palette, bg: B, dir: URL, alert: Double = 5) {
        let keep = (page: model.settingsPage, alert: model.renderAlert, now: model.fixedNow)
        model.settingsPage = page
        model.fixedNow = keep.now ?? input?.platforms.first { $0.snapshot?.quota != nil }?.snapshot?.fetchedAt
            ?? sampleSnapshot().fetchedAt
        model.renderAlert = alert
        renderFit(SettingsView(model: model, p: p, input: input), name: name, width: kSettingsWidth, bg: bg, dir: dir)
        model.settingsPage = keep.page; model.fixedNow = keep.now
        model.renderAlert = keep.alert
    }

    /// 宽度固定、高度取内容自然高度 —— 与真窗口的按内容定高一致，图里能直接看出留白/溢出
    static func renderFit<V: View, B: View>(_ v: V, name: String, width: CGFloat, bg: B, dir: URL) {
        let content = v.frame(width: width).fixedSize(horizontal: false, vertical: true).background(bg)
        write(ImageRenderer(content: content), name: name, dir: dir)
    }

    static func render<V: View>(_ v: V, name: String, size: CGSize, dir: URL) {
        write(ImageRenderer(content: v.frame(width: size.width, height: size.height)), name: name, dir: dir)
    }

    static func write<V: View>(_ renderer: ImageRenderer<V>, name: String, dir: URL) {
        renderer.scale = renderScale
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            logLine("渲染失败 \(name)")
            return
        }
        let url = dir.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
            print("rendered \(url.path) \(Int(img.size.width))x\(Int(img.size.height))")
        } catch {
            logLine("写图失败 \(name): \(error.localizedDescription)")
        }
    }
}
