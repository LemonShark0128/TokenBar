import Foundation

enum QuotaPace {
    static func expectedRemainingPercent(_ w: QuotaWindow, now: Date) -> Double? {
        guard let reset = w.resetsAt, reset > now, let minutes = w.windowMinutes, minutes > 0 else { return nil }
        let duration = Double(minutes) * 60
        let elapsed = min(1, max(0, now.timeIntervalSince(reset.addingTimeInterval(-duration)) / duration))
        return 100 * (1 - elapsed)
    }
}
