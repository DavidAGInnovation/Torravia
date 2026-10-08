@testable import TorraviaSearchCore
import Foundation
import Testing
@testable import Torravia

@MainActor
struct BandwidthScheduleTests {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func daytimeBoundariesAndDisabledDays() {
        let schedule = BandwidthSchedule(enabled: true, weekdays: [2], startMinute: 540, endMinute: 1020)
        #expect(!schedule.isActive(at: date(5, 8, 59), calendar: calendar))
        #expect(schedule.isActive(at: date(5, 9), calendar: calendar))
        #expect(schedule.isActive(at: date(5, 16, 59), calendar: calendar))
        #expect(!schedule.isActive(at: date(5, 17), calendar: calendar))
        #expect(!schedule.isActive(at: date(6, 10), calendar: calendar))
    }

    @Test func overnightUsesStartingDayIncludingSaturdayToSunday() {
        let schedule = BandwidthSchedule(enabled: true, weekdays: [7], startMinute: 1320, endMinute: 480)
        #expect(!schedule.isActive(at: date(10, 7), calendar: calendar))
        #expect(schedule.isActive(at: date(10, 22), calendar: calendar))
        #expect(schedule.isActive(at: date(11, 0), calendar: calendar))
        #expect(schedule.isActive(at: date(11, 7, 59), calendar: calendar))
        #expect(!schedule.isActive(at: date(11, 8), calendar: calendar))
        #expect(!schedule.isActive(at: date(11, 23), calendar: calendar))
    }

    @Test func equalTimesAllDayAndEmptySelection() {
        var schedule = BandwidthSchedule(enabled: true, weekdays: [2], startMinute: 600, endMinute: 600)
        #expect(schedule.isActive(at: date(5, 0), calendar: calendar))
        #expect(schedule.isActive(at: date(5, 23, 59), calendar: calendar))
        #expect(!schedule.isActive(at: date(6, 0), calendar: calendar))
        schedule.weekdays = []
        #expect(!schedule.isActive(at: date(5, 12), calendar: calendar))
        schedule.weekdays = [2]; schedule.enabled = false
        #expect(!schedule.isActive(at: date(5, 12), calendar: calendar))
    }

    @Test func persistsScheduleAndRestoresNormalLimitsOutsideInterval() throws {
        let suite = "TorraviaTests.schedule.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SeedingPreferencesStore(userDefaults: defaults)
        store.downloadLimitMBps = 12; store.uploadLimitMBps = 3
        store.bandwidthSchedule = BandwidthSchedule(enabled: true, weekdays: [2], startMinute: 540,
                                                   endMinute: 1020, downloadLimitMBps: 2, uploadLimitMBps: 0)
        let restored = SeedingPreferencesStore(userDefaults: defaults)
        #expect(restored.bandwidthSchedule == store.bandwidthSchedule)
        let active = restored.networkConfiguration(at: date(5, 12), calendar: calendar)
        #expect(active.downloadLimitBytesPerSecond == 2_000_000)
        #expect(active.uploadLimitBytesPerSecond == 0)
        let normal = restored.networkConfiguration(at: date(5, 17), calendar: calendar)
        #expect(normal.downloadLimitBytesPerSecond == 12_000_000)
        #expect(normal.uploadLimitBytesPerSecond == 3_000_000)
        #expect(!restored.remoteControlAllowsLAN)
        #expect(restored.remoteControlPort == 8555)
    }
}
