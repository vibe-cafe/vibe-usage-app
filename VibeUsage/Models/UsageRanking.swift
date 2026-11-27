struct UsageRanking {
    static let empty = UsageRanking(values: [:])
    enum Dimension { case model, terminal, tool }
    enum RankColor { case blue, teal, magenta, gray }

    struct Row {
        let name: String
        let value: Double
        let share: Double
        let color: RankColor
    }

    private let rows: [Row]
    var top: ArraySlice<Row> { rows.prefix(3) }
    var remainder: ArraySlice<Row> { rows.dropFirst(3) }
    let total: Double
    let remainderValue: Double

    /// The rows a card lists: the top three, and the fourth too when it is
    /// the only one left — 「其余 1 个」 would hide a single row behind a click.
    var listed: ArraySlice<Row> { rows.count == 4 ? rows[...] : top }
    /// What 「其余 N 个」 holds: two rows or more, otherwise nothing.
    var collapsed: ArraySlice<Row> { rows.count == 4 ? [] : remainder }

    /// Ranked by value, largest first (ties by name).
    init(values: [String: Double]) {
        let sorted = values.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        self.init(ordered: sorted.map { (name: $0.key, value: $0.value) })
    }

    /// Rows in the given order, colored by position (Token 构成's fixed
    /// 缓存, 输入, 输出).
    init(ordered entries: [(name: String, value: Double)]) {
        let colors: [RankColor] = [.blue, .teal, .magenta]
        let sum = entries.reduce(0) { $0 + $1.value }
        total = sum
        rows = entries.enumerated().map { index, item in
            Row(name: item.name, value: item.value, share: sum == 0 ? 0 : item.value / sum,
                color: index < colors.count ? colors[index] : .gray)
        }
        remainderValue = rows.dropFirst(3).reduce(0) { $0 + $1.value }
    }
}
