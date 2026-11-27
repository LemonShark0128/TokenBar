import AppKit
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
        for alert in platformAlerts.claudeLoginAlerts(store.platforms, now: now, cliSource: claudeSource != .web) {
            logLine("Claude 登录提醒：\(alert.title)")
            deliverAlert(title: alert.title, body: alert.body, provider: .claudePlan)
        }
        for alert in platformAlerts.geminiLoginAlerts(store.platforms) {
            logLine("Gemini 登录提醒：\(alert.title)")
            deliverAlert(title: alert.title, body: alert.body, provider: .geminiPlan)
        }
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
                currency: b.currency.rawValue, keyLimit: st.snapshot?.balanceIsKeyLimit == true)
            return ("余额预警触发：\(ProviderRegistry.logName(id))", title, body)
        }
        for id in platformAlerts.lowToFire(anomalies, now: now, repeatHours: alertRepeatHours,
                                           covered: PlatformAlertTracker.exhaustedPlatforms(store.platforms, now: now),
                                           known: store.platformsWithReading(),
                                           canFire: { lowMessage($0) != nil }) {
            guard let m = lowMessage(id) else { continue }
            logLine(m.log)
            deliverAlert(title: m.title, body: m.body, provider: id)
        }
        checkAgentAlerts(store, now: now)
        guard spikeAlertsOn else { return }
        func spikeMessage(_ id: ProviderID) -> (title: String, body: String)? {
            guard let st = store.platforms.first(where: { $0.id == id }), let burn = st.burn, let rate = burn.perHourRecent else { return nil }
            return StatusPresenter.spikeNotification(provider: ProviderRegistry.displayName(id),
                                                     cnyPerHour: AppDataMapping.double(rate),
                                                     avgCnyPerDayWeek: AppDataMapping.double(burn.avgPerDayWeek),
                                                     currency: (st.snapshot?.balance?.currency ?? ProviderRegistry.currency(id)).rawValue,
                                                     avgDays: burn.avgDays)
        }
        for id in platformAlerts.spikeToFire(anomalies, now: now, canFire: { spikeMessage($0) != nil }) {
            guard let (title, body) = spikeMessage(id) else { continue }
            logLine("用量异常增加提醒：\(body)")
            deliverAlert(title: title, body: body, sound: false, provider: id)
        }
    }

    /// 每小时花费提醒（按平台，1 小时内最多一次）
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
                deliverAlert(title: m.title, body: m.body, provider: id)
            }
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
            logLine("套餐额度用完提醒：\(ProviderRegistry.logName(alert.id))")
            deliverAlert(title: L("quota.alertUsedUpTitle"), body: body, provider: alert.id)
        }
    }

    func checkQuotaRecovered(_ platforms: [PlatformState], now: Date) {
        let settings = ProviderSettings.load(.standard)
        let previous = recoveryMemory
        let alerts = recoveryMemory.toFire(platforms, lowAlerts: settings.lowAlerts, now: now)
        if recoveryMemory != previous { recoveryMemory.save(.standard) }
        guard settings.quotaRecoveredAlert else { return }
        for (id, window) in alerts {
            logLine("额度恢复提醒：\(ProviderRegistry.logName(id))")
            deliverAlert(title: L("alert.recovered.title", ProviderRegistry.displayName(id), QuotaText.windowName(window.kind)),
                         body: L("alert.recovered.body", Int((100 - window.effectiveUsed(at: now)).rounded(.down))), provider: id)
        }
    }

    /// 发提醒：有系统通知权限走通知中心，没有就用浮动警示卡
    /// sound：是否先响一声提示音（用量异常增加提醒不响）
    func deliverAlert(title: String, body: String, sound: Bool = true, provider: ProviderID?) {
        pendingAlerts.append(PendingAlert(provider: provider, title: title, body: body, sound: sound))
        scheduleAlertFlush()
    }

    func scheduleAlertFlush() {
        guard !alertFlushScheduled else { return }
        alertFlushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushAlerts() }
    }

    func flushAlerts() {
        alertFlushScheduled = false
        let pending = pendingAlerts
        pendingAlerts.removeAll()
        let now = Date()
        let d = UserDefaults.standard
        let calendar = Calendar.current
        func allowed(_ alert: PendingAlert) -> Bool {
            if let id = alert.provider, AlertMute.isMuted(id, now: now, d: d, calendar: calendar) {
                logLine("今天已静音，不发：\(ProviderRegistry.logName(id))")
                return false
            }
            return true
        }
        let alerts = pending.filter(allowed)
        var backlog = QuietBacklog.load(d)
        if QuietHours.load(d)?.contains(now, calendar: calendar) == true {
            if !alerts.isEmpty {
                backlog.append(alerts)
                backlog.save(d)
                logLine("安静时段，暂存 \(alerts.count) 条提醒")
            }
            return
        }
        // 已积压的平台也可能刚被用户静音。
        var visibleBacklog = QuietBacklog()
        visibleBacklog.append(backlog.alerts.filter(allowed))
        // 安静时段汇总单独发一条，不和本轮新提醒合并（嵌套在一起读着乱）
        typealias Delivery = (title: String, body: String, sound: Bool, providers: [ProviderID], parts: [PendingAlert])
        var deliveries: [Delivery] = []
        if let summary = visibleBacklog.drain() {
            deliveries.append((summary.alert.title, summary.alert.body, summary.alert.sound, summary.providers, [summary.alert]))
        }
        if !backlog.alerts.isEmpty { QuietBacklog().save(d) }
        if let merged = AlertBatch.merge(alerts) {
            deliveries.append((merged.title, merged.body, merged.sound, merged.providers, alerts))
        }
        guard !deliveries.isEmpty else { return }
        let items = deliveries
        let playSound = deliveries.contains(where: \.sound)
        UNUserNotificationCenter.current().getNotificationSettings { s in
            if s.authorizationStatus == .authorized || s.authorizationStatus == .provisional {
                for item in items {
                    self.postSystemNotification(title: item.title, body: item.body, sound: item.sound, providers: item.providers)
                }
            } else {
                // 没授权系统通知 → 用自己画的浮动警示卡兜底（不依赖任何权限）。
                // 卡片高度固定，不合并：本轮每条提醒各一张，照原来那样排队
                DispatchQueue.main.async {
                    // 系统通知自带声音；只有浮动卡这条路才自己响一声，避免连响两次
                    if playSound { NSSound(named: "Basso")?.play() }
                    for item in items { for part in item.parts { self.showAlertCard(title: part.title, body: part.body) } }
                }
            }
        }
    }

    /// 在通知中心的回调线程上调用（不在主线程）：只碰 UNUserNotificationCenter 和日志，都是线程安全的
    nonisolated func postSystemNotification(title: String, body: String, sound: Bool, providers: [ProviderID]) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = sound ? .default : nil
        // 「今天不再提醒」只挂在单平台通知上：多平台合并 / 汇总时一点会静音好几个平台
        c.categoryIdentifier = providers.count == 1 ? "tokenbar.alert" : "tokenbar.alert.multi"
        c.userInfo["providers"] = providers.map(\.rawValue)
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
        // ⚠️ `--render` 离屏自检碰 UNUserNotificationCenter 会 abort：唯一调用方（UsageModel.init）已 guard !kRendering
        let center = UNUserNotificationCenter.current()
        let delegate = AlertNotificationDelegate(model: self)
        notificationDelegate = delegate
        center.delegate = delegate
        center.setNotificationCategories([UNNotificationCategory(identifier: "tokenbar.alert", actions: [
            UNNotificationAction(identifier: "open", title: L("alert.action.open"), options: .foreground),
            UNNotificationAction(identifier: "muteToday", title: L("alert.action.muteToday"), options: [])
        ], intentIdentifiers: [], options: []), UNNotificationCategory(identifier: "tokenbar.alert.multi", actions: [
            UNNotificationAction(identifier: "open", title: L("alert.action.open"), options: .foreground)
        ], intentIdentifiers: [], options: [])])
        let key = "didRequestNotificationAuth"
        if UserDefaults.standard.bool(forKey: key) { return }
        UserDefaults.standard.set(true, forKey: key)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, err in
            logLine("通知授权：\(ok ? "已允许" : "未允许") \(err?.localizedDescription ?? "")")
        }
    }
}
