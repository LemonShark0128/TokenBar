import AppKit
import Combine
import SwiftUI
import UserNotifications

// ---------------------------------------------------------------- 状态：汇率刷新、检查更新（定时器 fxTimer / updateLaunchTimer 是存储属性，留在 Model.swift）

extension UsageModel {
    /// 启动时刷新一次汇率，之后每小时检查（ExchangeRate 自己节流：成功 24 小时、失败 6 小时）；走系统代理；离屏预览不联网
    func startExchangeRateRefresh() {
        guard !kRendering else { return }
        refreshExchangeRate()
        // 定时器挂在主 RunLoop 上，但回调被声明成 @Sendable：用 Task { @MainActor } 让编译器检查（晚一拍无所谓）
        fxTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshExchangeRate()
                self?.checkForUpdate()
            }
        }
        fxTimer?.tolerance = 600        // 汇率自己节流到 24 小时，早晚 10 分钟无所谓，让系统合并唤醒
        // 检查更新：启动 1 分钟后看一次（UpdateCheck 自己节流到 24 小时），之后跟上面每小时的节拍
        let t = Timer(timeInterval: 60, repeats: false) { [weak self] _ in Task { @MainActor in self?.checkForUpdate() } }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        updateLaunchTimer = t
    }

    /// force = 设置里点「现在检查」：不看开关和 24 小时，结果显示在设置页
    func checkForUpdate(force: Bool = false) {
        guard !kRendering, !updateChecking else { return }
        if force { updateChecking = true }
        Task { @MainActor in
            let o = await UpdateCheck.check(client: URLSessionHTTPClient(systemProxy: true), defaults: .standard,
                                            current: UpdateCheck.currentVersion, now: Date(), force: force, log: logLine)
            self.updateChecking = false
            if force { self.updateOutcome = o ?? .failed }
            self.availableUpdate = UpdateCheck.available(.standard, current: UpdateCheck.currentVersion)
        }
    }

    func refreshExchangeRate() {
        Task { @MainActor in
            let rate = await ExchangeRate.refresh(client: URLSessionHTTPClient(systemProxy: true), defaults: .standard, now: Date(), log: logLine)
            guard rate != nil else { return }
            // 汇率变了：今日合计等按新汇率重算
            self.objectWillChange.send()
            self.applyStore()
        }
    }
}
