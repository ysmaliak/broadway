import Foundation

struct AnswerUnit {
    let unit: Dimension
    let symbol: String
    let russian: [String]
    let names: [String]
    let stems: [String]

    func shown(_ number: String, value: Double, russian ru: Bool) -> String {
        guard ru else { return number + " " + symbol }
        if russian.count == 1 { return number + " " + russian[0] }
        return number + " " + Self.plural(value, russian)
    }

    static func plural(_ value: Double, _ forms: [String]) -> String {
        guard value.rounded() == value, abs(value) < 1e15 else { return forms[1] }
        let whole = Int64(abs(value))
        let tens = whole % 100
        let ones = whole % 10
        if (11...14).contains(tens) { return forms[2] }
        if ones == 1 { return forms[0] }
        if (2...4).contains(ones) { return forms[1] }
        return forms[2]
    }
}

enum FieldUnits {
    static let day = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400))
    static let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800))
    static let year = UnitDuration(symbol: "yr", converter: UnitConverterLinear(coefficient: 31_557_600))
    static let cup = UnitVolume(symbol: "cup", converter: UnitConverterLinear(coefficient: 0.236_588_236_5))

    static func family(_ unit: Dimension) -> Int {
        switch unit {
        case is UnitLength: return 1
        case is UnitMass: return 2
        case is UnitTemperature: return 3
        case is UnitVolume: return 4
        case is UnitSpeed: return 5
        case is UnitInformationStorage: return 6
        case is UnitDuration: return 7
        case is UnitArea: return 8
        default: return 0
        }
    }

    static let all: [AnswerUnit] = [
        AnswerUnit(unit: UnitLength.kilometers, symbol: "km", russian: ["км"],
                   names: ["km", "kms", "kilometer", "kilometre", "kilometers", "kilometres", "км"], stems: ["километр"]),
        AnswerUnit(unit: UnitLength.meters, symbol: "m", russian: ["м"],
                   names: ["m", "meter", "metre", "meters", "metres", "м"], stems: ["метр"]),
        AnswerUnit(unit: UnitLength.centimeters, symbol: "cm", russian: ["см"],
                   names: ["cm", "centimeter", "centimetre", "centimeters", "centimetres", "см"], stems: ["сантиметр"]),
        AnswerUnit(unit: UnitLength.millimeters, symbol: "mm", russian: ["мм"],
                   names: ["mm", "millimeter", "millimetre", "millimeters", "millimetres", "мм"], stems: ["миллиметр"]),
        AnswerUnit(unit: UnitLength.miles, symbol: "mi", russian: ["миля", "мили", "миль"],
                   names: ["mi", "mile", "miles"], stems: ["мил"]),
        AnswerUnit(unit: UnitLength.yards, symbol: "yd", russian: ["ярд", "ярда", "ярдов"],
                   names: ["yd", "yds", "yard", "yards"], stems: ["ярд"]),
        AnswerUnit(unit: UnitLength.feet, symbol: "ft", russian: ["фут", "фута", "футов"],
                   names: ["ft", "foot", "feet", "'"], stems: ["фут"]),
        AnswerUnit(unit: UnitLength.inches, symbol: "in", russian: ["дюйм", "дюйма", "дюймов"],
                   names: ["in", "inch", "inches", "\""], stems: ["дюйм"]),
        AnswerUnit(unit: UnitLength.nauticalMiles, symbol: "nmi", russian: ["морская миля", "морские мили", "морских миль"],
                   names: ["nmi", "nautical mile", "nautical miles"], stems: []),

        AnswerUnit(unit: UnitMass.kilograms, symbol: "kg", russian: ["кг"],
                   names: ["kg", "kgs", "kilo", "kilos", "kilogram", "kilograms", "кг"], stems: ["килограмм", "кило"]),
        AnswerUnit(unit: UnitMass.grams, symbol: "g", russian: ["г"],
                   names: ["g", "gram", "grams", "gramme", "grammes", "г", "гр"], stems: ["грамм"]),
        AnswerUnit(unit: UnitMass.milligrams, symbol: "mg", russian: ["мг"],
                   names: ["mg", "milligram", "milligrams", "мг"], stems: ["миллиграмм"]),
        AnswerUnit(unit: UnitMass.metricTons, symbol: "t", russian: ["т"],
                   names: ["t", "tonne", "tonnes", "metric ton", "metric tons", "т"], stems: ["тонн"]),
        AnswerUnit(unit: UnitMass.pounds, symbol: "lb", russian: ["фунт", "фунта", "фунтов"],
                   names: ["lb", "lbs", "pound", "pounds"], stems: ["фунт"]),
        AnswerUnit(unit: UnitMass.ounces, symbol: "oz", russian: ["унция", "унции", "унций"],
                   names: ["oz", "ounce", "ounces"], stems: ["унци"]),
        AnswerUnit(unit: UnitMass.stones, symbol: "st", russian: ["стоун", "стоуна", "стоунов"],
                   names: ["st", "stone", "stones"], stems: ["стоун"]),

        AnswerUnit(unit: UnitTemperature.celsius, symbol: "°C", russian: ["°C"],
                   names: ["c", "°c", "celsius", "centigrade", "с", "°с"], stems: ["цельси"]),
        AnswerUnit(unit: UnitTemperature.fahrenheit, symbol: "°F", russian: ["°F"],
                   names: ["f", "°f", "fahrenheit", "ф", "°ф"], stems: ["фаренгейт"]),
        AnswerUnit(unit: UnitTemperature.kelvin, symbol: "K", russian: ["K"],
                   names: ["k", "kelvin", "kelvins", "к"], stems: ["кельвин"]),

        AnswerUnit(unit: UnitVolume.liters, symbol: "L", russian: ["л"],
                   names: ["l", "liter", "litre", "liters", "litres", "ltr", "л"], stems: ["литр"]),
        AnswerUnit(unit: UnitVolume.milliliters, symbol: "mL", russian: ["мл"],
                   names: ["ml", "milliliter", "millilitre", "milliliters", "millilitres", "мл"], stems: ["миллилитр"]),
        AnswerUnit(unit: UnitVolume.cubicMeters, symbol: "m³", russian: ["м³"],
                   names: ["m3", "m³", "cubic meter", "cubic meters", "cubic metre", "cubic metres", "м3", "м³"], stems: []),
        AnswerUnit(unit: UnitVolume.gallons, symbol: "gal", russian: ["галлон", "галлона", "галлонов"],
                   names: ["gal", "gals", "gallon", "gallons"], stems: ["галлон"]),
        AnswerUnit(unit: UnitVolume.quarts, symbol: "qt", russian: ["кварта", "кварты", "кварт"],
                   names: ["qt", "quart", "quarts"], stems: ["кварт"]),
        AnswerUnit(unit: UnitVolume.pints, symbol: "pt", russian: ["пинта", "пинты", "пинт"],
                   names: ["pt", "pint", "pints"], stems: ["пинт"]),
        AnswerUnit(unit: cup, symbol: "cups", russian: ["чашка", "чашки", "чашек"],
                   names: ["cup", "cups"], stems: ["чашк", "чашек", "стакан"]),
        AnswerUnit(unit: UnitVolume.fluidOunces, symbol: "fl oz", russian: ["жидкая унция", "жидкие унции", "жидких унций"],
                   names: ["fl oz", "floz", "fluid ounce", "fluid ounces"], stems: []),
        AnswerUnit(unit: UnitVolume.tablespoons, symbol: "tbsp", russian: ["ст. л."],
                   names: ["tbsp", "tablespoon", "tablespoons", "ст. л.", "ст.л."], stems: ["столов"]),
        AnswerUnit(unit: UnitVolume.teaspoons, symbol: "tsp", russian: ["ч. л."],
                   names: ["tsp", "teaspoon", "teaspoons", "ч. л.", "ч.л."], stems: ["чайн"]),

        AnswerUnit(unit: UnitSpeed.kilometersPerHour, symbol: "km/h", russian: ["км/ч"],
                   names: ["km/h", "kmh", "kph", "kmph", "kilometers per hour", "kilometres per hour", "км/ч", "км/час",
                           "километров в час", "километра в час"], stems: []),
        AnswerUnit(unit: UnitSpeed.metersPerSecond, symbol: "m/s", russian: ["м/с"],
                   names: ["m/s", "mps", "meters per second", "metres per second", "м/с", "метров в секунду"], stems: []),
        AnswerUnit(unit: UnitSpeed.milesPerHour, symbol: "mph", russian: ["миль/ч"],
                   names: ["mph", "mi/h", "miles per hour", "миль/ч", "миль в час", "мили в час", "миля в час"], stems: []),
        AnswerUnit(unit: UnitSpeed.knots, symbol: "kn", russian: ["узел", "узла", "узлов"],
                   names: ["kn", "kt", "kts", "knot", "knots", "узел"], stems: ["узл"]),

        AnswerUnit(unit: UnitInformationStorage.bytes, symbol: "B", russian: ["байт", "байта", "байт"],
                   names: ["b", "byte", "bytes"], stems: ["байт"]),
        AnswerUnit(unit: UnitInformationStorage.bits, symbol: "bit", russian: ["бит", "бита", "бит"],
                   names: ["bit", "bits"], stems: ["бит"]),
        AnswerUnit(unit: UnitInformationStorage.kilobytes, symbol: "KB", russian: ["КБ"],
                   names: ["kb", "kilobyte", "kilobytes", "кб"], stems: ["килобайт"]),
        AnswerUnit(unit: UnitInformationStorage.megabytes, symbol: "MB", russian: ["МБ"],
                   names: ["mb", "megabyte", "megabytes", "мб"], stems: ["мегабайт"]),
        AnswerUnit(unit: UnitInformationStorage.gigabytes, symbol: "GB", russian: ["ГБ"],
                   names: ["gb", "gigabyte", "gigabytes", "гб"], stems: ["гигабайт"]),
        AnswerUnit(unit: UnitInformationStorage.terabytes, symbol: "TB", russian: ["ТБ"],
                   names: ["tb", "terabyte", "terabytes", "тб"], stems: ["терабайт"]),
        AnswerUnit(unit: UnitInformationStorage.petabytes, symbol: "PB", russian: ["ПБ"],
                   names: ["pb", "petabyte", "petabytes", "пб"], stems: ["петабайт"]),
        AnswerUnit(unit: UnitInformationStorage.kibibytes, symbol: "KiB", russian: ["КиБ"],
                   names: ["kib", "kibibyte", "kibibytes", "киб"], stems: []),
        AnswerUnit(unit: UnitInformationStorage.mebibytes, symbol: "MiB", russian: ["МиБ"],
                   names: ["mib", "mebibyte", "mebibytes", "миб"], stems: []),
        AnswerUnit(unit: UnitInformationStorage.gibibytes, symbol: "GiB", russian: ["ГиБ"],
                   names: ["gib", "gibibyte", "gibibytes", "гиб"], stems: []),
        AnswerUnit(unit: UnitInformationStorage.tebibytes, symbol: "TiB", russian: ["ТиБ"],
                   names: ["tib", "tebibyte", "tebibytes", "тиб"], stems: []),
        AnswerUnit(unit: UnitInformationStorage.kilobits, symbol: "kbit", russian: ["кбит"],
                   names: ["kbit", "kbits", "kilobit", "kilobits", "кбит"], stems: ["килобит"]),
        AnswerUnit(unit: UnitInformationStorage.megabits, symbol: "Mbit", russian: ["Мбит"],
                   names: ["mbit", "mbits", "megabit", "megabits", "мбит"], stems: ["мегабит"]),
        AnswerUnit(unit: UnitInformationStorage.gigabits, symbol: "Gbit", russian: ["Гбит"],
                   names: ["gbit", "gbits", "gigabit", "gigabits", "гбит"], stems: ["гигабит"]),

        AnswerUnit(unit: UnitDuration.nanoseconds, symbol: "ns", russian: ["нс"],
                   names: ["ns", "nanosecond", "nanoseconds", "нс"], stems: ["наносекунд"]),
        AnswerUnit(unit: UnitDuration.microseconds, symbol: "µs", russian: ["мкс"],
                   names: ["µs", "us", "microsecond", "microseconds", "мкс"], stems: ["микросекунд"]),
        AnswerUnit(unit: UnitDuration.milliseconds, symbol: "ms", russian: ["мс"],
                   names: ["ms", "millisecond", "milliseconds", "мс"], stems: ["миллисекунд"]),
        AnswerUnit(unit: UnitDuration.seconds, symbol: "s", russian: ["с"],
                   names: ["s", "sec", "secs", "second", "seconds", "сек"], stems: ["секунд"]),
        AnswerUnit(unit: UnitDuration.minutes, symbol: "min", russian: ["мин"],
                   names: ["min", "mins", "minute", "minutes", "мин"], stems: ["минут"]),
        AnswerUnit(unit: UnitDuration.hours, symbol: "h", russian: ["ч"],
                   names: ["h", "hr", "hrs", "hour", "hours", "ч"], stems: ["час"]),
        AnswerUnit(unit: day, symbol: "days", russian: ["день", "дня", "дней"],
                   names: ["d", "day", "days", "день", "сутки", "суток"], stems: ["дн"]),
        AnswerUnit(unit: week, symbol: "weeks", russian: ["неделя", "недели", "недель"],
                   names: ["wk", "wks", "week", "weeks", "нед"], stems: ["недел"]),
        AnswerUnit(unit: year, symbol: "years", russian: ["год", "года", "лет"],
                   names: ["y", "yr", "yrs", "year", "years", "лет"], stems: ["год"]),

        AnswerUnit(unit: UnitArea.squareMeters, symbol: "m²", russian: ["м²"],
                   names: ["m2", "m²", "sq m", "sqm", "square meter", "square meters", "square metre", "square metres",
                           "м2", "м²", "кв м", "кв. м", "кв.м", "квадратных метров", "квадратный метр", "квадратных метра"],
                   stems: []),
        AnswerUnit(unit: UnitArea.squareKilometers, symbol: "km²", russian: ["км²"],
                   names: ["km2", "km²", "sq km", "square kilometer", "square kilometers", "square kilometre",
                           "square kilometres", "км2", "км²", "кв км", "кв. км"], stems: []),
        AnswerUnit(unit: UnitArea.squareCentimeters, symbol: "cm²", russian: ["см²"],
                   names: ["cm2", "cm²", "sq cm", "см2", "см²", "кв см"], stems: []),
        AnswerUnit(unit: UnitArea.hectares, symbol: "ha", russian: ["га"],
                   names: ["ha", "hectare", "hectares", "га"], stems: ["гектар"]),
        AnswerUnit(unit: UnitArea.acres, symbol: "acres", russian: ["акр", "акра", "акров"],
                   names: ["ac", "acre", "acres"], stems: ["акр"]),
        AnswerUnit(unit: UnitArea.squareFeet, symbol: "ft²", russian: ["кв. фут", "кв. фута", "кв. футов"],
                   names: ["ft2", "ft²", "sq ft", "sqft", "square foot", "square feet"], stems: []),
        AnswerUnit(unit: UnitArea.squareMiles, symbol: "mi²", russian: ["кв. миля", "кв. мили", "кв. миль"],
                   names: ["mi2", "mi²", "sq mi", "square mile", "square miles"], stems: []),
        AnswerUnit(unit: UnitArea.squareInches, symbol: "in²", russian: ["кв. дюйм", "кв. дюйма", "кв. дюймов"],
                   names: ["in2", "in²", "sq in", "square inch", "square inches"], stems: []),
    ]

    private static let byName: [String: AnswerUnit] = {
        var map: [String: AnswerUnit] = [:]
        for unit in all {
            for name in unit.names where map[name] == nil { map[name] = unit }
        }
        return map
    }()

    private static let byStem: [(String, AnswerUnit)] = all
        .flatMap { unit in unit.stems.map { ($0, unit) } }
        .sorted { $0.0.count > $1.0.count }

    static func unit(named phrase: String) -> AnswerUnit? {
        var name = phrase.trimmingCharacters(in: .whitespaces)
        for lead in ["degrees ", "degree ", "deg ", "градусов ", "градуса ", "градус ", "по "] where name.hasPrefix(lead) {
            name.removeFirst(lead.count)
        }
        if name.hasPrefix("° ") { name = "°" + name.dropFirst(2) }
        if let found = byName[name] { return found }
        if name.hasSuffix("."), let found = byName[String(name.dropLast())] { return found }
        let words = name.split(separator: " ")
        guard words.count == 1 else { return nil }
        let word = String(words[0]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        for (stem, unit) in byStem where word.hasPrefix(stem) {
            let rest = word.dropFirst(stem.count)
            if rest.count <= 3, rest.allSatisfy(\.isLetter) { return unit }
        }
        return nil
    }

    static func answer(_ text: String, expression: String, context: AnswerContext) -> FieldAnswer? {
        for (left, right) in FieldAnswers.splits(text) {
            guard let target = unit(named: right), let (value, source) = amount(left, locale: context.locale),
                  family(source.unit) != 0, family(source.unit) == family(target.unit)
            else { continue }
            let base = source.unit.converter.baseUnitValue(fromValue: value)
            let converted = target.unit.converter.value(fromBaseUnitValue: base)
            var numbers = AnswerNumbers(locale: context.locale)
            numbers.significant = 6
            guard let shown = numbers.string(converted, grouped: true),
                  let plain = numbers.string(converted, grouped: false) else { continue }
            let rounded = Double(plain.replacingOccurrences(of: context.locale.decimalSeparator ?? ".", with: ".")) ?? converted
            return FieldAnswer(kind: .unit, expression: expression,
                               answer: target.shown(shown, value: rounded, russian: context.russian),
                               copy: target.shown(plain, value: rounded, russian: context.russian))
        }
        return nil
    }

    static func amount(_ text: String, locale: Locale) -> (Double, AnswerUnit)? {
        let chars = Array(text)
        var start = 0
        var sign = 1.0
        if chars.first == "-" {
            sign = -1
            start = 1
        } else if chars.first == "+" {
            start = 1
        }
        guard start < chars.count, chars[start].isASCII, chars[start].isNumber || chars[start] == ".",
              let (value, radix, end) = AnswerLexer.number(chars, from: start, locale: locale), radix == nil
        else { return nil }
        let rest = String(chars[end...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, let unit = unit(named: rest) else { return nil }
        return (sign * value, unit)
    }
}
