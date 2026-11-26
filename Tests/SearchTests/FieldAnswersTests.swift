import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FieldAnswersTests {
    private let english = Locale(identifier: "en_US")
    private let russian = Locale(identifier: "ru_RU")
    private let german = Locale(identifier: "de_DE")
    private let warsaw = TimeZone(identifier: "Europe/Warsaw")!

    private func day(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    private func answer(_ typed: String, _ locale: Locale? = nil, now: String = "2026-11-04T12:00:00Z",
                        zone: TimeZone? = nil) -> FieldAnswer? {
        FieldAnswers.answer(for: typed, locale: locale ?? english, now: day(now), zone: zone ?? warsaw).map { found in
            FieldAnswer(kind: found.kind, expression: found.expression,
                        answer: found.answer.replacingOccurrences(of: "\u{202F}", with: " "), copy: found.copy,
                        detail: found.detail)
        }
    }

    @Test func arithmeticTable() {
        let table: [(String, String)] = [
            ("2+2", "4"), ("2 + 3 * 4", "14"), ("(2 + 3) * 4", "20"), ("(3+4)/2", "3.5"), ("2^10", "1,024"),
            ("2 ** 3", "8"), ("2^3^2", "512"), ("-2^2", "-4"), ("(-2)^2", "4"), ("10 - 2 - 3", "5"),
            ("100 / 4 / 5", "5"), ("7 × 6", "42"), ("84 ÷ 2", "42"), ("3 x 4", "12"), ("3x4", "12"),
            ("0.1 + 0.2", "0.3"), ("1/3", "0.333333333333"), ("2/3", "0.666666666667"), ("1,000 + 1", "1,001"),
            ("1,000,000 * 3", "3,000,000"), (".5 * 4", "2"), ("sqrt(2)*pi", "4.44288293816"), ("sqrt 16", "4"),
            ("√9 + 1", "4"), ("2 * π", "6.28318530718"), ("12345679 * 9", "111,111,111"), ("1e3", ""),
            ("((((1+1))))*2", "4"), ("2+2=", "4"), ("what is 6*7", "42"), ("сколько будет 6*7", "42"),
            ("1−1", "0"), ("10 * 10^20", "1e21"), ("0.000001 * 2", "0.000002"),
        ]

        for (typed, want) in table {
            #expect((answer(typed)?.answer ?? "") == want, "\(typed)")
        }
    }

    @Test func percentTable() {
        let table: [(String, String)] = [
            ("20% of 80", "16"), ("20% от 80", "16"), ("80 + 15%", "92"), ("80 - 15%", "68"), ("15% off 80", "68"),
            ("50% * 80", "40"), ("200 * 10%", "20"), ("12.5% of 64", "8"), ("(20% of 80) + 4", "20"),
            ("100 + 10% + 10%", "121"), ("20%", ""), ("20 of 80", ""), ("5% + 5%", "10%"),
        ]

        for (typed, want) in table {
            #expect((answer(typed)?.answer ?? "") == want, "\(typed)")
        }
    }

    @Test func basesTable() {
        let table: [(String, String)] = [
            ("255 in hex", "0xFF"), ("0xff to dec", "255"), ("0xff in decimal", "255"), ("0b1010", "10"),
            ("0xff", "255"), ("0o17", "15"), ("10 to binary", "0b1010"), ("8 in octal", "0o10"),
            ("0xff + 1", "256"), ("0xff + 1 in hex", "0x100"), ("-255 in hex", "-0xFF"), ("65535 in hex", "0xFFFF"),
            ("255 в шестнадцатеричной", "0xFF"), ("10 в двоичной системе", "0b1010"), ("0xff в десятичной", "255"),
            ("1.5 in hex", ""), ("0x", ""), ("0xfg", ""), ("0b102", ""), ("1000000 in hex", "0xF4240"),
        ]

        for (typed, want) in table {
            #expect((answer(typed)?.answer ?? "") == want, "\(typed)")
        }
    }

    @Test func unitsTableInEnglish() {
        let table: [(String, String)] = [
            ("5 km in mi", "3.10686 mi"), ("5km to miles", "3.10686 mi"), ("1 mi in km", "1.60934 km"),
            ("100 f in c", "37.7778 °C"), ("72f in c", "22.2222 °C"), ("-40 c in f", "-40 °F"), ("0 c to k", "273.15 K"),
            ("100°f to c", "37.7778 °C"), ("1.5 gb in mb", "1,500 MB"), ("1 gib in mib", "1,024 MiB"),
            ("8 mbit in mb", "1 MB"), ("3 cups in ml", "709.765 mL"), ("1 gal to l", "3.78541 L"),
            ("60 mph in km/h", "96.5606 km/h"), ("10 m/s in km/h", "36 km/h"), ("90 min in hours", "1.5 h"),
            ("1.5 h in min", "90 min"), ("2 weeks in days", "14 days"), ("1 day in hours", "24 h"),
            ("10 in to cm", "25.4 cm"), ("5 ft in in", "60 in"), ("6 feet in m", "1.8288 m"), ("1 kg in lb", "2.20462 lb"),
            ("16 oz in g", "453.592 g"), ("1 acre in m2", "4,046.86 m²"), ("1 ha in acres", "2.47105 acres"),
            ("5 km", ""), ("5 km in kg", ""), ("5 apples in pears", ""), ("1000 m in km", "1 km"),
            ("1 year in days", "365.25 days"), ("1 sq mi in km2", "2.58999 km²"),
        ]

        for (typed, want) in table {
            #expect((answer(typed)?.answer ?? "") == want, "\(typed)")
        }
    }

    @Test func aCapitalLetterBeforeALowercaseBMeansBits() {
        let table: [(String, String)] = [
            ("100 Mb in MB", "12.5 MB"), ("1 Gb to MB", "125 MB"), ("8 Kb in B", "1,000 B"), ("100 MB in Mb", "800 Mbit"),
            ("1.5 GB in MB", "1,500 MB"), ("1.5 gb in mb", "1,500 MB"), ("100Mb in MB", "12.5 MB"),
        ]

        for (typed, want) in table {
            #expect((answer(typed)?.answer ?? "") == want, "\(typed)")
        }
    }

    @Test func unitsTableInRussian() {
        let table: [(String, String)] = [
            ("5 км в милях", "3,10686 мили"), ("5 км в мили", "3,10686 мили"), ("1 миля в км", "1,60934 км"),
            ("10 миль в километрах", "16,0934 км"), ("100 фаренгейт в цельсия", "37,7778 °C"),
            ("100 °F в °С", "37,7778 °C"), ("2 кг в фунтах", "4,40925 фунта"), ("1 фунт в граммах", "453,592 г"),
            ("3,5 кг в г", "3 500 г"), ("2 часа в минутах", "120 мин"), ("90 минут в часах", "1,5 ч"),
            ("3 недели в днях", "21 день"), ("2 дня в часах", "48 ч"), ("5 дней в неделях", "0,714286 недели"),
            ("1 гб в мб", "1 000 МБ"), ("60 миль в час в км/ч", "96,5606 км/ч"), ("10 литров в галлонах", "2,64172 галлона"),
            ("12 дюймов в см", "30,48 см"), ("1 метр в футах", "3,28084 фута"), ("5 футов в метрах", "1,524 м"),
            ("1 год в днях", "365,25 дня"), ("100 гектаров в км²", "1 км²"), ("1 миля в футах", "5 280 футов"),
        ]

        for (typed, want) in table {
            #expect((answer(typed, russian)?.answer.replacingOccurrences(of: "\u{00A0}", with: " ") ?? "") == want, "\(typed)")
        }
    }

    @Test func decimalSeparatorsFollowTheLocale() {
        let table: [(String, Locale, String)] = [
            ("1,5 + 1", russian, "2,5"), ("1,5 + 1", english, "2.5"), ("1,000 + 1", english, "1,001"),
            ("1,000 + 1", russian, "2"), ("1.5 + 1", russian, "2,5"), ("1.000 + 1", german, "1.001"),
            ("1,5 + 1", german, "2,5"), ("1.000,5 + 1", german, "1.001,5"), ("1,000.5 + 1", english, "1,001.5"),
            ("1\u{00A0}000 + 1", russian, "1\u{00A0}001"), ("1.2.3", english, ""), ("1,2,3", english, ""),
            ("3,5 km in m", russian, "3\u{00A0}500 m"), ("3.5 km in m", english, "3,500 m"),
        ]

        for (typed, locale, want) in table {
            #expect((answer(typed, locale)?.answer ?? "") == want, "\(typed) in \(locale.identifier)")
        }
    }

    @Test func ambiguousInputStaysASearch() {
        let table = [
            "255", "1.5", "3pm", "tokyo", "london to new york", "2+", "(2+3", "2+3)", "1/0", "5 % ", "10 / (5 - 5)",
            "2024-11-04", "11/04/2024", "04.11.2024", "555-123-4567", "+1 555 123 4567", "+48123456789",
            "example.com", "https://2+2.com", "www.2plus2.com", "1.2.3.4", "covid 19", "iphone 15 pro",
            "c++", "f(x) = 2x", "sqrt(-1)", "2^99999", "e", "x", "word 2+2", "2+2 words", "rgb(255, 0, 0)",
            "x 3", "3 x", "of 80", "20% of", "now", "time", "время", "15:00", "25:00 london", "13pm london",
            "3 london", "time in atlantis", "время в нигде", "1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1",
            String(repeating: "(", count: 40) + "1" + String(repeating: ")", count: 40),
        ]

        for typed in table {
            #expect(answer(typed) == nil, "\(typed)")
        }
    }

    @Test func timeZonesShowDateAndOffset() {
        let november = "2026-11-04T12:00:00Z"

        let warsawToNewYork = answer("15:00 warsaw to new york", now: november)
        let londonToSF = answer("3pm london in sf", now: november)
        let tokyo = answer("время в токио", russian, now: november)
        let utc = answer("now in utc", now: november)
        let msk = answer("15:00 msk to pst", now: november)

        #expect(warsawToNewYork?.answer == "9:00 AM")
        #expect(warsawToNewYork?.detail == "Wed, Nov 4 · New York · UTC−5")
        #expect(londonToSF?.answer == "7:00 AM")
        #expect(londonToSF?.detail == "Wed, Nov 4 · San Francisco · UTC−8")
        #expect(tokyo?.answer == "21:00")
        #expect(tokyo?.detail == "Ср, 4 нояб. · Токио · UTC+9")
        #expect(utc?.answer == "12:00 PM")
        #expect(utc?.detail == "Wed, Nov 4 · UTC · UTC")
        #expect(msk?.answer == "4:00 AM")
        #expect(msk?.detail == "Wed, Nov 4 · Pacific Time · UTC−8")
    }

    @Test func timeZonesFollowDaylightSaving() {
        let table: [(String, String, String, String)] = [
            ("15:00 warsaw to new york", "2026-01-15T12:00:00Z", "9:00 AM", "UTC−5"),
            ("15:00 warsaw to new york", "2026-07-15T12:00:00Z", "9:00 AM", "UTC−4"),
            ("15:00 warsaw to new york", "2026-03-15T12:00:00Z", "10:00 AM", "UTC−4"),
            ("15:00 warsaw to new york", "2026-11-04T12:00:00Z", "9:00 AM", "UTC−5"),
            ("15:00 warsaw to new york", "2026-10-28T12:00:00Z", "10:00 AM", "UTC−4"),
            ("9am london to tokyo", "2026-01-15T12:00:00Z", "6:00 PM", "UTC+9"),
            ("9am london to tokyo", "2026-07-15T12:00:00Z", "5:00 PM", "UTC+9"),
            ("12:00 tokyo to warsaw", "2026-07-15T02:00:00Z", "5:00 AM", "UTC+2"),
            ("12:00 tokyo to warsaw", "2026-01-15T02:00:00Z", "4:00 AM", "UTC+1"),
            ("10:00 new york to delhi", "2026-07-15T12:00:00Z", "7:30 PM", "UTC+5:30"),
            ("23:00 sf to tokyo", "2026-07-15T12:00:00Z", "3:00 PM", "UTC+9"),
        ]

        for (typed, now, clock, offset) in table {
            let found = answer(typed, now: now)
            #expect(found?.answer == clock, "\(typed) on \(now)")
            #expect(found?.detail.hasSuffix(offset) == true, "\(typed) on \(now): \(found?.detail ?? "nil")")
        }
    }

    @Test func timeZonesCrossTheDateLine() {
        let now = "2026-07-15T12:00:00Z"

        let late = answer("23:00 sf to tokyo", now: now)

        #expect(late?.detail == "Thu, Jul 16 · Tokyo · UTC+9")
    }

    @Test func timeZoneWordsInBothLanguages() {
        let now = "2026-11-04T12:00:00Z"
        let table: [(String, Locale, String)] = [
            ("time in tokyo", english, "9:00 PM"), ("tokyo time", english, "9:00 PM"),
            ("what time is it in london", english, "12:00 PM"), ("now in new york", english, "7:00 AM"),
            ("what is the time in tokyo", english, "9:00 PM"), ("what's the time in tokyo", english, "9:00 PM"),
            ("whats the time in tokyo", english, "9:00 PM"),
            ("время в токио", russian, "21:00"), ("время в москве", russian, "15:00"),
            ("который час в нью-йорке", russian, "07:00"), ("сейчас в лондоне", russian, "12:00"),
            ("15:00 по москве в варшаве", russian, "13:00"), ("15:00 москва в лондон", russian, "12:00"),
            ("полдень в токио", russian, "20:00"), ("noon tokyo to london", english, "3:00 AM"),
            ("3:30pm london", english, "4:30 PM"), ("3 pm london in nyc", english, "10:00 AM"),
            ("12am utc to warsaw", english, "1:00 AM"), ("время в киеве", russian, "14:00"),
            ("время в сан-франциско", russian, "04:00"), ("15:00 utc → msk", english, "6:00 PM"),
        ]

        for (typed, locale, clock) in table {
            #expect(answer(typed, locale, now: now)?.answer == clock, "\(typed)")
        }
    }

    @Test func everyNamedZoneResolves() {
        let names = FieldTimes.russian.map(\.stem) + ["sf", "nyc", "la", "utc", "gmt", "msk", "pst", "est", "cet", "jst",
                                                       "kiev", "kyiv", "mumbai", "beijing", "hong kong", "aest"]

        for name in names {
            #expect(FieldTimes.zone(named: name) != nil, "\(name)")
        }
    }

    @Test func copiesTheAnswerWithoutGroupingAndTheFullLineWithTheExpression() {
        let big = answer("1000 * 1000")
        let unit = answer("1.5 gb in mb")

        #expect(big?.answer == "1,000,000")
        #expect(big?.copy == "1000000")
        #expect(big?.full == "1000 * 1000 = 1000000")
        #expect(unit?.copy == "1500 MB")
        #expect(answer("  20%   of 80 ")?.expression == "20% of 80")
    }
}
