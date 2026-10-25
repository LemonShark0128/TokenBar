import Foundation

enum WebLoadFailure {
    static func shouldIgnore(domain: String, code: Int) -> Bool {
        (domain == NSURLErrorDomain && code == -999)
            || (domain == "WebKitErrorDomain" && (code == 102 || code == 204))
    }

    static func message(domain: String, code: Int, host: String?) -> String {
        let reason: String
        if domain == NSURLErrorDomain {
            switch code {
            case -1009, -1005: reason = L("webLoad.offline")
            case -1001: reason = L("webLoad.timeout")
            case -1003, -1004, -1006: reason = L("webLoad.host", host ?? L("webLoad.thisSite"))
            case -1206 ... -1200: reason = L("webLoad.secure")
            case -1020: reason = L("webLoad.restricted")
            default: reason = L("webLoad.other", code)
            }
        } else { reason = L("webLoad.other", code) }
        return L("webLoad.failed", reason)
    }
}
