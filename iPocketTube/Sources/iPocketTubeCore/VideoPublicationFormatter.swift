import Foundation

public enum VideoPublicationFormatter {
    public static func string(
        for video: Video,
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        guard let date = video.publishedAt else {
            if let raw = video.publishedTimeText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                if let components = relativeComponents(from: raw) {
                    let formatter = RelativeDateTimeFormatter()
                    formatter.locale = locale
                    formatter.unitsStyle = .full
                    return formatter.localizedString(from: components)
                }
                // A localized/changed YouTube label is still more truthful than
                // "unknown". Never derive an invented absolute day from it.
                return raw
            }
            return locale.language.languageCode?.identifier == "ru"
                ? "Дата неизвестна"
                : "Publication date unknown"
        }

        if calendar.isDate(date, inSameDayAs: now) {
            return locale.language.languageCode?.identifier == "ru" ? "сегодня" : "today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return locale.language.languageCode?.identifier == "ru" ? "вчера" : "yesterday"
        }

        let elapsed = max(0, now.timeIntervalSince(date))
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full

        if elapsed < 31 * 86_400 {
            let days = max(2, Int(elapsed / 86_400))
            return formatter.localizedString(from: DateComponents(day: -days))
        }

        // InnerTube relative metadata is approximate by design. Keep that honesty
        // for month/year labels instead of presenting an invented exact day.
        if let raw = video.publishedTimeText, !raw.isEmpty {
            let components = calendar.dateComponents([.year, .month], from: date, to: now)
            if let years = components.year, years > 0 {
                return formatter.localizedString(from: DateComponents(year: -years))
            }
            let months = max(1, components.month ?? 1)
            return formatter.localizedString(from: DateComponents(month: -months))
        }

        let exact = DateFormatter()
        exact.locale = locale
        exact.dateStyle = .medium
        exact.timeStyle = .none
        return exact.string(from: date)
    }

    private static func relativeComponents(from text: String) -> DateComponents? {
        let stripped = text
            .replacingOccurrences(
                of: #"^(Streamed|Premiered|Started)\s+"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .lowercased()
        let pattern = #"(\d+)\s+(second|minute|hour|day|week|month|year)s?\s+ago"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: stripped,
                range: NSRange(stripped.startIndex..., in: stripped)
              ),
              let valueRange = Range(match.range(at: 1), in: stripped),
              let unitRange = Range(match.range(at: 2), in: stripped),
              let value = Int(stripped[valueRange])
        else { return nil }

        let negative = -value
        switch String(stripped[unitRange]) {
        case "second": return DateComponents(second: negative)
        case "minute": return DateComponents(minute: negative)
        case "hour": return DateComponents(hour: negative)
        case "day": return DateComponents(day: negative)
        case "week": return DateComponents(day: negative * 7)
        case "month": return DateComponents(month: negative)
        case "year": return DateComponents(year: negative)
        default: return nil
        }
    }
}
