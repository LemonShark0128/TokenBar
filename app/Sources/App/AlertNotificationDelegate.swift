import Foundation
import UserNotifications

@MainActor
final class AlertNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private weak var model: UsageModel?

    @MainActor init(model: UsageModel) {
        self.model = model
        super.init()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let action = response.actionIdentifier
        let providers = (response.notification.request.content.userInfo["providers"] as? [String] ?? [])
            .compactMap(ProviderID.init(rawValue:))
        DispatchQueue.main.async { [weak self] in
            defer { completionHandler() }
            switch action {
            case UNNotificationDefaultActionIdentifier, "open":
                self?.model?.onOpenPanel?()
            case "muteToday":
                AlertMute.mute(providers)
                logLine("今天不再提醒：\(providers.map { ProviderRegistry.logName($0) }.joined(separator: "、"))")
            default: break
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
