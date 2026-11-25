import Foundation

enum AgentNear {
    typealias Named = (ref: String, role: String, name: String)

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 }
    }

    static func shared(_ want: [String], _ have: [String]) -> Int {
        want.filter { word in
            have.contains { $0 == word || ($0.count >= 4 && word.count >= 4 && ($0.hasPrefix(word) || word.hasPrefix($0))) }
        }.count
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a.lowercased().prefix(80)), b = Array(b.lowercased().prefix(80))
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var last = row[0]
            row[0] = i
            for j in 1...b.count {
                let kept = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, last + (a[i - 1] == b[j - 1] ? 0 : 1))
                last = kept
            }
        }
        return row[b.count]
    }

    static func score(_ want: String, _ name: String) -> (shared: Int, distance: Int, near: Bool) {
        let shared = shared(words(want), words(name))
        let whole = distance(want, name)
        let start = distance(want, String(name.prefix(want.count)))
        let near = shared > 0 || min(whole, start) <= max(2, want.count / 3)
        return (shared, whole, near)
    }

    static func ranked(_ want: String, _ texts: [String], most: Int) -> [Int] {
        var seen: Set<String> = []
        let scored = texts.indices.compactMap { index -> (index: Int, shared: Int, distance: Int)? in
            let text = texts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 400 else { return nil }
            let found = score(want, text)
            return found.near ? (index, found.shared, found.distance) : nil
        }
        return scored.sorted { $0.shared != $1.shared ? $0.shared > $1.shared : $0.distance != $1.distance ? $0.distance < $1.distance : $0.index < $1.index }
            .filter { seen.insert(texts[$0.index].lowercased()).inserted }
            .prefix(most).map(\.index)
    }

    static func closest(_ want: String, among names: [Named], most: Int = 3) -> [Named] {
        let keys = names.map { $0.name }
        var seen: Set<String> = []
        let order = ranked(want, keys, most: names.count).filter { seen.insert("\(names[$0].role)|\(names[$0].name.lowercased())").inserted }
        return order.prefix(most).map { names[$0] }
    }

    static func closestLines(_ want: String, in lines: [String], most: Int = 3) -> [String] {
        ranked(want, lines, most: most).map { lines[$0] }
    }

    static func line(_ named: Named) -> String {
        "@\(named.ref) \(named.role) \"\(AgentChange.cell(named.name, most: 60))\""
    }
}
