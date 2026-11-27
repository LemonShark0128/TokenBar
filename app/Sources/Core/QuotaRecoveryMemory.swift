import Foundation

/// 低位窗口恢复到至少一半时提醒一次；读不到数据时保留记忆。
struct QuotaRecoveryMemory: Equatable, Codable {
    var keys: Set<String> = []

    mutating func toFire(_ platforms: [PlatformState], lowAlerts: [ProviderID: Decimal], now: Date) -> [(id: ProviderID, window: QuotaWindow)] {
        var result: [(id: ProviderID, window: QuotaWindow)] = []
        for st in platforms where ProviderRegistry.meter(st.id) == .quota {
            let prefix = "\(st.id.rawValue)|"
            if st.status == .notAdded {
                keys = keys.filter { !$0.hasPrefix(prefix) }
                continue
            }
            guard let quota = st.snapshot?.quota else { continue }
            for w in quota.windows {
                let key = prefix + w.kind.sampleKey
                let remaining = 100 - w.effectiveUsed(at: now)
                let low = w.isExhausted(at: now) || lowAlerts[st.id].map { remaining < AppDataMapping.double($0) } == true
                if low {
                    keys.insert(key)
                } else if remaining >= 50, keys.remove(key) != nil {
                    result.append((st.id, w))
                }
            }
        }
        return result
    }

    static func load(_ d: UserDefaults) -> Self {
        guard let data = d.data(forKey: "quotaRecoveryMemory"),
              let memory = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return Self(keys: Set(memory.keys.map(QuotaText.languageFreeKey)))
    }

    func save(_ d: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        d.set(data, forKey: "quotaRecoveryMemory")
    }
}
