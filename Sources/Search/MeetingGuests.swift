import AppKit

enum MeetingGuests {
    static func name(_ person: MeetingPerson) -> String {
        guard person.name.isEmpty else { return person.name.split(separator: " ").first.map(String.init) ?? person.name }
        let local = person.email.split(separator: "@", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return local.isEmpty ? person.email : local
    }

    static func tail(_ names: [String]) -> String {
        switch names.count {
        case 0, 1: ""
        case 2: " and \(names[1])"
        default: " and \(names.count - 1) others"
        }
    }

    static func line(_ names: [String], fits: (String) -> Bool = { _ in true }) -> String {
        guard let first = names.first else { return "" }
        let tail = tail(names)
        let whole = "With \(first)\(tail)"
        guard !tail.isEmpty, !fits(whole) else { return whole }
        var kept = Array(first)
        while kept.count > 1 {
            kept.removeLast()
            let stem = String(kept).trimmingCharacters(in: CharacterSet(charactersIn: " .-_+"))
            guard !stem.isEmpty else { break }
            let cut = "With \(stem)…\(tail)"
            if fits(cut) { return cut }
        }
        return whole
    }

    static func line(_ names: [String], font: NSFont, width: CGFloat) -> String {
        line(names) { ceil(NSAttributedString(string: $0, attributes: [.font: font]).size().width) <= width }
    }
}
