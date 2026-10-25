import Foundation

/// 记住已经提醒过的用完窗口；恢复额度或移除平台后重新允许提醒。
struct ExhaustedAlertMemory: Equatable {
    var keys: Set<String> = []

    static func key(_ id: ProviderID, _ w: QuotaWindow) -> String {
        "\(id.rawValue)|\(QuotaText.windowName(w.kind))|\(w.resetsAt.map { "\(Int($0.timeIntervalSince1970 / 60))" } ?? "-")"
    }

    mutating func toFire(_ platforms: [PlatformState], now: Date) -> [(id: ProviderID, window: QuotaWindow)] {
        var result: [(id: ProviderID, window: QuotaWindow)] = []
        for st in platforms where ProviderRegistry.meter(st.id) == .quota {
            let prefix = "\(st.id.rawValue)|"
            if st.status == .notAdded {
                keys = keys.filter { !$0.hasPrefix(prefix) }
                continue
            }
            // 没有读数不代表额度恢复；不在列表里的平台也保留记录。
            guard let quota = st.snapshot?.quota else { continue }
            let exhausted = quota.windows.filter { $0.effectiveUsed(at: now) >= 100 }
            // 同一窗口每轮读到的重置时间会差几十秒（跨分钟）、偶尔读不到：相差 5 分钟以内或缺重置时间都算同一次
            var kept: Set<String> = []
            var fresh: [(key: String, window: QuotaWindow)] = []
            for w in exhausted {
                let k = Self.key(st.id, w)
                if let old = keys.first(where: { $0.hasPrefix(prefix) && !kept.contains($0) && Self.sameWindow($0, k) }) {
                    kept.insert(old)
                } else {
                    fresh.append((k, w))
                }
            }
            keys = keys.filter { !$0.hasPrefix(prefix) || kept.contains($0) }
            for f in fresh where keys.insert(f.key).inserted {
                result.append((id: st.id, window: f.window))
            }
        }
        return result
    }

    /// 两条记录是不是同一个窗口的同一次用完：平台和窗口相同，重置时间相差不超过 5 分钟（任一边没有重置时间也算）
    static func sameWindow(_ a: String, _ b: String) -> Bool {
        func split(_ k: String) -> (String, Int?) {
            guard let i = k.lastIndex(of: "|") else { return (k, nil) }
            return (String(k[..<i]), Int(k[k.index(after: i)...]))
        }
        let (pa, ma) = split(a), (pb, mb) = split(b)
        guard pa == pb else { return false }
        guard let ma, let mb else { return true }
        return abs(ma - mb) <= 5
    }

    static func load(_ d: UserDefaults) -> ExhaustedAlertMemory {
        ExhaustedAlertMemory(keys: Set(d.stringArray(forKey: "quotaExhausted.alerted") ?? []))
    }

    func save(_ d: UserDefaults) { d.set(keys.sorted(), forKey: "quotaExhausted.alerted") }
}
