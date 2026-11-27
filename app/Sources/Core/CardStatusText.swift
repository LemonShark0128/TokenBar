import Foundation

enum AlertGlyph: Equatable {
    case none, warning, error

    static func level(status: String? = nil, quotaBlocked: Bool = false, loginHint: String? = nil,
                      riskSeverity: Int? = nil, warn: Bool = false) -> Self {
        let failed = status.map {
            $0 == L("quota.usedUp") || AppDataMapping.isCredentialProblem($0)
        } ?? false
        if quotaBlocked || loginHint != nil || failed || riskSeverity == RunwaySeverity.danger.rawValue {
            return .error
        }
        return warn || (riskSeverity ?? 0) > 0 ? .warning : .none
    }
}

enum RunningActivity: Equatable {
    case agent, payg, unspecified

    static let agentWindow: TimeInterval = 60

    static func recentAgents(_ tasks: [RunningTask], now: Date) -> Set<ProviderID> {
        Set(tasks.lazy.filter { now.timeIntervalSince($0.lastActivity) <= agentWindow }.map(\.provider))
    }

    static func kind(for provider: ProviderID?, recentAgents: Set<ProviderID>, paygActive: Set<ProviderID>) -> Self? {
        guard let provider else { return nil }
        if ProviderRegistry.meter(provider) == .quota {
            return recentAgents.contains(provider) ? .agent : nil
        }
        return paygActive.contains(provider) ? .payg : nil
    }

    var help: String {
        switch self {
        case .agent: return L("today.runningAgentHelp")
        case .payg: return L("today.runningPaygHelp")
        case .unspecified: return L("today.runningLabel")
        }
    }
}

enum PaceText {
    static func describe(remaining: Double, pace: Double) -> String {
        L("quota.paceDetail", short(remaining: remaining, pace: pace),
          String(format: "%.0f", pace.rounded()), String(format: "%.0f", remaining.rounded()))
    }

    static func short(remaining: Double, pace: Double) -> String {
        let points = (remaining - pace).rounded()
        guard let delta = Int(exactly: points.magnitude), delta > 2 else { return L("quota.paceSteady") }
        return points < 0 ? L("quota.paceFast", delta) : L("quota.paceSlow", delta)
    }
}

enum StaleTime {
    static func absolute(_ date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let time = String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
        if calendar.isDate(date, inSameDayAs: now) { return L("status.updatedToday", time) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L("status.updatedYesterday", time)
        }
        let day = calendar.component(.day, from: date)
        let month = calendar.component(.month, from: date)
        let year = calendar.component(.year, from: date)
        var names = calendar
        names.locale = Locale(identifier: "en_US_POSIX")
        let monthName = names.shortMonthSymbols.dropFirst(max(0, month - 1)).first
        let monthText = L10n.isZh ? String(month) : (monthName ?? String(month))
        return calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? L("status.updatedDate", monthText, day, time)
            : L("status.updatedYear", monthText, day, time, year)
    }

    static func help(_ date: Date?, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String? {
        date.map { L("status.lastSuccessfulUpdate", absolute($0, now: now, calendar: calendar)) }
    }
}
