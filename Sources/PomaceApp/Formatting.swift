import Foundation

/// Locale-aware display values. Count-bearing prose uses catalog plural variations.
enum Fmt {
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: count)
    }

    static func hour(_ hour: Int) -> String {
        if hour == 0 { return AppStrings.midnight }
        if hour == 12 { return AppStrings.noon }
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: hour))!
        return date.formatted(Date.FormatStyle().hour(.defaultDigits(amPM: .abbreviated)))
    }
}
