import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FieldAnswerDatesTests {
    private let english = Locale(identifier: "en_US")
    private let russian = Locale(identifier: "ru_RU")
    private let warsaw = TimeZone(identifier: "Europe/Warsaw")!

    private func answer(_ text: String, locale: Locale? = nil, now: String = "2026-11-04T12:00:00Z",
                        zone: TimeZone? = nil) -> FieldAnswer? {
        FieldAnswers.answer(for: text, locale: locale ?? english,
                            now: ISO8601DateFormatter().date(from: now)!, zone: zone ?? warsaw)
    }

    @Test func countdownsInEnglish() {
        let table = [
            ("days until christmas", "51 days"), ("days until 2026-12-31", "57 days"),
            ("how many days until new year", "58 days"), ("days till christmas day", "51 days"),
            ("days until new year's day", "58 days"), ("days until tomorrow", "1 day"),
            ("days until today", "0 days"), ("days until yesterday", "-1 day"),
            ("days until December 31, 2026", "57 days"), ("days until 31 Dec 2026", "57 days"),
            ("days until 2026-11-03", "-1 day"),
        ]

        for (text, expected) in table {
            let found = answer(text)
            #expect(found?.kind == .date, "\(text)")
            #expect(found?.answer == expected, "\(text)")
            #expect(found?.copy == expected, "\(text)")
            #expect(!(found?.detail.isEmpty ?? true), "\(text)")
        }
    }

    @Test func countdownsInRussianAndTheirPlurals() {
        let table = [
            ("сколько дней до нового года", "58 дней"), ("сколько дней до рождества", "64 дня"),
            ("дней до завтра", "1 день"), ("сколько дней до сегодня", "0 дней"),
            ("сколько дней до 2026-11-05", "1 день"), ("сколько дней до 2026-11-06", "2 дня"),
            ("сколько дней до 2026-11-09", "5 дней"), ("сколько дней до 2026-11-15", "11 дней"),
            ("сколько дней до 2026-11-25", "21 день"), ("сколько дней до 2026-11-26", "22 дня"),
            ("сколько дней до 31.12.2026", "57 дней"), ("сколько дней до 31 декабря 2026", "57 дней"),
            ("сколько дней до вчера", "-1 день"),
        ]

        for (text, expected) in table {
            #expect(answer(text, locale: russian)?.answer == expected, "\(text)")
        }
    }

    @Test func relativeDatesInEnglishAndRussian() {
        let table: [(String, Locale, String)] = [
            ("2 weeks from today", english, "2026-11-18"), ("in 10 days", english, "2026-11-14"),
            ("1 day from now", english, "2026-11-05"), ("0 days from today", english, "2026-11-04"),
            ("1 month from today", english, "2026-12-04"), ("1 year from today", english, "2027-11-04"),
            ("2 weeks ago", english, "2026-10-21"), ("1 month ago", english, "2026-10-04"),
            ("через 10 дней", russian, "2026-11-14"), ("через 1 день", russian, "2026-11-05"),
            ("через 2 дня", russian, "2026-11-06"), ("через неделю", russian, ""),
            ("через 1 неделю", russian, "2026-11-11"), ("через 2 недели", russian, "2026-11-18"),
            ("через 5 недель", russian, "2026-12-09"), ("через 1 месяц", russian, "2026-12-04"),
            ("через 2 месяца", russian, "2027-01-04"), ("через 1 год", russian, "2027-11-04"),
            ("через 2 года", russian, "2028-11-04"), ("через 5 лет", russian, "2031-11-04"),
            ("10 дней назад", russian, "2026-10-25"), ("2 недели назад", russian, "2026-10-21"),
        ]

        for (text, locale, expected) in table {
            let found = answer(text, locale: locale)
            #expect((found?.copy ?? "") == expected, "\(text)")
            if !expected.isEmpty { #expect(found?.kind == .date, "\(text)") }
        }
    }

    @Test func weekdaysInBothLanguages() {
        let table: [(String, Locale, String)] = [
            ("weekday of 2026-12-31", english, "Thursday"),
            ("what day of the week is December 31, 2026", english, "Thursday"),
            ("what day is 2024-02-29", english, "Thursday"),
            ("day of week for today", english, "Wednesday"),
            ("weekday on tomorrow", english, "Thursday"),
            ("какой день недели 31.12.2026", russian, "четверг"),
            ("день недели 31 декабря 2026", russian, "четверг"),
            ("какой день недели будет завтра", russian, "четверг"),
            ("какой день недели сегодня", russian, "среда"),
        ]

        for (text, locale, expected) in table {
            let found = answer(text, locale: locale)
            #expect(found?.answer == expected, "\(text)")
            #expect(found?.copy == expected, "\(text)")
            #expect(found?.kind == .date, "\(text)")
        }
    }

    @Test func holidaysIncludeTodayAndRollForwardAfterward() {
        let table = [
            ("days until christmas", "2026-12-25T12:00:00Z", "0 days"),
            ("days until christmas", "2026-12-26T12:00:00Z", "364 days"),
            ("days until new year", "2027-01-01T12:00:00Z", "0 days"),
            ("days until new year", "2027-01-02T12:00:00Z", "364 days"),
            ("сколько дней до рождества", "2027-01-07T12:00:00Z", "0 дней"),
            ("сколько дней до рождества", "2027-01-08T12:00:00Z", "364 дня"),
        ]

        for (text, now, expected) in table {
            #expect(answer(text, now: now)?.answer == expected, "\(text) on \(now)")
        }
    }

    @Test func calendarOffsetsClampMonthEndsAndLeapYears() {
        let table = [
            ("1 month from today", "2026-01-31T12:00:00Z", "2026-02-28"),
            ("1 month from today", "2024-01-31T12:00:00Z", "2024-02-29"),
            ("1 year from today", "2024-02-29T12:00:00Z", "2025-02-28"),
            ("1 month ago", "2026-03-31T12:00:00Z", "2026-02-28"),
            ("1 day from today", "2026-12-31T12:00:00Z", "2027-01-01"),
        ]

        for (text, now, expected) in table {
            #expect(answer(text, now: now)?.copy == expected, "\(text) on \(now)")
        }
    }

    @Test func dayMathUsesCalendarDaysAcrossDaylightSaving() {
        let table = [
            ("2026-03-28T23:30:00Z", "2026-03-30"),
            ("2026-10-24T22:30:00Z", "2026-10-26"),
        ]

        for (now, target) in table {
            #expect(answer("1 day from today", now: now)?.copy == target, "\(now)")
            #expect(answer("days until \(target)", now: now)?.answer == "1 day", "\(now)")
        }
    }

    @Test func todayUsesTheSuppliedLocalZone() {
        let now = "2026-11-04T00:30:00Z"
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!

        let west = answer("days until 2026-11-04", now: now, zone: losAngeles)
        let east = answer("days until 2026-11-04", now: now, zone: tokyo)

        #expect(west?.answer == "1 day")
        #expect(east?.answer == "0 days")
        #expect(answer("0 days from today", now: now, zone: losAngeles)?.copy == "2026-11-03")
    }

    @Test func displayAndCopyRetainAnUnambiguousDateAndQuestion() {
        let text = "  2 weeks   from today? "

        let found = answer(text)
        let countdown = answer("days until 2026-12-31")
        let russianDate = answer("через 10 дней", locale: english)

        #expect(found?.answer == "Nov 18, 2026")
        #expect(found?.copy == "2026-11-18")
        #expect(found?.detail == "Wednesday")
        #expect(found?.expression == "2 weeks from today?")
        #expect(found?.full == "2 weeks from today? = 2026-11-18")
        #expect(countdown?.detail == "Dec 31, 2026")
        #expect(russianDate?.answer.contains("нояб") == true)
        #expect(russianDate?.detail == "суббота")
    }

    @Test func invalidAmbiguousAndUnfinishedDatesRemainSearches() {
        let table = [
            "2026-12-31", "31.12.2026", "12/31/2026", "christmas", "новый год", "today", "tomorrow",
            "days until", "days until atlantis", "days until christmas presents", "days until 2026-02-29",
            "days until 2026-04-31", "days until 2026-13-01", "days until 2026-00-01", "days until 2026-01-00",
            "days until 0000-01-01", "days until 10000-01-01", "days until 11/04/2026",
            "weekday of 29 февраля 2026", "weekday of 31 november 2026", "weekday of 2026-12-31 trailing",
            "2 weeks from", "2.5 days from today", "-2 days from today", "через -10 дней", "через 1,5 дня",
            "in 2 hours", "через 10 секунд", "in 10001 days", "in 10000 years", "10000 years ago",
            "in 999999999999999999999999999999 days", "in ٢ days", "через 10 дней купить подарок",
            "https://example.com/days until 2026-12-31", "www.days until christmas", "weekday of",
        ]

        for text in table { #expect(answer(text) == nil, "\(text)") }
    }

    @Test func dateParsingPreservesExistingAnswerKinds() {
        let table: [(String, FieldAnswer.Kind)] = [
            ("2+2", .sum), ("255 in hex", .base), ("2 weeks in days", .unit), ("time in tokyo", .time),
        ]

        for (text, kind) in table { #expect(answer(text)?.kind == kind, "\(text)") }
    }
}
