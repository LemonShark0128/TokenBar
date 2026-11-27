import Foundation

struct PendingAlert: Equatable, Codable {
    var provider: ProviderID?
    var title: String
    var body: String
    var sound: Bool
}

enum AlertBatch {
    static func merge(_ alerts: [PendingAlert]) -> (title: String, body: String, sound: Bool, providers: [ProviderID])? {
        guard let first = alerts.first else { return nil }
        var providers: [ProviderID] = []
        for id in alerts.compactMap(\.provider) where !providers.contains(id) { providers.append(id) }
        return (alerts.count == 1 ? first.title : L("alert.batch.title", alerts.count),
                alerts.count == 1 ? first.body : lines(alerts),
                alerts.contains { $0.sound }, providers)
    }

    static func lines(_ alerts: [PendingAlert]) -> String {
        alerts.map { "\($0.title)：\($0.body)" }.joined(separator: "\n")
    }
}

struct QuietHours: Equatable {
    var startHour: Int
    var endHour: Int
    static let key = "alertQuietHours"

    func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard (0...23).contains(startHour), (0...23).contains(endHour), startHour != endHour else { return false }
        let hour = calendar.component(.hour, from: date)
        return startHour < endHour ? hour >= startHour && hour < endHour : hour >= startHour || hour < endHour
    }

    var value: String { "\(startHour)-\(endHour)" }

    static func parse(_ value: String) -> QuietHours? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]),
              (0...23).contains(start), (0...23).contains(end) else { return nil }
        return QuietHours(startHour: start, endHour: end)
    }

    static func load(_ d: UserDefaults) -> QuietHours? { parse(d.string(forKey: key) ?? "off") }
    static func save(_ q: QuietHours?, _ d: UserDefaults) { d.set(q?.value ?? "off", forKey: key) }
}

struct AlertMute {
    static let key = "alertMutedToday"
    private struct Record: Codable { var day: String; var ids: [ProviderID] }

    private static func day(_ now: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func load(_ d: UserDefaults) -> Record? {
        guard let data = d.string(forKey: key)?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func isMuted(_ id: ProviderID, now: Date, d: UserDefaults, calendar: Calendar) -> Bool {
        guard let record = load(d), record.day == day(now, calendar) else { return false }
        return record.ids.contains(id)
    }

    static func unmute(_ id: ProviderID, d: UserDefaults = .standard) {
        guard var record = load(d) else { return }
        record.ids.removeAll { $0 == id }
        if record.ids.isEmpty { d.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(record), let json = String(data: data, encoding: .utf8) {
            d.set(json, forKey: key)
        }
    }

    static func mute(_ ids: [ProviderID], now: Date = Date(), d: UserDefaults = .standard,
                     calendar: Calendar = .current) {
        let today = day(now, calendar)
        var record = load(d) ?? Record(day: today, ids: [])
        if record.day != today { record = Record(day: today, ids: []) }
        for id in ids where !record.ids.contains(id) { record.ids.append(id) }
        if let data = try? JSONEncoder().encode(record), let json = String(data: data, encoding: .utf8) {
            d.set(json, forKey: key)
        }
    }
}

struct QuietBacklog {
    static let key = "alertQuietBacklog"
    private(set) var alerts: [PendingAlert] = []

    mutating func remove(_ id: ProviderID) {
        alerts.removeAll { $0.provider == id }
    }

    mutating func append(_ incoming: [PendingAlert]) { alerts = Array((alerts + incoming).suffix(20)) }

    static func load(_ d: UserDefaults) -> QuietBacklog {
        guard let data = d.data(forKey: key), let alerts = try? JSONDecoder().decode([PendingAlert].self, from: data) else {
            return QuietBacklog()
        }
        return QuietBacklog(alerts: Array(alerts.suffix(20)))
    }

    func save(_ d: UserDefaults) {
        if alerts.isEmpty { d.removeObject(forKey: Self.key) }
        else if let data = try? JSONEncoder().encode(alerts) { d.set(data, forKey: Self.key) }
    }

    mutating func drain() -> (alert: PendingAlert, providers: [ProviderID])? {
        guard let merged = AlertBatch.merge(alerts) else { return nil }
        var body = AlertBatch.lines(Array(alerts.prefix(5)))
        if alerts.count > 5 { body += "\n" + L("alert.quiet.more", alerts.count - 5) }
        let alert = PendingAlert(provider: nil, title: L("alert.quiet.title", alerts.count), body: body, sound: merged.sound)
        alerts.removeAll()
        return (alert, merged.providers)
    }
}
