//
//  LockScreenClockView.swift
//  Lyrical
//
//  On the lock screen the backdrop covers the system's date and time, so we
//  draw our own in the same spot: date over a large time, top-centre.
//

import SwiftUI

struct LockScreenClockView: View {
    let screenSize: CGSize
    let design: Font.Design

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 0) {
                Text(context.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.system(size: screenSize.height * 0.028, weight: .semibold, design: design))
                    .opacity(0.8)
                Text(Self.time(context.date))
                    .font(.system(size: screenSize.height * 0.12, weight: .semibold, design: design))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            .padding(.top, screenSize.height * 0.075)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
    }

    /// "6:21", or "18:21" on a 24-hour Mac, the way the system lock screen
    /// shows it. FormatStyle zero-pads a 12-hour hour once AM/PM is omitted.
    static func time(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "h"
        let is24Hour = pattern.contains("H") || pattern.contains("k")
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour24 = parts.hour ?? 0
        let hour = is24Hour ? hour24 : (hour24 % 12 == 0 ? 12 : hour24 % 12)
        return String(format: "%d:%02d", hour, parts.minute ?? 0)
    }
}
