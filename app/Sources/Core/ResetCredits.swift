import Foundation
import CoreFoundation

struct ResetCredits: Codable, Equatable, Sendable {
    var available: Int
    var expiresAt: Date?

    func text(timeZone: TimeZone) -> String {
        guard available > 0 else { return L("quota.resetCreditsEmpty") }
        var result = L("quota.resetCredits", available)
        if let expiresAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "MM-dd"
            result += L("quota.resetCreditsExpires", formatter.string(from: expiresAt))
        }
        return result
    }

    static func count(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue >= 0 else { return nil }
        return Int(exactly: n.doubleValue)
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let string = value as? String else { return nil }
        if let seconds = Double(string), seconds.isFinite { return Date(timeIntervalSince1970: seconds) }
        return ISODate.parse(string)
    }
}

/// Keeps the most recently observed reset credits for this process only.
actor ResetCreditsMemory {
    static let shared = ResetCreditsMemory()
    static let maxAge: TimeInterval = 86400

    private var credits: ResetCredits?
    private var rememberedAt: Date?

    func remember(_ credits: ResetCredits, at: Date) {
        self.credits = credits
        self.rememberedAt = at
    }

    func recall(now: Date) -> ResetCredits? {
        guard let credits, let rememberedAt,
              Self.isValid(credits, rememberedAt: rememberedAt, now: now) else { return nil }
        return credits
    }

    nonisolated static func isValid(_ credits: ResetCredits, rememberedAt: Date, now: Date) -> Bool {
        if let expiresAt = credits.expiresAt { return now < expiresAt }
        return now.timeIntervalSince(rememberedAt) < maxAge
    }
}
