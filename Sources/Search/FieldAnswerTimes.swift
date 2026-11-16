import Foundation

struct AnswerZone: Equatable {
    let zone: TimeZone
    let name: String
    let russianName: String

    func shown(russian: Bool) -> String { russian && !russianName.isEmpty ? russianName : name }
}

enum FieldTimes {
    private static let extras: [String: (String, String)] = [
        "sf": ("America/Los_Angeles", "San Francisco"), "san francisco": ("America/Los_Angeles", "San Francisco"),
        "la": ("America/Los_Angeles", "Los Angeles"), "seattle": ("America/Los_Angeles", "Seattle"),
        "portland": ("America/Los_Angeles", "Portland"), "san diego": ("America/Los_Angeles", "San Diego"),
        "silicon valley": ("America/Los_Angeles", "Silicon Valley"), "cupertino": ("America/Los_Angeles", "Cupertino"),
        "nyc": ("America/New_York", "New York"), "ny": ("America/New_York", "New York"),
        "washington": ("America/New_York", "Washington"), "dc": ("America/New_York", "Washington"),
        "boston": ("America/New_York", "Boston"), "miami": ("America/New_York", "Miami"),
        "atlanta": ("America/New_York", "Atlanta"), "philadelphia": ("America/New_York", "Philadelphia"),
        "austin": ("America/Chicago", "Austin"), "dallas": ("America/Chicago", "Dallas"),
        "houston": ("America/Chicago", "Houston"), "beijing": ("Asia/Shanghai", "Beijing"),
        "delhi": ("Asia/Kolkata", "Delhi"), "new delhi": ("Asia/Kolkata", "New Delhi"),
        "mumbai": ("Asia/Kolkata", "Mumbai"), "bangalore": ("Asia/Kolkata", "Bangalore"),
        "bengaluru": ("Asia/Kolkata", "Bengaluru"), "kiev": ("Europe/Kyiv", "Kyiv"),
        "munich": ("Europe/Berlin", "Munich"), "frankfurt": ("Europe/Berlin", "Frankfurt"),
        "hamburg": ("Europe/Berlin", "Hamburg"), "milan": ("Europe/Rome", "Milan"),
        "barcelona": ("Europe/Madrid", "Barcelona"), "krakow": ("Europe/Warsaw", "Kraków"),
        "kraków": ("Europe/Warsaw", "Kraków"), "gdansk": ("Europe/Warsaw", "Gdańsk"),
        "wroclaw": ("Europe/Warsaw", "Wrocław"), "st petersburg": ("Europe/Moscow", "Saint Petersburg"),
        "saint petersburg": ("Europe/Moscow", "Saint Petersburg"), "petersburg": ("Europe/Moscow", "Saint Petersburg"),
        "kazan": ("Europe/Moscow", "Kazan"), "osaka": ("Asia/Tokyo", "Osaka"), "kyoto": ("Asia/Tokyo", "Kyoto"),
        "abu dhabi": ("Asia/Dubai", "Abu Dhabi"), "tel aviv": ("Asia/Jerusalem", "Tel Aviv"),
        "melbourne": ("Australia/Melbourne", "Melbourne"), "vancouver": ("America/Vancouver", "Vancouver"),
        "montreal": ("America/Toronto", "Montreal"), "rio": ("America/Sao_Paulo", "Rio de Janeiro"),
        "rio de janeiro": ("America/Sao_Paulo", "Rio de Janeiro"), "sao paulo": ("America/Sao_Paulo", "São Paulo"),
        "hong kong": ("Asia/Hong_Kong", "Hong Kong"), "utc": ("UTC", "UTC"), "gmt": ("GMT", "GMT"),
        "msk": ("Europe/Moscow", "Moscow"), "pst": ("America/Los_Angeles", "Pacific Time"),
        "pdt": ("America/Los_Angeles", "Pacific Time"), "pt": ("America/Los_Angeles", "Pacific Time"),
        "est": ("America/New_York", "Eastern Time"), "edt": ("America/New_York", "Eastern Time"),
        "et": ("America/New_York", "Eastern Time"), "cet": ("Europe/Paris", "Central Europe"),
        "cest": ("Europe/Paris", "Central Europe"), "eet": ("Europe/Helsinki", "Eastern Europe"),
        "eest": ("Europe/Helsinki", "Eastern Europe"), "jst": ("Asia/Tokyo", "Japan"), "kst": ("Asia/Seoul", "Korea"),
        "aest": ("Australia/Sydney", "Sydney"), "hkt": ("Asia/Hong_Kong", "Hong Kong"),
        "sgt": ("Asia/Singapore", "Singapore"), "мск": ("Europe/Moscow", "Москва"),
        "utc+0": ("UTC", "UTC"), "zulu": ("UTC", "UTC"),
    ]

    static let russian: [(stem: String, id: String, name: String)] = [
        ("москв", "Europe/Moscow", "Москва"), ("санкт петербург", "Europe/Moscow", "Санкт-Петербург"),
        ("петербург", "Europe/Moscow", "Санкт-Петербург"), ("питер", "Europe/Moscow", "Санкт-Петербург"),
        ("казан", "Europe/Moscow", "Казань"), ("минск", "Europe/Minsk", "Минск"), ("киев", "Europe/Kyiv", "Киев"),
        ("варшав", "Europe/Warsaw", "Варшава"), ("краков", "Europe/Warsaw", "Краков"),
        ("вильнюс", "Europe/Vilnius", "Вильнюс"), ("риг", "Europe/Riga", "Рига"), ("таллин", "Europe/Tallinn", "Таллин"),
        ("берлин", "Europe/Berlin", "Берлин"), ("мюнхен", "Europe/Berlin", "Мюнхен"), ("париж", "Europe/Paris", "Париж"),
        ("лондон", "Europe/London", "Лондон"), ("мадрид", "Europe/Madrid", "Мадрид"),
        ("барселон", "Europe/Madrid", "Барселона"), ("рим", "Europe/Rome", "Рим"), ("милан", "Europe/Rome", "Милан"),
        ("праг", "Europe/Prague", "Прага"), ("вен", "Europe/Vienna", "Вена"), ("амстердам", "Europe/Amsterdam", "Амстердам"),
        ("лиссабон", "Europe/Lisbon", "Лиссабон"), ("афин", "Europe/Athens", "Афины"), ("хельсинк", "Europe/Helsinki", "Хельсинки"),
        ("стокгольм", "Europe/Stockholm", "Стокгольм"), ("стамбул", "Europe/Istanbul", "Стамбул"),
        ("тбилиси", "Asia/Tbilisi", "Тбилиси"), ("ереван", "Asia/Yerevan", "Ереван"), ("баку", "Asia/Baku", "Баку"),
        ("алмат", "Asia/Almaty", "Алматы"), ("астан", "Asia/Almaty", "Астана"), ("ташкент", "Asia/Tashkent", "Ташкент"),
        ("бишкек", "Asia/Bishkek", "Бишкек"), ("екатеринбург", "Asia/Yekaterinburg", "Екатеринбург"),
        ("новосибирск", "Asia/Novosibirsk", "Новосибирск"), ("владивосток", "Asia/Vladivostok", "Владивосток"),
        ("калининград", "Europe/Kaliningrad", "Калининград"), ("самар", "Europe/Samara", "Самара"),
        ("дуба", "Asia/Dubai", "Дубай"), ("токио", "Asia/Tokyo", "Токио"), ("сеул", "Asia/Seoul", "Сеул"),
        ("пекин", "Asia/Shanghai", "Пекин"), ("шанха", "Asia/Shanghai", "Шанхай"), ("гонконг", "Asia/Hong_Kong", "Гонконг"),
        ("сингапур", "Asia/Singapore", "Сингапур"), ("бангкок", "Asia/Bangkok", "Бангкок"), ("бали", "Asia/Makassar", "Бали"),
        ("дели", "Asia/Kolkata", "Дели"), ("нью дели", "Asia/Kolkata", "Нью-Дели"), ("мумба", "Asia/Kolkata", "Мумбаи"),
        ("сидне", "Australia/Sydney", "Сидней"), ("мельбурн", "Australia/Melbourne", "Мельбурн"),
        ("нью йорк", "America/New_York", "Нью-Йорк"), ("вашингтон", "America/New_York", "Вашингтон"),
        ("бостон", "America/New_York", "Бостон"), ("майами", "America/New_York", "Майами"),
        ("чикаго", "America/Chicago", "Чикаго"), ("денвер", "America/Denver", "Денвер"),
        ("лос анджелес", "America/Los_Angeles", "Лос-Анджелес"), ("сан франциско", "America/Los_Angeles", "Сан-Франциско"),
        ("сиэтл", "America/Los_Angeles", "Сиэтл"), ("торонто", "America/Toronto", "Торонто"),
        ("ванкувер", "America/Vancouver", "Ванкувер"), ("мехико", "America/Mexico_City", "Мехико"),
        ("буэнос айрес", "America/Argentina/Buenos_Aires", "Буэнос-Айрес"), ("сан паулу", "America/Sao_Paulo", "Сан-Паулу"),
        ("каир", "Africa/Cairo", "Каир"), ("тель авив", "Asia/Jerusalem", "Тель-Авив"), ("иерусалим", "Asia/Jerusalem", "Иерусалим"),
        ("гринвич", "GMT", "Гринвич"),
    ].sorted { $0.0.count > $1.0.count }

    private static let english: [String: (String, String)] = {
        var map: [String: (String, String)] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers where id.contains("/") && !id.hasPrefix("Etc/") {
            guard let city = id.split(separator: "/").last else { continue }
            let name = city.replacingOccurrences(of: "_", with: " ")
            map[name.lowercased()] = (id, name)
        }
        for (phrase, entry) in extras { map[phrase] = entry }
        return map
    }()

    static func zone(named phrase: String) -> AnswerZone? {
        let name = phrase.replacingOccurrences(of: "-", with: " ").split(separator: " ").joined(separator: " ")
        guard !name.isEmpty else { return nil }
        if let (id, shown) = english[name], let zone = TimeZone(identifier: id) {
            let russianName = russian.first { $0.id == id && $0.name.count > 0 && id != "UTC" }
            return AnswerZone(zone: zone, name: shown, russianName: shown == "UTC" || shown == "GMT" ? shown : russianName?.name ?? "")
        }
        for entry in russian where name.hasPrefix(entry.stem) {
            let rest = name.dropFirst(entry.stem.count)
            guard rest.count <= 2, rest.allSatisfy(\.isLetter), let zone = TimeZone(identifier: entry.id) else { continue }
            return AnswerZone(zone: zone, name: entry.name, russianName: entry.name)
        }
        return nil
    }

    static func here(_ zone: TimeZone) -> AnswerZone {
        let city = zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
        let russianName = russian.first { $0.id == zone.identifier }?.name ?? ""
        return AnswerZone(zone: zone, name: city ?? zone.identifier, russianName: russianName)
    }

    private static let askings: [(String, String)] = [
        ("what time is it in ", "time in "), ("what's the time in ", "time in "), ("what is the time in ", "time in "),
        ("the time in ", "time in "),
        ("current time in ", "time in "), ("local time in ", "time in "), ("time now in ", "time in "),
        ("который час в ", "время в "), ("который час во ", "время в "), ("сколько времени в ", "время в "),
        ("сколько сейчас времени в ", "время в "), ("текущее время в ", "время в "), ("местное время в ", "время в "),
        ("сколько времени ", "время в "), ("который час ", "время в "),
    ]

    private static let nowWords: Set<String> = ["now", "time", "сейчас", "время"]
    private static let to: Set<String> = ["to", "in", "into", "→", "в", "во", "=", "as"]

    struct Clock: Equatable {
        let hour: Int
        let minute: Int
    }

    static func clock(_ words: [String]) -> (Clock?, Int)? {
        guard let first = words.first else { return nil }
        if nowWords.contains(first) { return (nil, 1) }
        switch first {
        case "noon", "midday", "полдень": return (Clock(hour: 12, minute: 0), 1)
        case "midnight", "полночь": return (Clock(hour: 0, minute: 0), 1)
        default: break
        }
        var word = first
        var used = 1
        var half: String?
        for mark in ["am", "pm", "a.m.", "p.m."] where word.hasSuffix(mark) && word.count > mark.count {
            half = String(mark.prefix(1))
            word.removeLast(mark.count)
        }
        if half == nil, words.count > 1, ["am", "pm", "a.m.", "p.m."].contains(words[1]) {
            half = String(words[1].prefix(1))
            used = 2
        }
        let parts = word.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), parts[0].count <= 2
        else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) ?? 99 : 0
        guard parts.count == 2 ? parts[1].count == 2 : half != nil, minute < 60 else { return nil }
        if let half {
            guard (1...12).contains(hour) else { return nil }
            return (Clock(hour: hour % 12 + (half == "p" ? 12 : 0), minute: minute), used)
        }
        guard hour < 24 else { return nil }
        return (Clock(hour: hour, minute: minute), used)
    }

    static func answer(_ text: String, expression: String, context: AnswerContext) -> FieldAnswer? {
        var text = text
        for (asking, plain) in askings where text.hasPrefix(asking) {
            text = plain + text.dropFirst(asking.count)
            break
        }
        var words = text.split(separator: " ").map(String.init)
        var nowAsked = false
        if let last = words.last, last == "time" || last == "время", words.count > 1, !nowWords.contains(words[0]) {
            words.removeLast()
            words.insert("now", at: 0)
        }
        guard let (clock, used) = clock(words) else { return nil }
        nowAsked = clock == nil
        let rest = Array(words.dropFirst(used))
        guard !rest.isEmpty else { return nil }
        var source: AnswerZone?
        var target: AnswerZone?
        if let split = rest.indices.first(where: { to.contains(rest[$0]) }) {
            let before = rest[..<split].filter { $0 != "по" }.joined(separator: " ")
            let after = rest[(split + 1)...].filter { $0 != "по" }.joined(separator: " ")
            guard !after.isEmpty, let found = zone(named: after) else { return nil }
            target = found
            if !before.isEmpty {
                guard let from = zone(named: before) else { return nil }
                source = from
            }
        } else {
            guard let from = zone(named: rest.filter { $0 != "по" }.joined(separator: " ")) else { return nil }
            source = from
        }
        let here = here(context.zone)
        let instant: Date
        let shownZone: AnswerZone
        if nowAsked {
            instant = context.now
            shownZone = target ?? source ?? here
        } else {
            let from = source ?? here
            shownZone = target ?? here
            guard let clock, let made = moment(clock, in: from.zone, near: context.now) else { return nil }
            instant = made
        }
        return format(instant, in: shownZone, expression: expression, context: context)
    }

    static func moment(_ clock: Clock, in zone: TimeZone, near now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = clock.hour
        parts.minute = clock.minute
        return calendar.date(from: parts)
    }

    static func offset(_ zone: TimeZone, at instant: Date) -> String {
        let seconds = zone.secondsFromGMT(for: instant)
        guard seconds != 0 else { return "UTC" }
        let size = abs(seconds)
        let minutes = size % 3600 / 60
        return "UTC" + (seconds < 0 ? "−" : "+") + String(size / 3600) + (minutes == 0 ? "" : String(format: ":%02d", minutes))
    }

    static func format(_ instant: Date, in place: AnswerZone, expression: String, context: AnswerContext) -> FieldAnswer {
        let locale = context.wordsLocale
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = place.zone
        time.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale)
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = place.zone
        day.dateFormat = DateFormatter.dateFormat(fromTemplate: "EEEdMMM", options: 0, locale: locale)
        let clock = time.string(from: instant)
        let plain = clock.replacingOccurrences(of: "\u{202F}", with: " ")
        let detail = [day.string(from: instant), place.shown(russian: context.russian), offset(place.zone, at: instant)]
            .joined(separator: " · ")
        return FieldAnswer(kind: .time, expression: expression, answer: clock, copy: plain, detail: detail)
    }
}
