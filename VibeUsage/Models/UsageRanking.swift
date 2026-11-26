struct UsageRanking {
    static let empty = UsageRanking(values: [:])
    enum Dimension { case model, terminal, tool }
    enum RankColor { case blue, teal, magenta, gray }

    struct Row {
        let name: String
        let value: Double
        let color: RankColor
    }

    private let rows: [Row]
    var top: ArraySlice<Row> { rows.prefix(3) }
    var remainder: ArraySlice<Row> { rows.dropFirst(3) }
    let total: Double
    let remainderValue: Double

    init(values: [String: Double]) {
        let sorted = values.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        let colors: [RankColor] = [.blue, .teal, .magenta]
        rows = sorted.enumerated().map { index, item in
            Row(name: item.key, value: item.value, color: index < colors.count ? colors[index] : .gray)
        }
        remainderValue = rows.dropFirst(3).reduce(0) { $0 + $1.value }
        total = rows.prefix(3).reduce(remainderValue) { $0 + $1.value }
    }
}
