import Foundation

/// 仅由真实面板的可见状态驱动；时间由调用方注入，便于验证关闭和换提醒的边界。
struct PanelReminderTimer {
    private var started: [String: TimeInterval] = [:]
    private var delivered: Set<String> = []

    mutating func update(visible: Bool, keys: Set<String>, now: TimeInterval) {
        guard visible else {
            started.removeAll()
            delivered.removeAll()
            return
        }
        started = started.filter { keys.contains($0.key) }
        delivered.formIntersection(keys)
        for key in keys where started[key] == nil { started[key] = now }
    }

    mutating func takeExpired(now: TimeInterval) -> Set<String> {
        let expired = Set(started.compactMap { key, start in
            now - start >= 3 && !delivered.contains(key) ? key : nil
        })
        delivered.formUnion(expired)
        return expired
    }
}
