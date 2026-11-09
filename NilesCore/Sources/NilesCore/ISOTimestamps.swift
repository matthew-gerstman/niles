import Foundation

/// ISO-8601 timestamps shared by argument parsing, proposal cards, and
/// evidence. `Date.ISO8601FormatStyle` is Sendable, so one shared instance
/// is safe under Swift 6 strict concurrency.
enum ISOTimestamps {
    private static let style = Date.ISO8601FormatStyle()

    static func parse(_ string: String) -> Date? {
        try? style.parse(string)
    }

    static func render(_ date: Date) -> String {
        date.formatted(style)
    }
}
