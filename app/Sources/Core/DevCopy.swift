import Foundation

/// 开发 / 渲染时编出来的 TokenBar 副本：跑完要从系统应用登记（LaunchServices）里去掉。
/// 同一个 bundle id 登记了多份时，通知中心可能挑中旧副本——通知显示旧名字和图标，点通知还会拉起旧版本（10-27 实机）
enum DevCopy {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// 装在 ~/Applications 或 /Applications 里的是正式版，保留；其余 .app（编译产物、临时副本）都去掉登记
    static func shouldForget(bundle: URL, home: URL) -> Bool {
        let path = bundle.standardizedFileURL.path
        guard path.hasSuffix(".app") else { return false }
        let installed = [home.appendingPathComponent("Applications/TokenBar.app"), URL(fileURLWithPath: "/Applications/TokenBar.app")]
        return !installed.contains { $0.standardizedFileURL.path == path }
    }
}
