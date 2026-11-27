import Foundation

/// Gemini 套餐：调用本机 Antigravity CLI（`agy -p /usage --output-format json`）读取实时额度。
/// 不调用模型、不花 token、不读登录凭据；登录和网络由 `agy` 自己处理。
struct GeminiPlanProvider: UsageProvider {
    let cli: @Sendable (Date) async throws -> GeminiCLIUsage.Outcome
    let retryDelays: [TimeInterval]
    let sleep: @Sendable (TimeInterval) async -> Void

    init(cli: @escaping @Sendable (Date) async throws -> GeminiCLIUsage.Outcome = { _ in .notInstalled },
         retryDelays: [TimeInterval] = [5, 25],
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.cli = cli
        self.retryDelays = retryDelays
        self.sleep = sleep
    }

    var id: ProviderID { .geminiPlan }
    var capabilities: Capabilities { ProviderRegistry.capabilities(.geminiPlan) }

    func validate(_ c: Credentials) async -> ValidationResult { .ok(summary: "") }

    func fetch(_ c: Credentials, now: Date, timeZone: TimeZone) async -> Result<ProviderSnapshot, ProviderError> {
        var outcome = (try? await cli(now)) ?? .failed(L("cli.error"))
        for delay in retryDelays {
            if outcome == GeminiCLIUsage.throttled || GeminiCLIUsage.isLoginProblem(outcome) { break }
            switch outcome {
            case .quota, .notInstalled, .noQuotas: break
            case .failed, .unrecognized:
                await sleep(delay)
                outcome = (try? await cli(now)) ?? .failed(L("cli.error"))
                continue
            }
            break
        }
        var s = ProviderSnapshot(provider: .geminiPlan, balance: nil, today: nil, month: nil, byModel: [],
                                 trend7: [], source: .quota, fetchedAt: now, credential: .ok)
        switch outcome {
        case .quota(let q):
            s.quota = q
            return .success(s)
        case .noQuotas:
            s.quotaNote = L("gemini.noWindowsNote")
            return .success(s)
        case .notInstalled:
            return .failure(.unavailable(L("gemini.cli.notInstalled")))
        case .unrecognized:
            return .failure(.schemaChanged(L("gemini.cli.unrecognized")))
        case .failed(let why):
            if GeminiCLIUsage.isLoginProblem(outcome) { return .failure(.auth(why)) }
            // 限流直接透传完整提示句（UsageStore 套餐失败分支不展示 .rateLimited，.unavailable 才能把文案带到面板和卡片）
            if outcome == GeminiCLIUsage.throttled { return .failure(.unavailable(why)) }
            return .failure(.unavailable(L("gemini.cli.failed", why)))
        }
    }
}
