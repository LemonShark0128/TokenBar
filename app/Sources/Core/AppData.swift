import Foundation

/// 面板/小组件/菜单栏共用的视图数据（原来由 Python 采集服务的 /api/app 提供，第一期起由 AppDataMapping 从 UsageStore 生成）
struct AppData: Codable {
    struct RunwayChip: Codable, Equatable {
        var title: String; var detail: String?; var severity: Int
        var short: String
        var muted: Bool = false

        init(title: String, detail: String?, severity: Int, short: String? = nil, muted: Bool = false) {
            self.title = title; self.detail = detail; self.severity = severity
            self.short = short ?? title; self.muted = muted
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            detail = try c.decodeIfPresent(String.self, forKey: .detail)
            severity = try c.decode(Int.self, forKey: .severity)
            short = try c.decodeIfPresent(String.self, forKey: .short) ?? title
            muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        }
    }
    struct RiskBanner: Codable, Equatable {
        var id: String; var text: String; var severity: Int
        var key: String = ""

        init(id: String, text: String, severity: Int, key: String = "") {
            self.id = id; self.text = text; self.severity = severity; self.key = key
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            text = try c.decode(String.self, forKey: .text)
            severity = try c.decode(Int.self, forKey: .severity)
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        }
    }
    var runway: RunwayChip? = nil
    var banner: RiskBanner? = nil
    var sidesByRisk = false
    /// cny：油箱读数（余额），币种见 currency（nil = 人民币，旧采集服务没有这项）
    struct Balance: Codable {
        var cny: Double?; var source: String; var status: String; var ageS: Int?
        var currency: String? = nil
        /// 套餐平台：cny 装的是剩余百分比（currency = "PCT"）
        var isQuota: Bool { source == AppData.quotaSource }
    }
    static let quotaSource = "套餐剩余"
    /// 套餐平台的一行窗口
    struct QuotaRow: Codable, Equatable, Identifiable {
        var id: String; var name: String
        /// 有效已用（已重置按 0，最多 100）
        var usedPercent: Double; var isReset: Bool; var reset: String?
        /// 窄处（小组件）用的重置时间：「2:13 后重置」；已重置为 nil
        var resetShort: String? = nil
    }
    /// 套餐平台主面板的数据；quota 为 nil 时只显示 note
    struct QuotaView: Codable, Equatable {
        var remainingPercent: Double?; var headline: String?; var secondLine: String?
        var rows: [QuotaRow]; var lastUsed: String?; var note: String?
        /// 套餐名的显示形式（「Plus 套餐」）；Claude 没有
        var plan: String? = nil
        /// 窄处（小组件表盘下）用的标题：推算的重置时间不写「（推算）」，只写「约」；nil 时用 headline
        var headlineCompact: String? = nil
        var staleNote: String? = nil
        var stale: Bool = false
        /// 用完：表盘不写「剩 0%」，写「下次重置：08:00」
        var exhausted: QuotaExhausted? = nil
    }
    /// 套餐平台在菜单栏的读数：某个窗口的已用百分比
    struct MenuQuota: Codable, Equatable {
        /// 有效已用（已重置按 0，最多 100）
        var usedPercent: Double
        /// 窗口称呼：「当前会话」「本周」「本周（Opus）」
        var window: String
        /// 完整的重置说明（「2 小时 13 分后重置」）；不知道或已重置为 nil
        var reset: String?
        /// 最紧的是别的窗口时，那个窗口的已用（「本周已用 92%」）；会话本身最紧时为 nil
        var tighter: String? = nil
        /// 显示的窗口用完时的下次重置；没用完为 nil
        var exhausted: QuotaExhausted? = nil
    }
    /// 辅助平台的一行（面板辅助区、右键卡、菜单栏平台都用它）。金额都是该平台自己的币种
    struct Side: Codable, Equatable, Identifiable {
        var id: String; var name: String
        var tank: Double?
        var currency: String
        var todayCost: Double?
        /// 正常 / 凭据失效 / 接口有变化 / 连不上 / N 分钟前 / 登录 N 天后过期 …
        var status: String
        /// 套餐平台：剩余百分比和最紧窗口的重置说明（tank 为 nil）
        var quotaRemaining: Double? = nil
        var quotaReset: String? = nil
        /// 套餐用完：数字位置改写「下次重置：08:00」；没用完为 nil
        var quotaExhausted: QuotaExhausted? = nil
        /// 套餐平台：菜单栏读数（当前会话已用，没有 5 小时窗口时用最紧的窗口）
        var menuQuota: MenuQuota? = nil
        /// 套餐平台还没有额度数据时的那句说明（如「打开 Claude 桌面 App…」）；有数据时为 nil
        var quotaNote: String? = nil
        var quotaStale: Bool = false
        var riskText: String? = nil
        var riskSeverity: Int? = nil
        /// 要不要标橙（不是「正常」和「正在连接」）
        var needsAttention: Bool { status != L("side.ok") && status != L("side.connecting") }
    }
    /// 花得多快 / 还能用几天（采集服务 burn_block；1 小时口径窗口不够时为 nil）
    struct Burn: Codable {
        /// cnyPerHourRate = 近 1 小时的时速（窗口不够可信时为 nil）；cnyPerDayRate = 近 24 小时窗口的平均时速；
        /// avgCnyPerDayWeek = 近 7 天日均。后端字段名刻意不带「_1h」这类数字后缀（会被解成 …1H）
        var cnyPerHourRate: Double?; var cnyPerDayRate: Double?
        var avgCnyPerDayWeek: Double?; var runwayDays: Double?; var spike: Bool?
    }
    struct CostTok: Codable {
        var costCny: Double; var tokens: Int; var source: String?
        var known: Bool { source == "平台账单" }
    }
    struct ModelUse: Codable, Identifiable {
        var key: String; var label: String
        var cacheHit: Int; var cacheMiss: Int; var output: Int
        var todayTokens: Int; var todayCny: Double; var monthCny: Double
        var hitRate: Double; var calls: Int
        /// 账单里有没有给这个模型的今日金额；nil（旧数据）当作有。false 时 todayCny 的 0 只是占位，不能当花费显示
        var todayCostKnown: Bool? = nil
        var id: String { key }
    }
    struct Day: Codable, Identifiable {
        struct Detail: Codable {
            var tokens: Int; var costCny: Double; var cacheHit: Int
            var cacheMiss: Int; var output: Int; var hitRate: Double
        }
        var date: String; var iso: String; var totalTokens: Int
        var byModel: [String: Int]; var detail: [String: Detail]?
        var id: String { iso }
    }
    var nowLocal: String
    var balance: Balance
    var today: CostTok
    var month: CostTok
    var models: [ModelUse]
    var trend7: [Day]
    var burn: Burn?
    /// 辅助平台（已添加、非主平台）
    var sides: [Side] = []
    /// 各平台今日花费换成人民币之和；没有任何平台有今日花费时为 nil
    var totalTodayCny: Double? = nil
    /// 合计里有美元平台（按设置汇率换算）：界面加「≈」
    var totalIsApprox: Bool = false
    /// 明细到了页数上限没拉完：近 7 天趋势可能少算，界面标「不完整」（硅基流动重度用户）
    var trendIncomplete: Bool = false
    /// 各模型「本月」只覆盖本月一部分（硅基流动明细只拉近 7 天）
    var monthModelsIncomplete: Bool = false
    /// 主平台是套餐平台时的额度数据；按量付费平台为 nil
    var quota: QuotaView? = nil
    /// 「近 7 天 token」合并图里主平台以外的来源（其他按量付费平台的 trend7、套餐平台的本机日志）
    var tokenSources: [TokenSource] = []
}

extension AppData {
    /// 手写解码：第二期新加的字段旧采集 /api/app 没有（启动时 UsageStore 接上前会先读一次），缺了取默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runway = try c.decodeIfPresent(RunwayChip.self, forKey: .runway)
        banner = try c.decodeIfPresent(RiskBanner.self, forKey: .banner)
        sidesByRisk = try c.decodeIfPresent(Bool.self, forKey: .sidesByRisk) ?? false
        nowLocal = try c.decode(String.self, forKey: .nowLocal)
        balance = try c.decode(Balance.self, forKey: .balance)
        today = try c.decode(CostTok.self, forKey: .today)
        month = try c.decode(CostTok.self, forKey: .month)
        models = try c.decode([ModelUse].self, forKey: .models)
        trend7 = try c.decode([Day].self, forKey: .trend7)
        burn = try c.decodeIfPresent(Burn.self, forKey: .burn)
        sides = try c.decodeIfPresent([Side].self, forKey: .sides) ?? []
        totalTodayCny = try c.decodeIfPresent(Double.self, forKey: .totalTodayCny)
        totalIsApprox = try c.decodeIfPresent(Bool.self, forKey: .totalIsApprox) ?? false
        trendIncomplete = try c.decodeIfPresent(Bool.self, forKey: .trendIncomplete) ?? false
        monthModelsIncomplete = try c.decodeIfPresent(Bool.self, forKey: .monthModelsIncomplete) ?? false
        quota = try c.decodeIfPresent(QuotaView.self, forKey: .quota)
        tokenSources = try c.decodeIfPresent([TokenSource].self, forKey: .tokenSources) ?? []
    }
}
