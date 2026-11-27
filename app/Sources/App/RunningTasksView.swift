import SwiftUI

/// 「当前 · N」区：本机 Claude Code / Codex 还没收轮的任务，按开始时间排，最多 3 个。
/// 面板（compact = false）和右键卡（compact = true）共用；没有任务时不占地方。
/// 计时每秒重算文字，不重读文件；离屏预览用固定的 now
struct RunningTasksSection: View {
    let tasks: [RunningTask]
    let fixedNow: Date?
    let p: Palette
    let compact: Bool
    var showHeader: Bool = true
    var limit: Int = RunningTaskText.maxShown
    /// false：不写「还有 N 个」（调用方自己放「显示全部」）
    var showMore: Bool = true
    /// 每条任务下面那行（模型 · 已写 · 花费）最多几行
    var detailLines: Int = 2
    /// 停住的任务写短形式「停 7分」（「今天」小卡太窄）
    var shortClock = false

    var body: some View {
        if !tasks.isEmpty {
            if let fixedNow {
                content(now: fixedNow)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in content(now: ctx.date) }
            }
        }
    }

    private func content(now: Date) -> some View {
        let v = (shown: Array(tasks.prefix(max(0, limit))), more: max(0, tasks.count - limit))
        return VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            if showHeader {
            if compact {
                Text(RunningTaskText.header(count: tasks.count)).font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                SectionTitle(text: RunningTaskText.header(count: tasks.count), p: p)
            }
            }
            ForEach(v.shown, id: \.sessionKey) { t in row(t, now: now) }
            if showMore && v.more > 0 {
                Text(RunningTaskText.moreLine(v.more)).font(.system(size: 11)).foregroundColor(p.sub)
            }
        }
    }

    private func row(_ t: RunningTask, now: Date) -> some View {
        let stale = RunningTaskText.isStale(t, now: now)
        let glyph: CGFloat = 13
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(nsImage: PlatformGlyph.image(t.provider, size: glyph, tint: nil))
                    .renderingMode(.template).foregroundColor(p.sub)
                    .frame(width: glyph, height: glyph)
                Text(t.project).font(.system(size: compact ? 11.5 : 12.5))
                    .foregroundColor(stale ? p.sub : (compact ? .primary : p.text))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(RunningTaskText.clock(t, now: now, short: shortClock))
                    .font(stale ? .system(size: compact ? 11 : 11.5) : .num(compact ? 11.5 : 12, .regular))
                    // 「今天」小卡（shortClock）：停住的任务用提醒橙，往往是在等回复
                    .foregroundColor(stale ? (shortClock ? p.warnText : p.sub) : (compact ? .primary : p.text)).lineLimit(1)
            }
            Text(shortClock ? RunningTaskText.costDetail(t) : RunningTaskText.detail(t)).font(.system(size: 11)).foregroundColor(p.sub).lineLimit(detailLines)
                .padding(.leading, glyph + 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RunningTaskText.a11y(t, now: now))
    }
}
