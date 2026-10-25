import Foundation

/// 用户看得到的 App 名字。只管显示：bundle id、launchd 标签、钥匙串服务名、
/// ~/Applications/TokenBar.app、Application Support/TokenBar 这些内部标识都不改（改了会丢数据和登录状态）
enum AppName {
    static let display = "Token Bar"
}
