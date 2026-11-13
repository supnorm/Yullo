import Foundation

public enum CoreHistoryTask: String, CaseIterable, Sendable {
    case translation, dictation, writing

    public var titleKey: String {
        switch self {
        case .translation: return "Translation"
        case .dictation: return "Dictation"
        case .writing: return "Writing"
        }
    }
}

// SQL uses a half-open range so adjacent calendar days never overlap.
public struct CoreHistoryDateRange: Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init?(start: Date, end: Date) {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, start < end else {
            return nil
        }
        self.start = start
        self.end = end
    }

    public static func days(from first: Date, through last: Date, calendar: Calendar) -> Self? {
        let start = calendar.startOfDay(for: first)
        let lastDay = calendar.startOfDay(for: last)
        guard start <= lastDay, let end = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return nil }
        return Self(start: start, end: end)
    }

    public static func recentDays(_ count: Int, including date: Date, calendar: Calendar) -> Self? {
        guard count > 0,
            let first = calendar.date(byAdding: .day, value: 1 - count, to: calendar.startOfDay(for: date))
        else { return nil }
        return days(from: first, through: date, calendar: calendar)
    }
}

public struct CoreHistoryFilter: Equatable, Sendable {
    public var task: CoreHistoryTask?
    public var dateRange: CoreHistoryDateRange?

    public init(task: CoreHistoryTask? = nil, dateRange: CoreHistoryDateRange? = nil) {
        self.task = task
        self.dateRange = dateRange
    }
}
