import Foundation

/// 从 dmg 里直接双击、或被系统隔离运行（App Translocation）时，App 路径是临时的：
/// 不能把它写进开机自启的守护 plist，否则推出 dmg 后开机自启就失效（1.0.0 打包前审查）
@MainActor
func registerAppLocationTests() {
    test("appLocationTransientPaths") {
        try check(AppLocation.isTransient("/Volumes/Token Bar 1.0.0/TokenBar.app"))
        try check(AppLocation.isTransient("/private/var/folders/x1/abc/T/AppTranslocation/1234-5678/d/TokenBar.app"))
        try check(!AppLocation.isTransient("/Applications/TokenBar.app"))
        try check(!AppLocation.isTransient("/Users/someone/Applications/TokenBar.app"))
        try check(!AppLocation.isTransient("/Users/someone/Volumes/TokenBar.app"))
    }
}
