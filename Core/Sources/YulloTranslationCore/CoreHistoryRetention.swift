import Foundation

public enum CoreHistoryRetention: RawRepresentable, CaseIterable, Hashable, Sendable, Identifiable {
    case day, week, month, forever
    case custom(seconds: Int64)
    public static let allCases: [Self] = [.day, .week, .month, .forever]
    public static let maximumCustomSeconds: Int64 = 9_007_199_254_740_991
    public init?(rawValue: String) {
        switch rawValue {
        case "day": self = .day
        case "week": self = .week
        case "month": self = .month
        case "forever": self = .forever
        default:
            guard rawValue.hasPrefix("seconds:") else { return nil }
            let digits = rawValue.dropFirst(8)
            guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                let seconds = Int64(digits), seconds > 0, seconds <= Self.maximumCustomSeconds
            else { return nil }
            self = .custom(seconds: seconds)
        }
    }
    public var rawValue: String {
        switch self {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .forever: return "forever"
        case .custom(let seconds): return "seconds:\(seconds)"
        }
    }
    public var id: String { rawValue }
    public var seconds: TimeInterval? {
        switch self {
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        case .forever: return nil
        case .custom(let seconds): return Double(seconds)
        }
    }
    public var titleKey: String {
        switch self {
        case .day: return "1 day"
        case .week: return "7 days"
        case .month: return "30 days"
        case .forever: return "Forever"
        case .custom: return "Custom…"
        }
    }
}
