import AppKit
import Combine
import SwiftUI

// ---------------------------------------------------------------- D：预警浮动卡

/// 预警浮动卡（未授权系统通知时的兜底弹窗）
struct AlertCard: View {
    let title: String
    let message: String
    let p: Palette
    /// 点 ×：默认只收起卡片；App 用它接着显示排队的下一条
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Accent.orange)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 12.5, weight: .bold)).foregroundColor(p.text)
                    .accessibilityLabel(L("alertCard.a11y", title))
                Spacer()
                Button { if let onClose { onClose() } else { Hud.hide("alert") } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(p.sub)
                }.buttonStyle(.plain)
                .accessibilityLabel(L("alertCard.close"))
            }
            Text(message)
                .font(.system(size: 11.5)).foregroundColor(p.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 340, height: 138, alignment: .topLeading)
        .background(Backdrop(p: p, material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Accent.orange.opacity(0.7), lineWidth: 1))
    }
}
