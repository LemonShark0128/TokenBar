import AppKit
import SwiftUI
import WebKit

// ---------------------------------------------------------------- 内嵌网页登录（DeepSeek：localStorage；硅基流动：Cookie）

/// 内嵌 WKWebView 登录窗的控制器：每秒轮询一次，取到登录凭证就回调一次。
/// 日志里只写「已取到登录凭证」，不写任何 token / cookie / subject id 的值
@MainActor
final class WebLoginController: NSObject {
    enum Capture {
        /// 从页面 localStorage 读一项（DeepSeek 的 userToken）→ ["webToken": …]
        case localStorage(key: String)
        /// 从 WKHTTPCookieStore 读一枚 Cookie（硅基流动的 session-token）
        /// → ["webToken", "subjectId", "webTokenExpiresAt"]，三项凑齐才回调
        case cookie(name: String, domain: String)
    }

    static var current: WebLoginController?
    private static var closeKeyMonitor: Any?

    static func installCloseKeyMonitor() {
        guard closeKeyMonitor == nil else { return }
        closeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = Hud.windows["weblogin"], window.isKeyWindow,
                  event.keyCode == 53 || (event.modifierFlags.contains(.command)
                    && event.charactersIgnoringModifiers == "w") else { return event }
            window.performClose(nil)
            return nil
        }
    }

    let webView: WKWebView
    private var timer: Timer?
    private let capture: Capture
    private let onCaptured: ([String: String]) -> Void
    private var checking = false
    private var finished = false
    /// 已有 token 和 subject id、但 Cookie 没有到期时间（会话型 Cookie）的轮询次数
    private var noExpiryPolls = 0
    static let noExpiryGivePolls = 5

    init(url: URL, capture: Capture, onCaptured: @escaping ([String: String]) -> Void) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()      // 不在 App 里留下网页登录态；需要的只有凭证（进钥匙串）
        webView = WKWebView(frame: .zero, configuration: cfg)
        self.capture = capture
        self.onCaptured = onCaptured
        super.init()
        webView.load(URLRequest(url: url))
        // 定时器挂在主 RunLoop 上，但回调被声明成 @Sendable：用 Task { @MainActor } 让编译器检查；
        // 晚一拍执行时 stop() 可能已经停了定时器，那就不再轮询
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.timer != nil { self?.poll() } }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        webView.stopLoading()
    }

    private func poll() {
        guard !finished, !checking else { return }
        switch capture {
        case .localStorage(let key):
            let literal = (try? JSONSerialization.data(withJSONObject: [key], options: []))
                .flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\(key)\""
            webView.evaluateJavaScript("localStorage.getItem(\(literal))") { [weak self] v, _ in
                guard let self = self, let raw = v as? String,
                      let token = DeepSeekProvider.extractUserToken(fromLocalStorageValue: raw) else { return }
                self.finish(["webToken": token])
            }
        case .cookie(let name, let domain):
            checking = true
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                DispatchQueue.main.async { self?.cookiePolled(cookies, name: name, domain: domain) }
            }
        }
    }

    private func cookiePolled(_ cookies: [HTTPCookie], name: String, domain: String) {
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard let c = cookies.first(where: {
            $0.name == name && !$0.value.isEmpty && ($0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain).hasSuffix(bare)
        }) else { checking = false; return }
        // subject id：先读页面里的 window.SF_SUBJECT_ID，没有就用当前页面 HTML 解析
        webView.evaluateJavaScript("window.SF_SUBJECT_ID || ''") { [weak self] v, _ in
            guard let self = self else { return }
            if let sid = v as? String, !sid.isEmpty { return self.cookieReady(c, subjectId: sid) }
            self.webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] h, _ in
                guard let self = self else { return }
                guard let html = h as? String, let sid = SiliconFlowProvider.parseSubjectId(html: html) else {
                    self.checking = false          // 还没进到控制台页面：下一秒再试
                    return
                }
                self.cookieReady(c, subjectId: sid)
            }
        }
    }

    private func cookieReady(_ c: HTTPCookie, subjectId: String) {
        // 到期时间先置空：没有到期时间时保存会删掉上次登录留下的旧值
        var values = ["webToken": c.value, "subjectId": subjectId, "webTokenExpiresAt": ""]
        if let exp = c.expiresDate {
            values["webTokenExpiresAt"] = String(Int(exp.timeIntervalSince1970))
        } else {
            // 会话型 Cookie 没有到期时间：多等几秒，仍没有就不带到期时间（provider 允许缺）
            noExpiryPolls += 1
            if noExpiryPolls < Self.noExpiryGivePolls { checking = false; return }
        }
        finish(values)
    }

    private func finish(_ values: [String: String]) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        logLine("已取到登录凭证")
        onCaptured(values)
    }
}

struct WebLoginSheet: NSViewRepresentable {
    let controller: WebLoginController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
