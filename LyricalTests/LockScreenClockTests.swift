//
//  LockScreenClockTests.swift
//  LyricalTests
//
//  The lock-screen clock stands in for the system's, so it should read the same.
//

import XCTest
@testable import Lyrical

final class LockScreenClockTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: hour, minute: minute))!
    }

    func testTwelveHourHasNoLeadingZero() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(LockScreenClockView.time(date(18, 21), calendar: calendar, locale: us), "6:21")
        XCTAssertEqual(LockScreenClockView.time(date(6, 5), calendar: calendar, locale: us), "6:05")
    }

    func testTwelveHourMidnightAndNoonAreTwelve() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(LockScreenClockView.time(date(0, 0), calendar: calendar, locale: us), "12:00")
        XCTAssertEqual(LockScreenClockView.time(date(12, 30), calendar: calendar, locale: us), "12:30")
    }

    func testTwentyFourHourLocale() {
        let de = Locale(identifier: "de_DE")
        XCTAssertEqual(LockScreenClockView.time(date(18, 21), calendar: calendar, locale: de), "18:21")
        XCTAssertEqual(LockScreenClockView.time(date(0, 7), calendar: calendar, locale: de), "0:07")
    }
}
