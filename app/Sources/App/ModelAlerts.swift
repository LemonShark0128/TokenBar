import AppKit
import Combine
import SwiftUI
import UserNotifications

// ---------------------------------------------------------------- 状态：余额 / 额度提醒（系统通知、浮动警示卡）。提醒去重记录 platformAlerts 是存储属性，留在 Model.swift

extension UsageModel {
    /// 每轮刷新后按平台检查：低于各自预警线、用量异常增加（第七批自查：原来只看主平台）
    @MainActor
    func checkPlatformAlerts(_ store: UsageStore) {
        let previous = platformAlerts
        defer {
            if platformAlerts != previous { platformAlerts.save(.standard) }
        }
        let now = Date()
        let anomalies = store.anomalies()
        let th = ProviderSettings.load(.standard).lowAlerts
        // 先算出这一轮能发的内容；缺数据发不出就不记成已提醒（评审 I4）
        func lowMessage(_ id: ProviderID) -> (log: String, title: String, body: String)? {
            guard let st = store.platforms.first(where: { $0.id == id }), let t = th[id] else { return nil }
            let name = ProviderRegistry.displayName(id)
            if ProviderRegistry.meter(id) == .quota {
                guard let r = st.snapshot?.quota?.remainingPercent(at: now) else { return nil }
                let (title, body) = StatusPresenter.quotaLowNotification(name: name, remaining: r, threshold: AppDataMapping.double(t))
                return ("套餐额度预警触发：\(ProviderRegistry.logName(id))", title, body)
            }
            guard let b = st.snapshot?.balance else { return nil }
            let (title, body) = StatusPresenter.lowTankNotification(
                name: name, amount: AppDataMapping.double(b.amount), threshold: AppDataMapping.double(t),
                currency: b.currency.rawValue)
            return ("余额预警触发：\(ProviderRegistry.logName(id))", title, body)
        }
        for id in platformAlerts.lowToFire(anomalies, now: now, repeatHours: alertRepeatHours,
                                           covered: PlatformAlertTracker.exhaustedPlatforms(store.platforms, now: now),
                                           known: store.platformsWithReading(),
                                           canFire: { lowMessage($0) != nil }) {
            guard let m = lowMessage(id) else { continue }
            logLine(m.log)
            deliverAlert(title: m.title, body: m.body)
        }
        checkAgentAlerts(store, now: now)
        guard spikeAlertsOn else { return }
        func spikeMessage(_ id: ProviderID) -> (title: String, body: String)? {
            guard let burn = store.platforms.first(where: { $0.id == id })?.burn, let rate = burn.perHourRecent else { return nil }
            return StatusPresenter.spikeNotification(provider: ProviderRegistry.displayName(id),
                                                     cnyPerHour: AppDataMapping.double(rate),
                                                     avgCnyPerDayWeek: AppDataMapping.double(burn.avgPerDayWeek))
        }
        for id in platformAlerts.spikeToFire(anomalies, now: now, canFire: { spikeMessage($0) != nil }) {
            guard let (title, body) = spikeMessage(id) else { continue }
            logLine("用量异常增加提醒：\(body)")
            UNUserNotificationCenter.current().getNotificationSettings { s in
                if s.authorizationStatus == .authorized || s.authorizationStatus == .provisional {
                    self.postSystemNotification(title: title, body: body)
                } else {
                    DispatchQueue.main.async { self.showAlertCard(title: title, body: body) }
                }
            }
        }
    }

    /// 代理场景的两种提醒：每小时花费超过（按平台，1 小时内最多一次）、套餐重置前会用完（每个窗口一次）
    @MainActor
    func checkAgentAlerts(_ store: UsageStore, now: Date) {
        let settings = ProviderSettings.load(.standard)
        let risks = store.risks()
        if !settings.hourlyAlerts.isEmpty {
            // 只算这一轮取数成功的平台的原币种时速（与预警线同币种）
            var rates: [ProviderID: Decimal] = [:]
            for st in store.platforms where st.status == .ok || st.status == .consoleLoginNeeded {
                if let r = st.burn?.perHourRecent { rates[st.id] = r }
            }
            func hourlyMessage(_ id: ProviderID) -> (title: String, body: String)? {
                guard let st = store.platforms.first(where: { $0.id == id }), let r = rates[id], let th = settings.hourlyAlerts[id] else { return nil }
                let rate = AppDataMapping.double(r)
                let risk = risks.first { $0.id == id }
                let payg: PaygRunway? = { if case .payg(let p)? = risk?.kind { return p }; return risk?.paygReading }()
                let hours = payg?.basis == .recentSpike ? payg?.hours
                    : (rate > 0 ? st.snapshot?.balance.map { max(0, AppDataMapping.double($0.amount)) / rate } : nil)
                return StatusPresenter.hourlyNotification(name: ProviderRegistry.displayName(id), perHour: rate,
                                                          threshold: AppDataMapping.double(th),
                                                          currency: st.snapshot?.balance?.currency.rawValue, runwayHours: hours)
            }
            for id in platformAlerts.hourlyToFire(rates: rates, thresholds: settings.hourlyAlerts, now: now,
                                                  canFire: { hourlyMessage($0) != nil }) {
                guard let m = hourlyMessage(id) else { continue }
                let logTitle = m.title.replacingOccurrences(of: ProviderRegistry.displayName(id),
                                                           with: ProviderRegistry.logName(id))
                logLine("每小时花费提醒：\(logTitle)")
                deliverAlert(title: m.title, body: m.body)
            }
        }
        guard settings.quotaRunoutAlert else { return }
        let quotaRisks = risks.filter { ProviderRegistry.meter($0.id) == .quota }
        func runoutMessage(_ id: ProviderID) -> (title: String, body: String)? {
            guard let q = quotaRisks.first(where: { $0.id == id })?.quotaReading else { return nil }
            return StatusPresenter.runoutNotification(name: ProviderRegistry.displayName(id), runway: q, now: now,
                                                      timeZone: .autoupdatingCurrent)
        }
        for id in platformAlerts.runoutToFire(quotaRisks, now: now, canFire: { runoutMessage($0) != nil }) {
            guard let m = runoutMessage(id) else { continue }
            logLine("套餐重置前会用完提醒：\(ProviderRegistry.logName(id))")
            deliverAlert(title: m.title, body: m.body)
        }
    }

    /// 套餐窗口用完：每个窗口每次重置只提醒一次，去重记录变化时保存。
    func checkQuotaExhausted(_ platforms: [PlatformState], now: Date) {
        let previous = exhaustedMemory
        let alerts = exhaustedMemory.toFire(platforms, now: now)
        if exhaustedMemory != previous { exhaustedMemory.save(.standard) }
        for alert in alerts {
            let body = QuotaText.exhausted(name: ProviderRegistry.displayName(alert.id), window: alert.window,
                                           now: now, timeZone: .autoupdatingCurrent)
            logLine("套餐额度用完提醒")
            deliverAlert(title: L("quota.alertUsedUpTitle"), body: body)
        }
    }

    /// 发提醒：有系统通知权限走通知中心，没有就用浮动警示卡
    func deliverAlert(title: String, body: String) {
        NSSound(named: "Basso")?.play()
        UNUserNotificationCenter.current().getNotificationSettings { s in
            if s.authorizationStatus == .authorized || s.authorizationStatus == .provisional {
                self.postSystemNotification(title: title, body: body)
            } else {
                // 没授权系统通知 → 用自己画的浮动警示卡兜底（不依赖任何权限）
                DispatchQueue.main.async { self.showAlertCard(title: title, body: body) }
            }
        }
    }

    /// 在通知中心的回调线程上调用（不在主线程）：只碰 UNUserNotificationCenter 和日志，都是线程安全的
    nonisolated func postSystemNotification(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let req = UNNotificationRequest(identifier: "balance-alert-\(UUID().uuidString)",
                                        content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err = err {
                // 发不出去时提醒不能就这么没了（去重记录已经写下）：改用浮动警示卡
                logLine("系统通知发送失败：\(err.localizedDescription)，改用浮动警示卡")
                DispatchQueue.main.async { self.showAlertCard(title: title, body: body) }
            } else { logLine("系统通知已发送（通知中心）") }
        }
    }

    /// 兜底弹窗：屏幕右上角浮动警示卡
    /// 卡片开着时来的提醒先排队，用户关掉当前这张再显示下一张（以前新卡直接顶掉旧卡，同一轮只剩最后一条）
    static var pendingAlertCards: [(title: String, body: String)] = []

    func showAlertCard(title: String, body: String) {
        if Hud.windows["alert"]?.isVisible == true {
            Self.pendingAlertCards.append((title, body))
            return
        }
        _ = Hud.toggle(key: "alert", title: L("alertCard.windowTitle"),
                       size: CGSize(width: 340, height: 138), titled: false,
                       origin: { size in
                           NSPoint(x: self.screen.maxX - size.width - 24,
                                   y: self.screen.maxY - size.height - 80)
                       },
                       content: AnyView(AlertCard(title: title, message: body, p: Palette.of(self.dark),
                                                  onClose: { [weak self] in
                                                      Hud.hide("alert")
                                                      guard !Self.pendingAlertCards.isEmpty else { return }
                                                      let next = Self.pendingAlertCards.removeFirst()
                                                      self?.showAlertCard(title: next.title, body: next.body)
                                                  })))
    }

    /// 首次运行时申请一次通知权限（拒绝也不影响：走浮动卡兜底）
    func requestNotificationAuthOnce() {
        // ⚠️ `--render` 离屏自检不是经 LaunchServices 启动的真 App（无 bundle 代理）：
        // 这里碰 UNUserNotificationCenter 会抛 NSAssertion 直接 abort —— 实测 `--render` 退出码 133、
        // 一个 PNG 都渲染不出来。自检模式必须跳过。
        guard !CommandLine.arguments.contains(where: { $0 == "--render" || $0 == "--render-check" }) else { return }
        let key = "didRequestNotificationAuth"
        if UserDefaults.standard.bool(forKey: key) { return }
        UserDefaults.standard.set(true, forKey: key)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, err in
            logLine("通知授权：\(ok ? "已允许" : "未允许") \(err?.localizedDescription ?? "")")
        }
    }
}
