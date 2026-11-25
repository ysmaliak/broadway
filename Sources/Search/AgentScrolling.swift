import Foundation

enum AgentScrolling {
    struct Amount: Equatable {
        var mode: String
        var points: Double
    }

    static func amount(_ value: Any?) -> Amount? {
        if let number = value as? Double ?? (value as? NSNumber)?.doubleValue {
            return Amount(mode: number < 0 ? "up" : "down", points: abs(number))
        }
        guard let text = value as? String else { return nil }
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count == 1 {
            if BrowserToolbox.directions.contains(words[0]) { return Amount(mode: words[0], points: 0) }
            if let number = Double(words[0]), number.isFinite { return Amount(mode: number < 0 ? "up" : "down", points: abs(number)) }
            return nil
        }
        guard words.count == 2, ["down", "up", "left", "right"].contains(words[0]), let number = Double(words[1]), number.isFinite else { return nil }
        return Amount(mode: words[0], points: abs(number))
    }

    static func line(mode: String, moved: Int, top: Bool, bottom: Bool, below: Int, above: Int, place: String = "") -> String {
        if moved == 0 { return mode == "up" || mode == "top" ? "Already at the top\(place)" : "Already at the bottom\(place)" }
        switch mode {
        case "top": return "Scrolled to the top\(place)"
        case "bottom": return "Scrolled to the bottom\(place)"
        case "up": return "Scrolled up \(abs(moved)) points\(place), " + (top ? "at the top" : "\(above) more above")
        default: return "Scrolled down \(abs(moved)) points\(place), " + (bottom ? "at the bottom" : "\(below) more below")
        }
    }

    static func sideways(mode: String, moved: Int, end: Bool, left: Int, place: String = "") -> String {
        if moved == 0 { return "Already at the \(mode) end\(place)" }
        return "Scrolled \(mode) \(abs(moved)) points\(place), " + (end ? "at the \(mode) end" : "\(left) more to the \(mode)")
    }

    static func grown(moved: Int, place: String = "") -> String {
        "Scrolled down \(abs(moved)) points\(place), and the page loaded more below"
    }

    static let grownScript = """
    var st = window.__broadwayRefs, el = ref && st && st.map ? st.map[ref] : null;
    var at = el ? el.scrollTop : scrollY, end = el ? el.scrollHeight - el.clientHeight : document.documentElement.scrollHeight - innerHeight;
    return { below: Math.max(0, Math.round(end - at)) };
    """
}
