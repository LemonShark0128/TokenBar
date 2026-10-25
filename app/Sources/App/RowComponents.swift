import AppKit
import Combine
import SwiftUI

// ---------------------------------------------------------------- B：数字行、口径标记、辅助平台行、套餐窗口列表

/// 今日 / 本月 / 第三格 —— 一行，不用卡片
struct StatRow: View {
    let items: [(String, String)]
    let p: Palette
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.0).font(.system(size: 11)).foregroundColor(p.sub)
                    Text(it.1).font(.num(17, .semibold)).foregroundColor(p.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11yText.stats(items))
    }
}

/// 口径标记：估算=橙、只有余额=灰；平台账单是正常情况，不再写「平台账单口径」（第 4 节，来源放在今日 / 本月的悬停提示）
struct SourceTag: View {
    let source: String?
    var p: Palette? = nil
    var body: some View {
        let tag = costSourceTag(source)
        if tag != "账单" { label(tag) }
    }

    @ViewBuilder private func label(_ tag: String) -> some View {
        // 只有余额是正常状态（没登录控制台），用中性灰，不当成警告
        let c: Color = tag == "余额" ? .secondary : Accent.orange
        let text = tag == "余额" ? L("row.balanceOnlyHint") : (sourceLabel(source) ?? L("source.unknownBasis"))
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 5, height: 5)
            Text(text).font(.system(size: 10.5)).foregroundColor(tag == "余额" ? c : (p?.warnText ?? c))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("menu.dataBasisA11y", A11yText.speak(text)))
    }
}

/// 辅助平台的一行：小油量图标 · 名称 · 今日花费（或异常原因，标橙）· 余额。点一行设为主平台
/// 套餐平台：名称旁是重置时间，右侧是「已用 41%」
struct SideRow: View {
    let side: AppData.Side
    let level: Double
    let p: Palette
    var match: SwitchMatch? = nil
    var body: some View {
        HStack(spacing: 8) {
            GaugeLogo(value: level, size: 15, quota: side.isQuota).switchGeometry(match, "gauge")
            Text(side.name).font(.system(size: 12)).foregroundColor(p.text).switchGeometry(match, "name")
            // 用完时右边已写「下次重置：…」，中间不再写「低于预警线」或别的窗口的重置时间（会互相矛盾）
            if let text = side.riskText, side.quotaExhausted == nil {
                Text(text).font(.system(size: 11)).foregroundColor(riskTint(side.riskSeverity, ok: p.sub, p: p)).lineLimit(1)
            } else if side.needsAttention {
                Text(side.status).font(.system(size: 11)).foregroundColor(p.warnText).lineLimit(1)
            } else if side.isQuota, side.quotaExhausted == nil {
                if let r = side.quotaReset {
                    Text(r).font(.num(11, .regular)).foregroundColor(p.sub).lineLimit(1)
                }
            } else if let t = side.todayCost {
                LT("panel.todayMoney", fmtMoney(t, side.currency))
                    .font(.num(11, .regular)).foregroundColor(p.sub).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(side.isQuota ? side.quotaExhausted?.text ?? L("panel.used", quotaUsedPercent(remaining: side.quotaRemaining))
                 : fmtMoney(side.tank, side.currency))
                .font(.num(13, .semibold)).foregroundColor(side.quotaStale ? p.sub : remainingTint).lineLimit(1)
                .layoutPriority(1)
                .switchGeometry(match, "value")
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11yText.side(side))
    }

    private var remainingTint: Color {
        if side.quotaExhausted != nil { return p.text }
        guard side.isQuota, let remaining = side.quotaRemaining else { return p.text }
        switch QuotaLevel.severity(usedPercent: 100 - remaining) {
        case .ok: return p.text
        case .warn: return p.warnText
        case .danger: return p.dangerText
        }
    }
}

/// 套餐平台主面板的窗口列表：每个窗口一行 —— 窗口名 · 细进度条 · 「已用 41%」或「已重置」· 重置时间
struct QuotaWindowList: View {
    let rows: [AppData.QuotaRow]
    let p: Palette
    var dimmed: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { r in
                let used = r.isReset ? 0 : max(0, min(100, r.usedPercent)) / 100
                HStack(spacing: 8) {
                    Text(r.name).font(.system(size: 12)).foregroundColor(p.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: 70, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(p.track)
                            Capsule().fill(dimmed ? p.sub.opacity(0.5) : quotaTint(QuotaLevel.severity(usedPercent: r.usedPercent))).frame(width: g.size.width * used)
                        }
                    }
                    .frame(height: 5)
                    // 已用和重置时间定宽，各行进度条一样长
                    Text(r.isReset ? L("quota.windowResetShort") : L("panel.used", quotaUsedPercent(remaining: 100 - r.usedPercent)))
                        .font(.num(11.5, .medium)).foregroundColor(p.text).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: 58, alignment: .trailing)
                    Text(r.reset ?? "").font(.system(size: 11)).foregroundColor(p.sub).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: 108, alignment: .leading)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(A11yText.quotaWindow(r) + (dimmed ? L("panel.noData") : ""))
            }
        }
    }
}
