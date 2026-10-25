import AppKit
import Combine
import SwiftUI

// ---------------------------------------------------------------- C：近 7 天柱图、模型占比、Token 明细、单日详情

/// 近 7 天 token：每天一根柱。面板里点柱子选中那一天，图例换成那天各模型的用量（再点一下或点今天回到今天）；
/// 选中的那天有主平台明细时，右上角「明细 ›」打开当天详情。离屏预览不传 onSelect：点柱子直接开详情（原来的行为）。
/// 只有一个平台有用量时与原来一样：细条、今天用正文色，其余淡灰；
/// 多个平台时按模型分段堆叠（4 种色相 + 灰色的「其他」），柱下列出今天每个模型的名字和用量，不只靠颜色
struct TrendStrip: View {
    let chart: TokenChart
    /// 主平台的 trend7：点柱子时按日期找当天的明细；套餐平台作主平台时为空（不能点）
    let days: [AppData.Day]
    let onPick: (AppData.Day) -> Void
    let p: Palette
    /// 明细到了页数上限没拉完（硅基流动重度用户）：标「不完整」，免得把少算的柱子当真
    var incomplete = false
    /// 选中的日期（yyyy-MM-dd）；nil 或不在图里 = 今天。放在 model 里：面板定高时新建的视图也要按选中的那天量
    var picked: String? = nil
    /// 点柱子：传选中的日期，选回今天时传 nil
    var onSelect: ((String?) -> Void)? = nil

    /// 选中的柱子下标
    private var sel: Int { chart.bars.firstIndex { $0.iso == picked } ?? max(chart.bars.count - 1, 0) }
    private var selIsToday: Bool { sel == chart.bars.count - 1 }

    /// 分段颜色：dataviz 默认分类色板的前 4 个槽位（蓝、橙、青绿、黄，深浅主题各一套，已用校验脚本验过），第 5 段灰色是「其他」
    static func colors(dark: Bool) -> [Color] {
        func hex(_ v: UInt32) -> Color {
            Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
        }
        return dark ? [hex(0x3987E5), hex(0xD95926), hex(0x199E70), hex(0xC98500)]
                    : [hex(0x2A78D6), hex(0xEB6834), hex(0x1BAF7A), hex(0xEDA100)]
    }
    func color(_ i: Int) -> Color {
        chart.series[i].isOther ? p.sub.opacity(0.55) : Self.colors(dark: p.dark)[min(i, 3)]
    }

    var body: some View {
        let bars = chart.bars
        let maxV = max(bars.map(\.total).max() ?? 0, 1)
        let multi = chart.multiPlatform
        let h: CGFloat = multi ? 40 : 30
        VStack(alignment: multi ? .leading : .center, spacing: 4) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(bars.enumerated()), id: \.element.iso) { i, b in
                    let chosen = i == sel
                    let day = days.first { $0.iso == b.iso }
                    Group {
                        if multi {
                            // 选中以前的某天时，其余柱子变淡，一眼看出选的是哪根
                            stack(b, index: i, height: max(2, h * CGFloat(b.total) / CGFloat(maxV)))
                                .opacity(selIsToday || chosen ? 1 : 0.4)
                        } else {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(chosen ? p.text : p.sub.opacity(b.total > 0 ? 0.45 : 0.22))
                                .frame(width: 14, height: max(2, h * CGFloat(b.total) / CGFloat(maxV)))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: h, alignment: .bottom)   // 细柱居中，不做成整块
                    .contentShape(Rectangle())
                    .onTapGesture { tapBar(i, b, chosen: chosen, day: day) }
                    .help(L("chart.barHelp", b.iso, cnCount(b.total)) + (onSelect != nil ? L("chart.barHelpClick") : ""))
                    // 读屏：一根柱子一个元素，读日期和用量；能点的标成按钮
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(A11yText.trendBar(iso: b.iso, total: b.total,
                                                          parts: chart.series.indices.map { (chart.series[$0].label, b.parts[$0]) },
                                                          isToday: i == bars.count - 1))
                    .accessibilityAddTraits(onSelect != nil || day != nil ? .isButton : [])
                    .accessibilityAddTraits(onSelect != nil && chosen ? .isSelected : [])
                    .accessibilityHint(onSelect != nil || day != nil ? A11yText.trendBarHint(opensDetail: onSelect == nil) : "")
                    .accessibilityAction { tapBar(i, b, chosen: chosen, day: day) }
                }
            }
            .frame(height: h)
            HStack {
                Text(bars.first?.date ?? "").font(.num(11, .regular)).foregroundColor(p.sub)
                    .accessibilityHidden(true)      // 每根柱子已经读了日期
                Spacer()
                if incomplete {
                    (LT("chart.titleDot").foregroundColor(p.sub) + LT("chart.incompleteTag").foregroundColor(p.warnText))
                        .font(.system(size: 11))
                        .help(L("chart.incompleteHelp"))
                } else {
                    LT("chart.title").font(.system(size: 11)).foregroundColor(p.sub)
                }
                Spacer()
                let b = bars.indices.contains(sel) ? bars[sel] : nil
                Text("\(selIsToday ? L("chart.today") : b?.date ?? "") \(cnCount(b?.total ?? 0))").font(.num(11, .regular)).foregroundColor(p.text)
                    .accessibilityLabel(A11yText.selectedDay(iso: b?.iso ?? "", total: b?.total ?? 0, isToday: selIsToday))
                if onSelect != nil, let b, let day = days.first(where: { $0.iso == b.iso }) {
                    Button { onPick(day) } label: {
                        LT("chart.details").font(.system(size: 11)).foregroundColor(Accent.blue)
                    }.buttonStyle(.plain).help(L("chart.openDayHelp", b.iso))
                    .accessibilityLabel(A11yText.openDayDetail(iso: b.iso))
                }
            }
            // 图例有两部分（模型行、「今天合计」）：包一层再加 padding，否则 padding 会分别加到每一部分上
            VStack(alignment: .leading, spacing: 4) { legend }.padding(.top, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(A11yText.trendChart(summary: chart.a11yLabel(incomplete: incomplete),
                                                allZero: chart.bars.allSatisfy { $0.total == 0 }))
    }

    private func tapBar(_ i: Int, _ b: TokenChart.Bar, chosen: Bool, day: AppData.Day?) {
        if let onSelect {
            onSelect(chosen || i == chart.bars.count - 1 ? nil : b.iso)
        } else if let day { onPick(day) }
    }

    /// 一根分段柱：第 1 名在最底下，「其他」在最上面；柱子够高时段之间留 1.5pt 缝（矮柱留缝会变成一道道细纹）
    private func stack(_ b: TokenChart.Bar, index: Int, height: CGFloat) -> some View {
        let segs = b.parts.enumerated().filter { $0.element > 0 }
        let gap: CGFloat = height / CGFloat(max(segs.count, 1)) >= 6 ? 1.5 : 0
        let avail = max(height - gap * CGFloat(max(segs.count - 1, 0)), CGFloat(segs.count))
        return VStack(spacing: gap) {
            ForEach(segs.reversed(), id: \.offset) { s in
                Rectangle().fill(color(s.offset))
                    .frame(height: max(1, avail * CGFloat(s.element) / CGFloat(max(b.total, 1))))
                    .help("\(b.date) · \(chart.partText(bar: index, series: s.offset))")
            }
            if segs.isEmpty { Rectangle().fill(p.sub.opacity(0.22)).frame(height: 2) }
        }
        .frame(width: 16)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }

    /// 图例：今天用量最多的模型，每个都写名字、token 和今日花费（色块只是辅助）；
    /// 单平台时柱子是单色，图例不画色块，只列模型（替代原来面板里的模型占比条）
    @ViewBuilder private var legend: some View {
        let items = chart.legend(bar: sel)
        let multi = chart.multiPlatform
        if items.isEmpty {
            if multi { Text(selIsToday ? L("chart.noUsageToday") : L("chart.noUsageThatDay")).font(.system(size: 11)).foregroundColor(p.sub) }
        } else {
            // 一行一个模型：名字写全（两栏会把「硅基 · Qwen3-Coder-480B」截断）
            let costs = items.map { chart.costText(series: $0.series, bar: sel) }
            let hasCost = costs.contains { $0 != nil }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.element.series) { i, it in
                    HStack(spacing: 6) {
                        if multi {
                            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color(it.series))
                                .frame(width: 8, height: 8)
                        }
                        Text(chart.series[it.series].label).font(.system(size: 11)).foregroundColor(p.sub)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(cnCount(it.tokens)).font(.num(11, .regular)).foregroundColor(p.text).lineLimit(1)
                        // 花费单独一列右对齐：看不到花费的行留空（不写 ¥0）
                        if hasCost {
                            Text(costs[i] ?? "").font(.num(11, .regular)).foregroundColor(p.sub).lineLimit(1)
                                .frame(minWidth: 44, alignment: .trailing)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(A11yText.speak("\(chart.series[it.series].label) \(cnCount(it.tokens))", separators: false)
                                        + (costs[i].map { "，" + A11yText.speak($0) } ?? ""))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let s = chart.daySummary(bar: sel, incomplete: incomplete) {
            // 上下对称：图例 → 分隔线 → 文字 → 下一条分隔线，三段留白都是 PanelLayout.sectionGap
            let gaps = PanelLayout.todaySummaryGaps(stripSpacing: 4)    // 4 = 上面包住图例的 VStack 的间距
            VStack(spacing: gaps.lineToText) {
                Hairline(p: p)
                HStack(spacing: 6) {
                    let name = selIsToday ? L("chart.todayTotalLabel") : L("chart.dayTotal", chart.bars[sel].date)
                    Text(chart.planOnly(bar: sel) ? name + L("chart.planDot") : name).font(.system(size: 11)).foregroundColor(p.sub)
                    Spacer(minLength: 8)
                    (Text(s.total).foregroundColor(p.text)
                     + Text(s.change.map { " · " + $0 } ?? "")
                        .foregroundColor(s.trend == .up ? Accent.orange : p.sub))
                        .font(.num(11, .regular)).lineLimit(1).minimumScaleFactor(0.85)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(A11yText.speak((selIsToday ? L("chart.todayTotalLabel") : L("chart.dayTotalA11y", A11yText.spokenDate(iso: chart.bars[sel].iso)))
                                                   + (chart.planOnly(bar: sel) ? L("chart.planDot") : "") + " " + s.total
                                                   + (s.change.map { " · " + $0 } ?? "")))
            }
            .padding(.top, gaps.lineAbove)
        }
    }
}

/// 模型占比：一根比例条，替代原来的两张模型卡
struct ModelShare: View {
    let models: [AppData.ModelUse]
    /// 窄窗口（小组件）只写「模型 用量」，花费和调用次数留给面板
    var compact = false
    var currency: String? = nil
    let p: Palette
    var body: some View {
        let used = models.filter { $0.todayTokens > 0 }
        let total = max(used.reduce(0) { $0 + $1.todayTokens }, 1)
        let shades: [Color] = [p.text, p.sub.opacity(0.7), p.sub.opacity(0.4), p.sub.opacity(0.25)]
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                HStack(spacing: 1.5) {
                    ForEach(Array(used.enumerated()), id: \.element.id) { i, m in
                        Rectangle().fill(shades[min(i, shades.count - 1)])
                            .frame(width: max(2, (g.size.width - 1.5 * CGFloat(used.count - 1))
                                              * CGFloat(m.todayTokens) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
            .accessibilityHidden(true)      // 比例条只是辅助，下面的文字写了数
            HStack {
                ForEach(Array(used.prefix(2).enumerated()), id: \.element.id) { i, m in
                    if i > 0 { Spacer(minLength: 8) }
                    Text(compact ? "\(m.label) \(cnCount(m.todayTokens))"
                         : "\(m.label) \(cnCount(m.todayTokens)) · \(fmtMoney(m.todayCny, currency))\(i == 0 ? L("chart.calls", m.calls) : "")")
                        .font(.num(11, .regular))
                        .foregroundColor(i == 0 ? p.text : p.sub)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityLabel(A11yText.speak(compact ? "\(m.label) \(cnCount(m.todayTokens))"
                             : "\(m.label) \(cnCount(m.todayTokens)) · \(fmtMoney(m.todayCny, currency))\(i == 0 ? L("chart.calls", m.calls) : "")"))
                }
            }
            if used.isEmpty {
                LT("chart.noUsageToday").font(.system(size: 11)).foregroundColor(p.sub)
            }
        }
    }
}

/// Token 明细：按模型切换的四个数（面板里默认收起，小组件里常显）
struct TokenDetailCard: View {
    let models: [AppData.ModelUse]
    @Binding var picked: String?
    var title: String? = nil
    let p: Palette

    var body: some View {
        let sel = models.first(where: { $0.key == (picked ?? models.first?.key) }) ?? models.first
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let t = title { SectionTitle(text: t, p: p) }
                Spacer()
                if models.count > 1 {
                    SegmentPicker(items: models.map { ($0.key, $0.label) }, selected: sel?.key, p: p) {
                        picked = $0
                    }
                }
            }
            if let m = sel {
                StatGrid(items: [(L("panel.cacheHit"), cnCount(m.cacheHit)),
                                 (L("chart.cacheMiss"), cnCount(m.cacheMiss)),
                                 (L("chart.output"), cnCount(m.output)),
                                 (L("chart.hitRate"), AppDataMapping.hitRateText(hit: m.cacheHit, miss: m.cacheMiss, rate: m.hitRate))], p: p)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(m.label)，" + A11yText.stats([(L("panel.cacheHit"), cnCount(m.cacheHit)),
                                                                     (L("chart.cacheMiss"), cnCount(m.cacheMiss)),
                                                                     (L("chart.output"), cnCount(m.output)),
                                                                     (L("chart.hitRate"), AppDataMapping.hitRateText(hit: m.cacheHit, miss: m.cacheMiss, rate: m.hitRate))]))
            } else {
                LT("chart.noUsageData").font(.system(size: 11.5)).foregroundColor(p.sub)
            }
        }
    }
}

/// 单日详情：总量 + 一根构成条（主模型的命中/未命中/输出 + 其它模型），去掉模型切换
struct DayDetail: View {
    let day: AppData.Day
    /// 模型 key（如 deepseek-flash）—— detail 字典按 key 索引；传 label（Flash）会查不到
    let modelKey: String?
    var labels: [String: String] = [:]
    var currency: String? = nil
    let p: Palette

    var body: some View {
        let det = day.detail ?? [:]
        let key = modelKey.flatMap { det[$0] != nil ? $0 : nil }
            ?? det.max(by: { $0.value.tokens < $1.value.tokens })?.key
        let d = key.flatMap { det[$0] }
        let cost = det.values.reduce(0) { $0 + $1.costCny }
        let others = det.filter { $0.key != key && $0.value.tokens > 0 }.sorted { $0.value.tokens > $1.value.tokens }
        let segs: [(String, Int, Color)] = [
            (L("panel.cacheHit"), d?.cacheHit ?? 0, p.text),
            (L("chart.cacheMiss"), d?.cacheMiss ?? 0, p.sub.opacity(0.75)),
            (L("chart.output"), d?.output ?? 0, p.sub.opacity(0.45)),
        ] + others.map { (labels[$0.key] ?? $0.key, $0.value.tokens, p.sub.opacity(0.2)) }
        let total = max(segs.reduce(0) { $0 + $1.1 }, 1)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(cnCount(day.totalTokens)).font(.num(26, .semibold)).foregroundColor(p.text)
                Text("token · \(fmtMoney(cost, currency))").font(.num(12, .regular)).foregroundColor(p.sub)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(A11yText.spokenDate(iso: day.iso))，\(A11yText.count(day.totalTokens)) token，\(A11yText.money(cost, currency: currency))")
            GeometryReader { g in
                HStack(spacing: 1.5) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                        Rectangle().fill(s.2)
                            .frame(width: max(s.1 > 0 ? 2 : 0, (g.size.width - 1.5 * CGFloat(segs.count - 1))
                                              * CGFloat(s.1) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 6).clipShape(Capsule())
            .accessibilityHidden(true)      // 构成条只是辅助，下面每行写了数
            VStack(spacing: 5) {
                ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(s.2).frame(width: 7, height: 7)
                        Text(s.0).font(.system(size: 11.5)).foregroundColor(p.sub)
                        Spacer()
                        Text(cnCount(s.1)).font(.num(12, .medium)).foregroundColor(p.text)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(s.0) \(A11yText.count(s.1))")
                }
            }
            if let d = d, let k = key {
                LT("panel.modelHitRate", labels[k] ?? k, AppDataMapping.hitRateText(hit: d.cacheHit, miss: d.cacheMiss, rate: d.hitRate))
                    .font(.system(size: 11)).foregroundColor(p.sub)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}
