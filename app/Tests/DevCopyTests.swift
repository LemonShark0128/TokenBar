import Foundation

/// 开发 / 渲染用的 TokenBar 副本跑完要从系统登记里去掉，免得通知中心挑中旧副本（10-27 实机：通知显示成「DeepSeek 用量条」、点通知拉起 10-14 的老版本）
@MainActor
func registerDevCopyTests() {
    let home = URL(fileURLWithPath: "/Users/test user")
    test("devCopyKeepsInstalledApp") {
        try check(!DevCopy.shouldForget(bundle: home.appendingPathComponent("Applications/TokenBar.app"), home: home), "正式安装位置不去掉")
        try check(!DevCopy.shouldForget(bundle: home.appendingPathComponent("Applications/TokenBar.app/"), home: home), "末尾斜杠也算正式位置")
        try check(!DevCopy.shouldForget(bundle: URL(fileURLWithPath: "/Applications/TokenBar.app"), home: home), "装在系统应用程序里的不去掉")
    }
    test("devCopyForgetsBuildOutputs") {
        try check(DevCopy.shouldForget(bundle: URL(fileURLWithPath: "/Users/test user/.hermes/token-dashboard/app/build/TokenBar.app"), home: home), "编译产物")
        try check(DevCopy.shouldForget(bundle: URL(fileURLWithPath: "/private/tmp/scratch dir/app/build/TokenBar.app"), home: home), "临时副本")
        try check(!DevCopy.shouldForget(bundle: URL(fileURLWithPath: "/usr/local/bin"), home: home), "不是 .app 不管")
    }
}
