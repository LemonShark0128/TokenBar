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
    /// 已提醒过「重置前会用完」的窗口：按重置时间区分；没有重置时间记 nil，回到够用后才重新武装
    private var runoutWindow: [ProviderID: Date?] = [:]

    static let defaultsKey = "platformAlerts.state"

    private enum CodingKeys: String, CodingKey {
        case below, lowAt, spikeAt, hourlyAt, runoutWindow
    }

    /// 用对象保留 nil 窗口，区别于字典里没有这个平台的记录。
    private struct RunoutWindow: Codable {
        var resetsAt: Date?
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
        below = try decodeValues(Bool.self, forKey: .below)
        lowAt = try decodeValues(Date.self, forKey: .lowAt)
        spikeAt = try decodeValues(Date.self, forKey: .spikeAt)
        hourlyAt = try decodeValues(Date.self, forKey: .hourlyAt)
        runoutWindow = try decodeValues(RunoutWindow.self, forKey: .runoutWindow).mapValues { $0.resetsAt }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func encodeValues<Value: Encodable>(_ values: [ProviderID: Value], forKey key: CodingKeys) throws {
            try container.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }), forKey: key)
        }
        try encodeValues(below, forKey: .below)
        try encodeValues(lowAt, forKey: .lowAt)
        try encodeValues(spikeAt, forKey: .spikeAt)
        try encodeValues(hourlyAt, forKey: .hourlyAt)
        try encodeValues(runoutWindow.mapValues { RunoutWindow(resetsAt: $0) }, forKey: .runoutWindow)
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

    /// 与「额度已用完」提醒一致：已添加的套餐平台，任一窗口有效已用达到 100%
    static func exhaustedPlatforms(_ platforms: [PlatformState], now: Date) -> Set<ProviderID> {
        Set(platforms.compactMap { st in
            guard ProviderRegistry.meter(st.id) == .quota, st.status != .notAdded,
                  let q = st.snapshot?.quota,
                  q.windows.contains(where: { $0.effectiveUsed(at: now) >= 100 }) else { return nil }
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

    /// 同一个窗口的重置时间在两次读数之间会抖动（服务器时间带毫秒、桌面记录按读数估算），
    /// 差 1 小时以内算同一个窗口（窗口至少 5 小时一个，不会误并）
    static let windowTolerance: TimeInterval = 3600
    static func sameWindow(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x.timeIntervalSince(y)) < windowTolerance
        default: return false
        }
    }

    /// 套餐重置前会用完：每个窗口只提醒一次（窗口按重置时间区分）；低于预警线时也看原始读数
    mutating func runoutToFire(_ risks: [PlatformRisk], now: Date, canFire: (ProviderID) -> Bool = { _ in true }) -> [ProviderID] {
        var out: [ProviderID] = []
        for r in risks {
            guard let q = r.quotaReading else { continue }      // RiskRanker 对套餐平台总会带上原始读数
            guard q.state == .runsOut else {
                // 没有重置时间的窗口：恢复够用就重新武装（有重置时间的按窗口记，同一窗口不再提醒）
                if let w = runoutWindow[r.id], w == nil { runoutWindow.removeValue(forKey: r.id) }
                continue
            }
            if let w = runoutWindow[r.id], Self.sameWindow(w, q.resetsAt) { continue }
            guard canFire(r.id) else { continue }
            runoutWindow[r.id] = .some(q.resetsAt)
            out.append(r.id)
        }
        return out
    }
}
