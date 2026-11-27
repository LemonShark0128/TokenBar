import Foundation

/// 11-05 全量审查第 1 批：「用完」统一判法、提醒记忆键不随语言变、硅基流动业务码、诊断日志打码
@MainActor
func registerAuditFixTests() {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    let reset = t0.addingTimeInterval(3 * 3600)
    func plan(_ id: ProviderID, used: [Double], status: PlatformStatus = .ok) -> PlatformState {
        let windows = used.enumerated().map { i, percent in
            QuotaWindow(kind: i == 0 ? .session : .weekly, usedPercent: percent, resetsAt: reset, windowMinutes: nil)
        }
        return PlatformState(id: id, snapshot: ProviderSnapshot(provider: id, balance: nil, today: nil, month: nil,
                             byModel: [], trend7: [], source: .bill, fetchedAt: t0, credential: .ok,
                             quota: Quota(plan: nil, windows: windows, observedAt: t0)), burn: nil, status: status)
    }

    // —— 「用完」只有一种判法：剩余向下取整为 0（已用 > 99%）——
    test("auditExhaustedSameRuleEverywhere") {
        let w = QuotaWindow(kind: .session, usedPercent: 99.5, resetsAt: reset, windowMinutes: nil)
        try check(w.isExhausted(at: t0), "已用 99.5% 应算用完")
        try check(!QuotaWindow(kind: .session, usedPercent: 99, resetsAt: reset, windowMinutes: nil).isExhausted(at: t0),
                  "已用 99%（剩 1%）不算用完")
        try check(!w.isExhausted(at: reset.addingTimeInterval(1)), "重置后不算用完")
        var m = ExhaustedAlertMemory()
        try checkEqual(m.toFire([plan(.codexPlan, used: [99.5])], now: t0).count, 1)
        try checkEqual(PlatformAlertTracker.exhaustedPlatforms([plan(.codexPlan, used: [99.5])], now: t0), [.codexPlan])
        let q = Quota(plan: nil, windows: [w], observedAt: t0)
        try checkEqual(Runway.quota(q, risePP: nil, now: t0)?.state, .exhausted)
        var r = QuotaRecoveryMemory()
        _ = r.toFire([plan(.codexPlan, used: [99.5])], lowAlerts: [:], now: t0)
        try check(!r.keys.isEmpty, "已用 99.5% 应记成低位窗口")
    }

    // —— 记忆键用窗口种类（session / weekly），不用界面语言里的名字 ——
    test("auditAlertMemoryKeysAreLanguageFree") {
        let w = QuotaWindow(kind: .session, usedPercent: 100, resetsAt: reset, windowMinutes: nil)
        try check(ExhaustedAlertMemory.key(.codexPlan, w).hasPrefix("codexPlan|session|"), ExhaustedAlertMemory.key(.codexPlan, w))
        var r = QuotaRecoveryMemory()
        _ = r.toFire([plan(.codexPlan, used: [100])], lowAlerts: [:], now: t0)
        try checkEqual(r.keys, ["codexPlan|session"])
    }
    test("auditAlertMemoryMigratesLocalizedKeys") {
        let d = freshDefaults()
        let minute = Int(reset.timeIntervalSince1970 / 60)
        d.set(["codexPlan|\(QuotaText.windowName(.session))|\(minute)"], forKey: "quotaExhausted.alerted")
        var m = ExhaustedAlertMemory.load(d)
        try checkEqual(m.keys, ["codexPlan|session|\(minute)"])
        // 迁移后同一次用完不再重复提醒
        try checkEqual(m.toFire([plan(.codexPlan, used: [100])], now: t0).count, 0)
        let old = QuotaRecoveryMemory(keys: ["claudePlan|\(QuotaText.windowName(.weekly))"])
        d.set(try JSONEncoder().encode(old), forKey: "quotaRecoveryMemory")
        try checkEqual(QuotaRecoveryMemory.load(d).keys, ["claudePlan|weekly"])
    }

    test("auditLanguageFreeKeyEdgeCases") {
        // 新格式原样返回（含模型名里带「|」的）
        try checkEqual(QuotaText.languageFreeKey("codexPlan|session|123"), "codexPlan|session|123")
        try checkEqual(QuotaText.languageFreeKey("claudePlan|weeklyModel:a|b"), "claudePlan|weeklyModel:a|b")
        // 旧的按模型窗口显示名 → weeklyModel:模型名
        try checkEqual(QuotaText.languageFreeKey("claudePlan|\(QuotaText.windowName(.weeklyModel("Opus")))|9"),
                       "claudePlan|weeklyModel:Opus|9")
        // 认不出的保持原样
        try checkEqual(QuotaText.languageFreeKey("claudePlan|别的名字"), "claudePlan|别的名字")
    }

    // —— 硅基流动：只有登录类业务码（400xx）算登录失效，其余按网络问题重试 ——
    test("auditSiliconFlowBizCodes") {
        try checkEqual(SiliconFlowProvider.bizCodeError(20000), nil)
        guard case .auth? = SiliconFlowProvider.bizCodeError(40001) else { throw TestFailure(description: "40001 应为 .auth") }
        guard case .network? = SiliconFlowProvider.bizCodeError(50000) else { throw TestFailure(description: "50000 应为 .network") }
        guard case .network? = SiliconFlowProvider.bizCodeError(30001) else { throw TestFailure(description: "30001 应为 .network") }
        guard case .schemaChanged? = SiliconFlowProvider.bizCodeError(nil) else { throw TestFailure(description: "没有 code 应为 .schemaChanged") }
    }

    // —— 写进日志的命令行诊断输出要打码（邮箱、长 token）——
    test("auditCLIDiagnosticRedacted") {
        let line = Data(#"{"type":"system","account":{"email":"someone@example.com","token":"abc123def456ghi789jkl012mno345"}}"#.utf8)
        let text = ClaudeCLIUsage.diagnostic(stdout: line)
        try check(!text.contains("someone@example.com"), text)
        try check(!text.contains("abc123def456ghi789jkl012mno345"), text)
        try check(Diagnostics.redact("联系 a.b+c@mail.co 即可") == "联系 ***@*** 即可", Diagnostics.redact("联系 a.b+c@mail.co 即可"))
    }
}
