import Foundation

enum ProviderID: Int, CaseIterable, Comparable {
    case codex
    case kimi

    // Kimi is intentionally disabled while its local installation is not in use.
    static let enabledCases: [ProviderID] = [.codex]

    static func < (lhs: ProviderID, rhs: ProviderID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ProviderHealth: Equatable {
    case ready
    case configured
    case warning
    case unavailable
}

struct StatusMetric {
    let label: String
    let value: String
    let remainingPercent: Double?
    let resetText: String?

    init(
        label: String,
        value: String,
        remainingPercent: Double? = nil,
        resetText: String? = nil
    ) {
        self.label = label
        self.value = value
        self.remainingPercent = remainingPercent
        self.resetText = resetText
    }
}

struct ProviderSnapshot {
    let id: ProviderID
    let name: String
    let detail: String
    let health: ProviderHealth
    let metrics: [StatusMetric]
    let footer: String?
    let dashboardURL: URL

    var minimumRemainingPercent: Double? {
        metrics.compactMap(\.remainingPercent).min()
    }
}

struct OverallSnapshot {
    let providers: [ProviderSnapshot]
    let refreshedAt: Date

    var minimumRemainingPercent: Double? {
        providers.compactMap(\.minimumRemainingPercent).min()
    }

    var hasUnavailableProvider: Bool {
        providers.contains { $0.health == .unavailable }
    }
}

enum StatusFormatting {
    private static let resetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let resetDateWithDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func percent(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    static func compactNumber(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000_000 {
            return compactDecimal(value / 1_000_000_000) + "B"
        }
        if magnitude >= 1_000_000 {
            return compactDecimal(value / 1_000_000) + "M"
        }
        if magnitude >= 1_000 {
            return compactDecimal(value / 1_000) + "K"
        }
        return String(Int(value.rounded()))
    }

    static func quotaWindow(minutes: Int) -> String {
        guard minutes > 0 else { return "window" }
        if minutes % 10_080 == 0 {
            return "\(minutes / 10_080 * 7)d"
        }
        if minutes % 1_440 == 0 {
            return "\(minutes / 1_440)d"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }

    static func resetText(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return "resets \(resetDateFormatter.string(from: date))"
        }
        if date.timeIntervalSince(now) < 7 * 86_400 {
            return "resets \(resetDateWithDayFormatter.string(from: date))"
        }
        return "resets " + resetDateWithDayFormatter.string(from: date)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 5 {
            return "just now"
        }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    static func titleCasePlan(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    private static func compactDecimal(_ value: Double) -> String {
        if abs(value) >= 100 || value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}
