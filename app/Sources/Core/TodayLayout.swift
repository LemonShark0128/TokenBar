import Foundation

enum TodayCardSize: String, Codable, CaseIterable {
    case small, medium, large
    var title: String {
        switch self {
        case .small: return L("today.size.small")
        case .medium: return L("today.size.medium")
        case .large: return L("today.size.large")
        }
    }
    var columns: Int { self == .small ? 1 : 2 }
    var rows: Int { self == .large ? 2 : 1 }
}

struct TodayLayoutItem: Codable, Equatable {
    var id: String
    var size: TodayCardSize
}

enum TodayLayout {
    /// 固定格子：小 = 正方形；中 = 两格宽、一格高；大 = 2×2 正方形。卡片高度不随内容变。
    struct Frame: Equatable { var x, y, width, height: Double }

    static func cellSide(total: Double, gap: Double = 8) -> Double { max(0, (total - gap) / 2) }

    static func frame(_ placement: Placement, total: Double, gap: Double = 8) -> Frame {
        let side = cellSide(total: total, gap: gap)
        let rows = Double(placement.size.rows)
        return Frame(x: Double(placement.column) * (side + gap), y: Double(placement.row) * (side + gap),
                     width: placement.size.columns == 2 ? total : side, height: rows * side + (rows - 1) * gap)
    }

    static func boardHeight(_ placements: [Placement], total: Double, gap: Double = 8) -> Double {
        let rows = placements.map { $0.row + $0.size.rows }.max() ?? 0
        guard rows > 0 else { return 0 }
        return Double(rows) * cellSide(total: total, gap: gap) + Double(rows - 1) * gap
    }

    /// 拖动排序：松手点落在哪张卡上（缝按一半分给两边）
    static func cardAt(_ placements: [Placement], x: Double, y: Double, total: Double, gap: Double = 8) -> String? {
        let half = gap / 2
        return placements.first { placement in
            let f = frame(placement, total: total, gap: gap)
            return x >= f.x - half && x < f.x + f.width + half && y >= f.y - half && y < f.y + f.height + half
        }?.id
    }

    /// Drag deltas are relative to the starting footprint. Ties stay at the smaller size.
    static func snap(start: TodayCardSize, dx: CGFloat, dy: CGFloat,
                     cellWidth: CGFloat, cellHeight: CGFloat, allowed: Set<TodayCardSize>) -> TodayCardSize {
        guard !allowed.isEmpty, cellWidth > 0, cellHeight > 0, dx.isFinite, dy.isFinite else { return start }
        let x = CGFloat(start.columns) + dx / cellWidth
        let y = CGFloat(start.rows) + dy / cellHeight
        let target: TodayCardSize = x > 1.5 ? (y > 1.5 ? .large : .medium) : .small
        if allowed.contains(target) { return target }
        return TodayCardSize.allCases.filter { allowed.contains($0) }.min {
            let a = abs($0.columns - target.columns) + abs($0.rows - target.rows)
            let b = abs($1.columns - target.columns) + abs($1.rows - target.rows)
            return a < b
        } ?? start
    }

    struct Placement: Equatable {
        var id: String
        var size: TodayCardSize
        var row: Int
        var column: Int
        var stretched: Bool = false
    }
    static func decode(_ data: Data?) -> [TodayLayoutItem]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([TodayLayoutItem].self, from: data)
    }
    static func encode(_ layout: [TodayLayoutItem]) -> Data {
        // Strings and this closed enum cannot fail JSON encoding.
        try! JSONEncoder().encode(layout)
    }
    static func defaultLayout(platformIDs: [String]) -> [TodayLayoutItem] {
        var seen = Set<String>()
        return (platformIDs + ["spend", "running", "trend"]).filter { seen.insert($0).inserted }
            .map { .init(id: $0, size: $0 == "trend" ? .medium : .small) }
    }
    /// defaultOrder is the settings' platform order, never the current main-provider order.
    static func reconcile(saved: [TodayLayoutItem]?, platformIDs: [String], defaultOrder: [String]) -> [TodayLayoutItem] {
        let platforms = Set(platformIDs)
        let ordered = defaultOrder.filter { platforms.contains($0) } + platformIDs.filter { !defaultOrder.contains($0) }
        let defaults = defaultLayout(platformIDs: ordered)
        guard let saved else { return defaults }
        let valid = platforms.union(["spend", "running", "trend"])
        var seen = Set<String>()
        var result = saved.filter { valid.contains($0.id) && seen.insert($0.id).inserted }
        let newPlatforms = defaults.filter { platforms.contains($0.id) && !seen.contains($0.id) }
        let insertion = result.lastIndex { platforms.contains($0.id) }.map { $0 + 1 } ?? 0
        result.insert(contentsOf: newPlatforms, at: insertion)
        for (index, item) in defaults.enumerated() where !result.contains(where: { $0.id == item.id }) {
            // Insert before the next default sibling, otherwise after the last preceding sibling.
            let following = Set(defaults.dropFirst(index + 1).map(\.id))
            if let next = result.firstIndex(where: { following.contains($0.id) }) {
                result.insert(item, at: next)
            } else {
                let preceding = Set(defaults.prefix(index).map(\.id))
                let previous = result.lastIndex(where: { preceding.contains($0.id) }).map { $0 + 1 } ?? result.count
                result.insert(item, at: previous)
            }
        }
        // The existing trend chart has no narrow presentation in step one.
        return result.map { $0.id == "trend" && $0.size == .small ? .init(id: $0.id, size: .medium) : $0 }
    }
    static func place(_ items: [TodayLayoutItem], present: Set<String>) -> [Placement] {
        var occupied = Set<Int>(), seen = Set<String>()
        var bottom = 0
        var result: [Placement] = []
        for item in items where present.contains(item.id) && seen.insert(item.id).inserted {
            let row: Int, column: Int
            if item.size == .small {
                var slot = 0
                while occupied.contains(slot) { slot += 1 }
                row = slot / 2; column = slot % 2
            } else {
                row = bottom; column = 0
            }
            for r in row..<(row + item.size.rows) {
                for c in column..<(column + item.size.columns) { occupied.insert(r * 2 + c) }
            }
            bottom = max(bottom, row + item.size.rows)
            result.append(.init(id: item.id, size: item.size, row: row, column: column))
        }
        // Decide only after later S cards have had a chance to backfill holes.
        return result.map { placement in
            var placement = placement
            placement.stretched = placement.size == .small
                && !occupied.contains(placement.row * 2 + (1 - placement.column))
            return placement
        }
    }
    static func move(_ layout: [TodayLayoutItem], id: String, to index: Int) -> [TodayLayoutItem] {
        guard let source = layout.firstIndex(where: { $0.id == id }) else { return layout }
        var result = layout
        let item = result.remove(at: source)
        result.insert(item, at: max(0, min(index, result.count)))
        return result
    }
    static func moveToFront(_ layout: [TodayLayoutItem], id: String) -> [TodayLayoutItem] { move(layout, id: id, to: 0) }
    static func moveToEnd(_ layout: [TodayLayoutItem], id: String) -> [TodayLayoutItem] { move(layout, id: id, to: layout.count) }
    static func resize(_ layout: [TodayLayoutItem], id: String, to size: TodayCardSize) -> [TodayLayoutItem] {
        layout.map { $0.id == id ? .init(id: id, size: size) : $0 }
    }
    static func reset(platformIDs: [String]) -> [TodayLayoutItem] { defaultLayout(platformIDs: platformIDs) }
}
