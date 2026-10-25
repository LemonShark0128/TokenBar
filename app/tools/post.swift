import Foundation
// post <object>  —— 发 TokenBar 调试快照通知
let obj = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.lemon.deepseek-tokenbar.snapshot"), object: obj, userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
