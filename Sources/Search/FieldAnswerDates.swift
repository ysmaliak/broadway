import Foundation

enum FieldDates {
    private static let countdowns = [
        "how many days until ", "how many days till ", "days until ", "days till ", "сколько дней до ", "дней до ",
    ]
    private static let weekdays = [
        "what day of the week is ", "what day of week is ", "what weekday is ", "what day is ",
        "day of week for ", "day of week of ", "weekday of ", "weekday on ",
        "какой день недели будет ", "какой день недели ", "день недели ",
    ]
    private static let units: [String: Calendar.Component] = [
        "day": .day, "days": .day, "день": .day, "дня": .day, "дней": .day,
        "week": .weekOfYear, "weeks": .weekOfYear, "неделю": .weekOfYear,
        "неделя": .weekOfYear, "недели": .weekOfYear, "недель": .weekOfYear,
        "month": .month, "months": .month, "месяц": .month, "месяца": .month, "месяцев": .month,
        "year": .year, "years": .year, "год": .year, "года": .year, "лет": .year,
    ]
    private static let months: [String: Int] = {
        let names = [
            ["january", "jan", "январь", "января"], ["february", "feb", "февраль", "февраля"],
            ["march", "mar", "март", "марта"], ["april", "apr", "апрель", "апреля"],
            ["may", "май", "мая"], ["june", "jun", "июнь", "июня"], ["july", "jul", "июль", "июля"],
            ["august", "aug", "август", "августа"], ["september", "sep", "sept", "сентябрь", "сентября"],
            ["october", "oct", "октябрь", "октября"], ["november", "nov", "ноябрь", "ноября"],
            ["december", "dec", "декабрь", "декабря"],
        ]
        var found: [String: Int] = [:]
        for (index, aliases) in names.enumerated() {
            for alias in aliases { found[alias] = index + 1 }
        }
        return found
    }()

    static func answer(_ text: String, expression: String, context: AnswerContext) -> FieldAnswer? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.zone
        let today = calendar.startOfDay(for: context.now)
        for prefix in countdowns where text.hasPrefix(prefix) {
            guard let target = date(String(text.dropFirst(prefix.count)), today: today, calendar: calendar),
                  let days = calendar.dateComponents([.day], from: today, to: target).day,
                  let shown = AnswerNumbers(locale: context.locale).string(Double(days), grouped: true),
                  let copy = AnswerNumbers(locale: context.locale).string(Double(days), grouped: false)
            else { return nil }
            let unit = context.russian ? AnswerUnit.plural(Double(days), ["день", "дня", "дней"]) : days.magnitude == 1 ? "day" : "days"
            return FieldAnswer(kind: .date, expression: expression, answer: shown + " " + unit,
                               copy: copy + " " + unit, detail: formatted(target, template: "yMMMd", context: context))
        }
        for prefix in weekdays where text.hasPrefix(prefix) {
            guard let target = date(String(text.dropFirst(prefix.count)), today: today, calendar: calendar) else { return nil }
            let weekday = formatted(target, template: "EEEE", context: context)
            return FieldAnswer(kind: .date, expression: expression, answer: weekday, copy: weekday,
                               detail: formatted(target, template: "yMMMd", context: context))
        }
        guard let offset = offset(text),
              let target = calendar.date(byAdding: offset.component, value: offset.value, to: today),
              calendar.component(.era, from: target) == 1,
              (1...9999).contains(calendar.component(.year, from: target))
        else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: target)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return FieldAnswer(kind: .date, expression: expression, answer: formatted(target, template: "yMMMd", context: context),
                           copy: String(format: "%04d-%02d-%02d", year, month, day),
                           detail: formatted(target, template: "EEEE", context: context))
    }

    private static func offset(_ text: String) -> (component: Calendar.Component, value: Int)? {
        let patterns: [(String, Int)] = [
            (#"^([0-9]+) ([a-z]+) (?:from today|from now)$"#, 1),
            (#"^in ([0-9]+) ([a-z]+)$"#, 1),
            (#"^([0-9]+) ([a-z]+) ago$"#, -1),
            (#"^через ([0-9]+) ([а-яё]+)$"#, 1),
            (#"^([0-9]+) ([а-яё]+) назад$"#, -1),
        ]
        for (pattern, sign) in patterns {
            guard let parts = captures(pattern, in: text), let amount = Int(parts[0]), amount <= 10_000,
                  let component = units[parts[1]] else { continue }
            return (component, amount * sign)
        }
        return nil
    }

    private static func date(_ text: String, today: Date, calendar: Calendar) -> Date? {
        switch text {
        case "today", "сегодня": return today
        case "tomorrow", "завтра": return calendar.date(byAdding: .day, value: 1, to: today)
        case "yesterday", "вчера": return calendar.date(byAdding: .day, value: -1, to: today)
        default: break
        }
        let holiday: (month: Int, day: Int)?
        switch text {
        case "christmas", "christmas day", "xmas": holiday = (12, 25)
        case "рождество", "рождества": holiday = (1, 7)
        case "new year", "new year's day", "new years day", "новый год", "нового года": holiday = (1, 1)
        default: holiday = nil
        }
        if let holiday {
            let year = calendar.component(.year, from: today)
            guard let target = exact(year: year, month: holiday.month, day: holiday.day, calendar: calendar) else { return nil }
            return target < today ? exact(year: year + 1, month: holiday.month, day: holiday.day, calendar: calendar) : target
        }
        if let parts = captures(#"^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})$"#, in: text),
           let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) {
            return exact(year: year, month: month, day: day, calendar: calendar)
        }
        if let parts = captures(#"^([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4})$"#, in: text),
           let day = Int(parts[0]), let month = Int(parts[1]), let year = Int(parts[2]) {
            return exact(year: year, month: month, day: day, calendar: calendar)
        }
        if let parts = captures(#"^([0-9]{1,2}) ([a-zа-яё]+) ([0-9]{4})$"#, in: text),
           let day = Int(parts[0]), let month = months[parts[1]], let year = Int(parts[2]) {
            return exact(year: year, month: month, day: day, calendar: calendar)
        }
        if let parts = captures(#"^([a-z]+) ([0-9]{1,2}),? ([0-9]{4})$"#, in: text),
           let month = months[parts[0]], let day = Int(parts[1]), let year = Int(parts[2]) {
            return exact(year: year, month: month, day: day, calendar: calendar)
        }
        return nil
    }

    private static func exact(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let found = calendar.date(from: DateComponents(era: 1, year: year, month: month, day: day))
        else { return nil }
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: found)
        guard parts.era == 1, parts.year == year, parts.month == month, parts.day == day else { return nil }
        return calendar.startOfDay(for: found)
    }

    private static func formatted(_ date: Date, template: String, context: AnswerContext) -> String {
        let locale = context.wordsLocale, zone = context.zone
        let formatter = AnswerFormatters.formatter(.init("day", locale: locale, zone: zone, template: template)) {
            let made = DateFormatter()
            made.locale = locale
            made.calendar = Calendar(identifier: .gregorian)
            made.timeZone = zone
            made.setLocalizedDateFormatFromTemplate(template)
            return made
        }
        return formatter.string(from: date)
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range == NSRange(text.startIndex..., in: text)
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
