import XCTest
@testable import Minutes

final class CalendarTimelineTests: XCTestCase {
    func testOverlappingEventsUseSeparateLanesAndReleaseThem() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func event(_ id: String, _ start: Double, _ end: Double) -> CalendarMeeting {
            CalendarMeeting(id: id, title: id, start: base.addingTimeInterval(start), end: base.addingTimeInterval(end), calendar: "Class", color: .blue, eventURL: nil)
        }
        let items = CalendarTimelineLayout.positions([event("later", 300, 400), event("b", 20, 150), event("a", 0, 100), event("c", 100, 200)])
        XCTAssertEqual(items.map(\.id), ["a", "b", "c", "later"])
        XCTAssertEqual(items.map(\.lane), [0, 1, 0, 0])
        XCTAssertEqual(items.map(\.lanes), [2, 2, 2, 1])
    }
    func testWeekUsesCalendarDaysAcrossDSTAndDayModeHasOneDay() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!; calendar.firstWeekday = 1
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let days = CalendarLayout.periodDays(date, week: true, calendar: calendar)
        XCTAssertEqual(days.count, 7); XCTAssertEqual(calendar.component(.weekday, from: days[0]), 1)
        XCTAssertEqual(days[1].timeIntervalSince(days[0]), 25 * 3600)
        XCTAssertEqual(CalendarLayout.periodDays(date, week: false, calendar: calendar), [date])
    }
}
