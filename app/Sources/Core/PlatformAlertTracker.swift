import Foundation

/// 按平台记的提醒状态（保存在 UserDefaults）：每个平台的预警线各自提醒，换主平台不串（第七批自查）。
/// - 低于预警线：刚跌破或从没提醒过就提醒；一直在线下按「充值提醒」间隔再提醒；回到线上重新武装（规则同 AlertRepeat）
/// - 套餐已用完：覆盖低额度提醒，每轮仍记为线下并刷新提醒时间；恢复后仍在线下从最后一轮覆盖起算间隔，回到线上照常重新武装
/// - 离线、凭据失效时读不到余额：保持原状态，不当作「回到线上」（评审 I3：否则网络一抖就重复提醒）；
///   还没有读数（启动时正在连接）同样保持原状态（2026-10-18：否则每次重启都重复提醒）
/// - 用量异常增加：每个平台 6 小时内最多一次
/// - canFire：这一轮能不能真的发出（缺数据就不记成已提醒，评审 I4）
struct PlatformAlertTracker: Equatable, Codable {
    private var below: [ProviderID: Bool] = [:]
    private var lowAt: [ProviderID: Date] = [:]
    private var spikeAt: [ProviderID: Date] = [:]
    static let spikeCooldown: TimeInterval = 6 * 3600
    private var hourlyAt: [ProviderID: Date] = [:]
    static let hourlyCooldown: TimeInterval = 3600
    private var claudeLoginNotified = false
    private var claudeExpiryDays: Set<Date> = []
    private var geminiLoginNotified = false
    static let defaultsKey = "platformAlerts.state"

    private enum CodingKeys: String, CodingKey {
        case below, lowAt, spikeAt, hourlyAt, claudeLoginNotified, claudeExpiryDays, geminiLoginNotified
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decodeValues<Value: Decodable>(_ type: Value.Type, forKey key: CodingKeys) throws -> [ProviderID: Value] {
            let values = try container.decodeIfPresent([String: Value].self, forKey: key) ?? [:]
            // 不认识的平台（以后删掉的）跳过，不连累其他平台的记录
            return Dictionary(uniqueKeysWithValues: values.compactMap { rawID, value in
                ProviderID(rawValue: rawID).map { ($0, value) }
            })
        }
        claudeLoginNotified = try container.decodeIfPresent(Bool.self, forKey: .claudeLoginNotified) ?? false
        claudeExpiryDays = try container.decodeIfPresent(Set<Date>.self, forKey: .claudeExpiryDays) ?? []
        geminiLoginNotified = try container.decodeIfPresent(Bool.self, forKey: .geminiLoginNotified) ?? false
        below = try decodeValues(Bool.self, forKey: .below)
        lowAt = try decodeValues(Date.self, forKey: .lowAt)
        spikeAt = try decodeValues(Date.self, forKey: .spikeAt)
        hourlyAt = try decodeValues(Date.self, forKey: .hourlyAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func encodeValues<Value: Encodable>(_ values: [ProviderID: Value], forKey key: CodingKeys) throws {
            try container.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }), forKey: key)
        }
        try container.encode(claudeLoginNotified, forKey: .claudeLoginNotified)
        try container.encode(claudeExpiryDays, forKey: .claudeExpiryDays)
        try container.encode(geminiLoginNotified, forKey: .geminiLoginNotified)
        try encodeValues(below, forKey: .below)
        try encodeValues(lowAt, forKey: .lowAt)
        try encodeValues(spikeAt, forKey: .spikeAt)
        try encodeValues(hourlyAt, forKey: .hourlyAt)
    }

    mutating func forget(_ id: ProviderID) {
        if id == .claudePlan { claudeLoginNotified = false; claudeExpiryDays = [] }
        if id == .geminiPlan { geminiLoginNotified = false }
        below.removeValue(forKey: id)
        lowAt.removeValue(forKey: id)
        spikeAt.removeValue(forKey: id)
        hourlyAt.removeValue(forKey: id)
    }

    struct LoginAlert {
        var title: String
        var body: String
    }

    /// 只提醒 Claude；未知 / 离线不会重新武装，避免重启或临时失败重复通知。
    /// cliSource：Claude 套餐用的是 Claude Code（desktop / terminal 来源）。网页来源在 TokenBar 里登录，
    /// 引导时还没登完就可能先刷新一次，不发这条通知（卡片上照样显示要登录）
    mutating func claudeLoginAlerts(_ platforms: [PlatformState], now: Date, cliSource: Bool = true) -> [LoginAlert] {
        guard let st = platforms.first(where: { $0.id == .claudePlan }) else { return [] }
        if st.status == .credentialInvalid {
            guard cliSource, !claudeLoginNotified else { return [] }
            claudeLoginNotified = true
            // 连续限流升级来的只是「多半」：标题不说死（真限流超过 30 分钟时也会走到这里）
            let suspected = st.errorDetail == L("cli.suspectedLogin")
            return [LoginAlert(title: L(suspected ? "alert.claudeLogin.suspectedTitle" : "alert.claudeLogin.title"),
                               body: st.errorDetail ?? L("cli.needsLogin"))]
        }
        guard st.status == .ok else { return [] }
        claudeLoginNotified = false
        guard let snapshot = st.snapshot, case .expiring(let days) = snapshot.credential else { return [] }
        // 新快照带精确到期时间；旧缓存按其采集时刻估算，不能用每轮 now 滚动。
        let expiry = snapshot.credentialExpiresAt ?? snapshot.fetchedAt.addingTimeInterval(TimeInterval(days) * 86400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: expiry)
        guard claudeExpiryDays.insert(day).inserted else { return [] }
        return [LoginAlert(title: days <= 0 ? L("alert.claudeExpiry.today") : L("alert.claudeExpiry.title", days),
                           body: L("alert.claudeExpiry.body"))]
    }

    /// Gemini 套餐（本机 Antigravity CLI）登录失效提醒：掉线发一次，恢复 .ok 后重新武装；离线不重置。
    mutating func geminiLoginAlerts(_ platforms: [PlatformState]) -> [LoginAlert] {
        guard let st = platforms.first(where: { $0.id == .geminiPlan }) else { return [] }
        if st.status == .credentialInvalid {
            guard !geminiLoginNotified else { return [] }
            geminiLoginNotified = true
            return [LoginAlert(title: L("alert.geminiLogin.title"),
                               body: st.errorDetail ?? L("gemini.cli.needsLogin"))]
        }
        if st.status == .ok { geminiLoginNotified = false }
        return []
    }

    static func load(_ d: UserDefaults) -> PlatformAlertTracker {
        guard let data = d.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return state
    }

    func save(_ d: UserDefaults) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        d.set(data, forKey: Self.defaultsKey)
    }

    /// 与「额度已用完」提醒一致：已添加的套餐平台，任一窗口用完（QuotaWindow.isExhausted）
    static func exhaustedPlatforms(_ platforms: [PlatformState], now: Date) -> Set<ProviderID> {
        Set(platforms.compactMap { st in
            guard ProviderRegistry.meter(st.id) == .quota, st.status.isShown,
                  let q = st.snapshot?.quota,
                  q.windows.contains(where: { $0.isExhausted(at: now) }) else { return nil }
            return st.id
        })
    }

    /// 这一轮要发「低于预警线」提醒的平台（按 anomalies 的顺序）。
    /// known：这一轮有读数的平台（nil = 都当作有）；没有读数的平台不重新武装
    mutating func lowToFire(_ anomalies: [Anomaly], now: Date, repeatHours: Int,
                            covered: Set<ProviderID> = [], known: Set<ProviderID>? = nil,
                            canFire: (ProviderID) -> Bool = { _ in true }) -> [ProviderID] {
        let low = anomalies.compactMap { if case .lowTank(let id) = $0 { return id } else { return nil } }
        let unknown = Set(anomalies.compactMap { a -> ProviderID? in
            switch a {
            case .offline(let id), .credentialInvalid(let id): return id
            default: return nil
            }
        })
        for id in Array(below.keys) where !low.contains(id) && !unknown.contains(id) && (known?.contains(id) ?? true) {
            below[id] = false
        }
        var out: [ProviderID] = []
        for id in low {
            if covered.contains(id) {
                below[id] = true
                lowAt[id] = now
                continue
            }
            if AlertRepeat.shouldFire(wasAbove: !(below[id] ?? false), lastAt: lowAt[id], now: now, hours: repeatHours) {
                guard canFire(id) else { continue }
                lowAt[id] = now
                out.append(id)
            }
            below[id] = true
        }
        return out
    }

    /// 这一轮要发「用量异常增加」提醒的平台
    mutating func spikeToFire(_ anomalies: [Anomaly], now: Date, canFire: (ProviderID) -> Bool = { _ in true }) -> [ProviderID] {
        var out: [ProviderID] = []
        for a in anomalies {
            guard case .spike(let id) = a else { continue }
            if let t = spikeAt[id], now.timeIntervalSince(t) < Self.spikeCooldown { continue }
            guard canFire(id) else { continue }
            spikeAt[id] = now
            out.append(id)
        }
        return out
    }

    /// 每小时花费超过（近 1 小时时速 > 用户设的线）：同一平台 1 小时内最多一次
    mutating func hourlyToFire(rates: [ProviderID: Decimal], thresholds: [ProviderID: Decimal], now: Date,
                               canFire: (ProviderID) -> Bool = { _ in true }) -> [ProviderID] {
        var out: [ProviderID] = []
        for id in ProviderID.allCases {
            guard let r = rates[id], let th = thresholds[id], th > 0, r > th else { continue }
            if let t = hourlyAt[id], now.timeIntervalSince(t) < Self.hourlyCooldown { continue }
            guard canFire(id) else { continue }
            hourlyAt[id] = now
            out.append(id)
        }
        return out
    }

}
