import Foundation

// ---------------------------------------------------------------- 界面语言（中文 / 英文）
//
// 界面跟随系统：系统首选语言是中文（任意 zh 变体）用中文，其余一律英文。日志不翻译（一律中文，方便排查）。
// 文案集中在 L10nStrings*.swift 的表里：key 用英文短名，每条中文、英文两列。
// 占位：{0}、{1}… 按顺序换成参数（参数用字符串插值的写法转成文字，和原来直接插值的结果一样）；
// 英文的单复数写成 {0|day|days}：参数 0 等于 1 时用前一个，否则用后一个（中文不需要，不用这个写法）。

enum Lang: String, Sendable {
    case zh, en
}

enum L10n {
    /// 当前界面语言。启动时按系统首选语言定一次；渲染预览可用 --lang en / --lang zh 指定，测试固定中文。
    /// nonisolated(unsafe)：只在启动时（还没有界面和后台任务）设置，之后只读
    nonisolated(unsafe) static var lang: Lang = detect()

    /// 系统首选语言列表的第一项是 zh 开头（zh-Hans、zh-Hant-TW、zh_CN…）→ 中文；其余（包括空列表）→ 英文
    static func detect(_ preferred: [String] = Locale.preferredLanguages) -> Lang {
        (preferred.first ?? "").lowercased().hasPrefix("zh") ? .zh : .en
    }

    static var isZh: Bool { lang == .zh }

    struct Entry: Sendable {
        let key: String
        let zh: String
        let en: String
        init(_ key: String, _ zh: String, _ en: String) {
            self.key = key
            self.zh = zh
            self.en = en
        }
    }

    /// 全部条目（各区域的表拼起来）；测试检查 key 不重复、两列都不为空
    static let entries: [Entry] = L10nStrings.common + L10nStrings.status + L10nStrings.quota + L10nStrings.a11y
        + L10nStrings.settings + L10nStrings.onboarding + L10nStrings.panel + L10nStrings.menu + L10nStrings.providers
        + L10nStrings.alerts + L10nStrings.misc

    /// key → 条目；重复的 key 取第一条（测试会报出来）
    static let table: [String: Entry] = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

    /// 取文案：查不到 key 时原样返回 key（测试会扫描源码里用到的 key，保证都在表里）
    static func text(_ key: String, _ args: [Any], lang: Lang = L10n.lang) -> String {
        guard let e = table[key] else { return key }
        return fill(lang == .zh ? e.zh : e.en, args)
    }

    /// 把 {0}、{1}… 和 {0|单数|复数} 换成参数
    static func fill(_ template: String, _ args: [Any]) -> String {
        guard !args.isEmpty, template.contains("{") else { return template }
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let inner = rest[rest.index(after: open)..<close]
            let parts = inner.split(separator: "|", omittingEmptySubsequences: false)
            if let i = Int(parts[0]), i >= 0, i < args.count {
                if parts.count == 3 {
                    out += isOne(args[i]) ? parts[1] : parts[2]
                } else {
                    out += "\(args[i])"
                }
            } else {
                out += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    private static func isOne(_ v: Any) -> Bool {
        switch v {
        case let i as Int: return i == 1
        case let d as Double: return d == 1
        case let s as String: return s == "1"
        default: return "\(v)" == "1"
        }
    }
}

/// 取当前语言的文案：L("panel.close")、L("status.minAgo", 5)
func L(_ key: String, _ args: Any...) -> String { L10n.text(key, args) }
