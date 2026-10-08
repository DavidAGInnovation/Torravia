import Foundation

/// Weekdays use Calendar's numbering (Sunday = 1). Overnight intervals belong
/// to the day on which they start; the end minute is exclusive.
nonisolated struct BandwidthSchedule: Codable, Equatable, Sendable {
    var enabled = false
    var weekdays: Set<Int> = Set(1...7)
    var startMinute = 22 * 60
    var endMinute = 8 * 60
    var downloadLimitMBps = 5
    var uploadLimitMBps = 1

    nonisolated func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let day = calendar.component(.weekday, from: date)
        let start = min(max(startMinute, 0), 1439)
        let end = min(max(endMinute, 0), 1439)
        if start == end { return weekdays.contains(day) }
        if start < end { return weekdays.contains(day) && minute >= start && minute < end }
        if minute >= start { return weekdays.contains(day) }
        let previousDay = day == 1 ? 7 : day - 1
        return minute < end && weekdays.contains(previousDay)
    }
}
