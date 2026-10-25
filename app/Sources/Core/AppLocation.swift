import Foundation

/// App 现在从哪里运行
enum AppLocation {
    /// 从 dmg（/Volumes/…）里直接运行，或被系统隔离到临时目录（App Translocation）：路径随时会失效，
    /// 不能写进开机自启的守护 plist
    static func isTransient(_ bundlePath: String) -> Bool {
        bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/")
    }
}
