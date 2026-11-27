import Foundation

enum ProviderID: String, Codable, CaseIterable {
    case deepseek, siliconflow, codexPlan, claudePlan, kimi, openrouter, packyapi, geminiPlan
}

/// 平台能做什么；界面据此决定画余额油箱还是额度油箱、刷新多快
struct Capabilities {
    /// 外部登录可自行恢复的平台，缩短凭据失效后的检查间隔。
    var credentialRetryInterval: TimeInterval? = nil
    var hasBalance: Bool
    var currency: Currency
    var minPollInterval: TimeInterval
    /// 油箱按金额还是套餐额度百分比
    var meter: Meter = .money
    /// 套餐平台读本地文件，不需要凭据
    var needsCredentials: Bool = true
    /// 平台没有账单接口：今日 / 本月花费和近 7 天按余额采样的下降量估算（Kimi）
    var estimatesSpendFromBalance: Bool = false
    /// 有按模型 / token 明细（缓存命中率、近 7 天 token 柱图）；OpenRouter 只给花费金额，没有
    var hasTokenDetail: Bool = true
    /// 平台「本月累计花费」按哪个时区换月（nil = 用户所在时区）；OpenRouter 按 UTC，
    /// 算时速时要用它判断两次采样之间累计花费是不是清零了
    var billingTimeZone: TimeZone? = nil
}

/// 平台直接给的日均花费（没有逐日账单时，用本周 / 本月累计 ÷ 已过天数）；days = 覆盖的天数（含今天）
struct DailyAverage: Equatable, Codable {
    var perDay: Decimal
    var days: Int
}

struct ModelUsage: Equatable, Codable {
    var model: String
    var cacheHit: Int
    var cacheMiss: Int
    var output: Int
    var requests: Int
    var cost: Money?
}

enum SnapshotSource: String, Codable {
    /// 平台账单（有今日/本月花费）
    case bill
    /// 只有余额（如 DeepSeek 未登录控制台）
    case balanceOnly
    /// 套餐额度（读本地文件，没有金额）
    case quota
    /// 花费按余额变化估算（平台没有账单接口，如 Kimi）
    case balanceEstimate
}

enum CredentialState: Equatable, Codable {
    case ok
    case expiring(days: Int)
    case invalid
}

struct DayUsage: Equatable, Codable {
    /// yyyy-MM-dd（按该平台的日界）
    var day: String
    var tokens: Int
    var cost: Money?
    /// 当天按模型拆分（点趋势柱打开单日详情时用）
    var models: [ModelUsage] = []
}

/// 每个平台每次取数返回的统一快照；界面与异常判断只认它
struct ProviderSnapshot: Equatable, Codable {
    var provider: ProviderID
    var balance: Money?
    var today: Money?
    var month: Money?
    var byModel: [ModelUsage]
    var trend7: [DayUsage]
    var source: SnapshotSource
    var fetchedAt: Date
    var credential: CredentialState
    /// 保留确切到期日，避免整数剩余天数随刷新时刻变化导致重复提醒。
    var credentialExpiresAt: Date? = nil
    /// 主凭据（API Key）正常，但网页控制台登录失效：只剩余额，花费处提示重新登录控制台
    var consoleLoginNeeded: Bool = false
    /// 控制台登录还有效，但取不到花费（如认不出这把 Key）：降级为只有余额，界面说明原因
    var consoleProblem: String? = nil
    /// 本月按模型汇总（按平台日界的本月日桶）；没有账单或旧快照为 nil
    var monthByModel: [ModelUsage]? = nil
    /// 明细到了页数上限没拉完：近 7 天趋势、按模型可能少算（界面标「不完整」）；完整为 nil
    var detailTruncated: Bool? = nil
    /// monthByModel 只覆盖本月一部分（明细只拉近 7 天，或被截断）；完整为 nil
    var monthByModelPartial: Bool? = nil
    /// 套餐平台的额度窗口；按量付费平台与旧快照为 nil
    var quota: Quota? = nil
    /// quota 为 nil 时界面显示的那句话
    var quotaNote: String? = nil
    /// 没有逐日账单（trend7 为空）但平台给了周 / 月累计时的日均（OpenRouter）；其他平台与旧快照为 nil
    var dailyAverage: DailyAverage? = nil
    /// balance 是 API Key 的剩余花费上限，不是账户余额（OpenRouter 读不到账户余额、或 Key 上限更小时）；
    /// 界面把这个数叫「Key 剩余额度」（用户 11/7 选 proposal-openrouter-balance 乙）。其他平台为 nil
    var balanceIsKeyLimit: Bool? = nil
}

extension ProviderSnapshot {
    /// 把日桶里属于本月（day 以「yyyy-MM」开头）的按模型用量加起来；用量最多的排前面
    static func monthByModel(_ days: [DayUsage], month: String) -> [ModelUsage] {
        var acc: [String: ModelUsage] = [:]
        for d in days where d.day.hasPrefix(month) {
            for m in d.models {
                var a = acc[m.model] ?? ModelUsage(model: m.model, cacheHit: 0, cacheMiss: 0, output: 0, requests: 0, cost: nil)
                a.cacheHit += m.cacheHit; a.cacheMiss += m.cacheMiss; a.output += m.output; a.requests += m.requests
                if let c = m.cost { a.cost = Money(amount: (a.cost?.amount ?? 0) + c.amount, currency: c.currency) }
                acc[m.model] = a
            }
        }
        func tokens(_ m: ModelUsage) -> Int { m.cacheHit + m.cacheMiss + m.output }
        return acc.values.filter { tokens($0) + $0.requests > 0 || ($0.cost?.amount ?? 0) > 0 }
            .sorted { tokens($0) != tokens($1) ? tokens($0) > tokens($1) : $0.model < $1.model }
    }
}

enum ProviderError: Error, Equatable {
    case network(String)
    /// 401/403 或平台业务码判定的登录失效
    case auth(String)
    case rateLimited
    /// 响应格式变了、解析不了（与登录失效分开）
    case schemaChanged(String)
    /// 我们发的参数不对（如 DeepSeek biz_code ≠ 0），不是登录问题
    case badRequest(String)
    /// 平台层面不可用（如读不到套餐额度文件、控制台没认出这把 Key）
    case unavailable(String)
}

extension ProviderError {
    /// 失败原因原文（日志、状态详情用）；限流没有原文，返回 nil
    var detail: String? {
        switch self {
        case .network(let m), .auth(let m), .schemaChanged(let m), .badRequest(let m), .unavailable(let m): return m
        case .rateLimited: return nil
        }
    }
}

/// 凭据键：apiKey、webToken
struct Credentials: Equatable {
    var values: [String: String]
}

enum ValidationResult: Equatable {
    case ok(summary: String)
    case failed(ProviderError)
}
