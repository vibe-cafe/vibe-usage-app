import Foundation

enum Formatters {
    /// Format large numbers with compact notation: 1234 → "1,234", 45200 → "45.2K"
    static func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 {
            let value = Double(n) / 1_000_000.0
            return String(format: "%.1fM", value)
        }
        if n >= 10_000 {
            let value = Double(n) / 1_000.0
            return String(format: "%.1fK", value)
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Format cost: $0.00, $12.34, or $0.0012 for very small values
    static func formatCost(_ cost: Double) -> String {
        if cost == 0 { return "$0.00" }
        if cost < 0.01 { return String(format: "$%.4f", cost) }
        return String(format: "$%.2f", cost)
    }

    /// Format date for chart axis: "2/25"
    static func formatDateShort(_ dateString: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        // Try full ISO first, then just date
        if let date = isoFormatter.date(from: dateString) ?? dateFromDayKey(dateString) {
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d"
            return formatter.string(from: date)
        }
        // Fallback: extract from yyyy-MM-dd
        let parts = dateString.split(separator: "-")
        if parts.count >= 3 {
            let month = Int(parts[1]) ?? 0
            let day = Int(parts[2]) ?? 0
            return "\(month)/\(day)"
        }
        return dateString
    }

    /// Format relative time: "刚刚", "3 分钟前", "1 小时前"
    static func formatRelativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
        return "\(Int(interval / 86400)) 天前"
    }

    /// Format hour key for chart axis: "yyyy-MM-ddTHH" (UTC) → local "15:00"
    static func formatHourShort(_ hourKey: String) -> String {
        // hourKey is UTC like "2026-02-27T14"
        let utcFormatter = DateFormatter()
        utcFormatter.dateFormat = "yyyy-MM-dd'T'HH"
        utcFormatter.timeZone = TimeZone(identifier: "UTC")
        if let date = utcFormatter.date(from: hourKey) {
            let localFormatter = DateFormatter()
            localFormatter.dateFormat = "HH:mm"
            return localFormatter.string(from: date)
        }
        return hourKey
    }

    /// Format duration in seconds: 90 → "1m", 3661 → "1h 1m", 86400+ → "1d 2h"
    static func formatDuration(_ seconds: Int) -> String {
        if seconds <= 0 { return "0m" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(minutes, 1))m"
    }

    /// Parse "yyyy-MM-dd" to Date
    static func dateFromDayKey(_ key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }

    /// Format the gap between now and a future date: "12m", "2h 14m", "4d 18h", "已重置"
    static func formatTimeUntil(_ date: Date) -> String {
        let interval = Int(date.timeIntervalSinceNow)
        if interval <= 0 { return "已重置" }
        return formatDuration(interval)
    }
}
