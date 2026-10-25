import Foundation

/// 引导「选平台」的勾选规则：已添加的平台自动勾上、不用再验证，只有新勾的平台走连接流程；
/// 取消勾选已添加的平台等于「移除」，点「完成」/「下一步」并确认后才生效
enum OnboardingPlan {
    /// 打开选平台页时的勾选：已添加的全部勾上；从设置里「添加」某个平台时再加上它；什么都没有时默认勾 DeepSeek
    static func initialPicked(added: Set<ProviderID>, only: ProviderID?) -> Set<ProviderID> {
        if let only { return added.union([only]) }
        return added.isEmpty ? [.deepseek] : added
    }

    /// 要走连接流程的平台（新勾的），按界面顺序
    static func toSetUp(picked: Set<ProviderID>, added: Set<ProviderID>) -> [ProviderID] {
        ProviderRegistry.all.filter { picked.contains($0) && !added.contains($0) }
    }

    /// 要移除的平台（已添加、被取消勾选的），按界面顺序
    static func toRemove(picked: Set<ProviderID>, added: Set<ProviderID>) -> [ProviderID] {
        ProviderRegistry.all.filter { added.contains($0) && !picked.contains($0) }
    }

    /// 选平台页底部按钮：有新勾的平台要连接写「下一步」；没有但添加过（或要移除）写「完成」；什么都没有写「跳过」
    static func pickButton(picked: Set<ProviderID>, added: Set<ProviderID>) -> String {
        if !toSetUp(picked: picked, added: added).isEmpty { return L("ob.next") }
        return added.isEmpty ? L("ob.skip") : L("ob.done")
    }

    /// 逐个连接平台时每页右下角的按钮：最后一个平台写「完成」，否则「下一步」
    static func stepButton(isLast: Bool) -> String { isLast ? L("ob.done") : L("ob.next") }

    /// 选平台页每行勾选框的样子：已连接的平台绿勾，新勾的蓝勾，已添加但没连上的灰勾
    enum PickCheck: Equatable { case off, new, connected, addedNotConnected }

    static func pickCheck(on: Bool, added: Bool, state: AccountState?) -> PickCheck {
        guard on else { return .off }
        guard added else { return .new }
        switch state {
        case .ok?, .balanceOnly?, .expiring?: return .connected
        default: return .addedNotConnected
        }
    }

    /// 已添加平台那一行的副标题
    static func addedDetail(on: Bool, state: AccountState?) -> String {
        guard on else { return L("ob.addedUncheckToRemove") }
        if pickCheck(on: true, added: true, state: state) == .connected { return L("ob.connected") }
        return L("ob.addedState", (state ?? .offline).label)
    }

    /// 移除一个平台时确认框里的说明（设置里的「移除」和选平台页共用）。
    /// claudeRestoresHook：Claude 套餐移除时要不要还原 settings.json（桌面来源且没留着钩子时不碰任何文件）
    static func removeDetail(_ id: ProviderID, claudeRestoresHook: Bool = true) -> String {
        if id == .claudePlan && !claudeRestoresHook {
            return L("remove.detail.claudeDesktop")
        }
        if id == .claudePlan { return L("remove.detail.claudeTerminal") }
        if ProviderRegistry.meter(id) == .quota { return L("remove.detail.quota") }
        return L("remove.detail.payg")
    }

    /// 移除确认框的标题和说明；多个平台时逐个写「平台名：说明」
    static func removeConfirm(_ ids: [ProviderID], claudeRestoresHook: Bool = true) -> (title: String, detail: String) {
        let title = L("remove.title", ids.map(ProviderRegistry.displayName).joined(separator: L("common.listSep")))
        func detail(_ id: ProviderID) -> String { removeDetail(id, claudeRestoresHook: claudeRestoresHook) }
        if ids.count == 1, let id = ids.first { return (title, detail(id)) }
        return (title, ids.map { L("remove.detailLine", ProviderRegistry.displayName($0), detail($0)) }.joined(separator: "\n"))
    }
}

/// 引导一次打开期间的状态：打开时的已添加平台、勾选、待连接队列。
/// 队列在进入连接步骤时定下来，之后不随存储变化——连接成功的平台会马上变成「已添加」，
/// 如果每次界面刷新都按此刻的已添加平台重算，正在连接的平台就会从队列里消失（第四批第 3 条）。
/// 队列走完 current 为 nil，界面收尾；绝不回落到某个默认平台
struct OnboardingFlow: Equatable {
    /// 打开引导时已添加的平台
    let addedAtOpen: Set<ProviderID>
    /// 从设置里「添加」某个平台：只走它这一个
    let only: ProviderID?
    var picked: Set<ProviderID>
    private(set) var queue: [ProviderID] = []
    private(set) var index = 0

    init(added: Set<ProviderID>, only: ProviderID?, picked: Set<ProviderID>? = nil) {
        addedAtOpen = added
        self.only = only
        self.picked = picked ?? OnboardingPlan.initialPicked(added: added, only: only)
    }

    /// 选平台页之后要连接的平台（还没定下来时用于按钮文字、是否跳过菜单栏页）
    var pending: [ProviderID] { only.map { [$0] } ?? OnboardingPlan.toSetUp(picked: picked, added: addedAtOpen) }

    /// 进入连接步骤：定下队列，从第 at 个开始
    mutating func startLogin(at: Int = 0) {
        queue = pending
        index = at
    }

    var current: ProviderID? { queue.indices.contains(index) ? queue[index] : nil }
    var isLast: Bool { index + 1 >= queue.count }

    /// 当前平台办完：还有下一个返回 true
    @discardableResult mutating func advance() -> Bool {
        index += 1
        return current != nil
    }
}
