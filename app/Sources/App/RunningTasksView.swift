import SwiftUI

/// 「当前 · N」区：本机 Claude Code / Codex 还没收轮的任务，按开始时间排，最多 3 个。
/// 面板（compact = false）和右键卡（compact = true）共用；没有任务时不占地方。
/// 计时每秒重算文字，不重读文件；离屏预览用固定的 now
struct RunningTasksSection: View {
    let tasks: [RunningTask]
    let fixedNow: Date?
    let p: Palette
    let compact: Bool

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
        let v = RunningTaskText.visible(tasks)
        return VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            if compact {
                Text(RunningTaskText.header(count: tasks.count)).font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                SectionTitle(text: RunningTaskText.header(count: tasks.count), p: p)
            }
            ForEach(v.shown, id: \.sessionKey) { t in row(t, now: now) }
            if v.more > 0 {
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
                Text(RunningTaskText.clock(t, now: now))
                    .font(stale ? .system(size: compact ? 11 : 11.5) : .num(compact ? 11.5 : 12, .regular))
                    .foregroundColor(stale ? p.sub : (compact ? .primary : p.text)).lineLimit(1)
            }
            Text(RunningTaskText.detail(t)).font(.system(size: 11)).foregroundColor(p.sub).lineLimit(1)
                .padding(.leading, glyph + 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RunningTaskText.a11y(t, now: now))
    }
}
