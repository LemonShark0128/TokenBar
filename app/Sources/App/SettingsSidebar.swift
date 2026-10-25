import AppKit
import Combine
import SwiftUI

// ---------------------------------------------------------------- 设置：左侧分类侧栏

/// 侧栏宽度（设置窗 600pt 宽，左边 150pt 侧栏）
let kSettingsSidebarWidth: CGFloat = 150
let kSettingsWidth: CGFloat = 600

/// 设置左侧的分类侧栏：图标 + 名称，选中项有底色；底部小字「数据更新于 …」
struct SettingsSidebar: View {
    let selected: SettingsPage
    let updated: String
    let p: Palette
    let onPick: (SettingsPage) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases, id: \.self) { page in
                let on = page == selected
                Button { onPick(page) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: page.symbol).font(.system(size: 12.5))
                            .foregroundColor(Accent.blue).frame(width: 18)
                        Text(page.title).font(.system(size: 12.5, weight: on ? .semibold : .regular))
                            .foregroundColor(p.text).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(on ? (p.dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.title)
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
            Spacer(minLength: 8)
            // 时间带日期，一行放不下：分两行
            VStack(alignment: .leading, spacing: 1) {
                LT("set.dataUpdated").font(.system(size: 10.5))
                Text(updated).font(.num(10.5, .regular)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundColor(p.sub)
            .padding(.horizontal, 8).padding(.bottom, 4)
            .accessibilityElement(children: .combine)
        }
        .padding(8)
        .frame(width: kSettingsSidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(p.dark ? Color.black.opacity(0.18) : Color.black.opacity(0.035))
        .overlay(alignment: .trailing) { Rectangle().fill(p.border).frame(width: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("set.categories"))
    }
}

/// 正在显示的平台的小徽标（用户 10-19：「主平台」的说法已去掉）
struct MainBadge: View {
    var body: some View {
        LT("set.showing").font(.system(size: 10)).foregroundColor(Accent.blue)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Accent.blue.opacity(0.14)))
            .accessibilityLabel(L("set.showingA11y"))
    }
}
