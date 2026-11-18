import Foundation

enum LiveFile {
    struct Loaded {
        var kept: [LiveFolder]
        var retired: [UUID]
        var foreign: [Data]
        var foreignIDs: Set<UUID>
    }

    private struct Peek: Decodable {
        struct Source: Decodable { let kind: String }
        let id: UUID
        let source: Source?
    }

    static func entries(_ data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        var at = 0
        func skip() { while at < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 } }
        skip()
        guard at < bytes.count, bytes[at] == UInt8(ascii: "[") else { return nil }
        at += 1
        var out: [Data] = []
        skip()
        if at < bytes.count, bytes[at] == UInt8(ascii: "]") {
            at += 1
            skip()
            return at == bytes.count ? [] : nil
        }
        while at < bytes.count {
            skip()
            let start = at
            var depth = 0
            var quoted = false
            var escaped = false
            while at < bytes.count {
                let byte = bytes[at]
                if quoted {
                    if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { quoted = false }
                } else if byte == UInt8(ascii: "\"") {
                    quoted = true
                } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                    depth += 1
                } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                    if depth == 0 { break }
                    depth -= 1
                } else if byte == UInt8(ascii: ","), depth == 0 {
                    break
                }
                at += 1
            }
            guard at < bytes.count, !quoted else { return nil }
            var end = at
            while end > start, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[end - 1]) { end -= 1 }
            guard end > start else { return nil }
            out.append(Data(bytes[start..<end]))
            if bytes[at] == UInt8(ascii: "]") {
                at += 1
                skip()
                return at == bytes.count ? out : nil
            }
            at += 1
        }
        return nil
    }

    static func read(_ data: Data, retiredKinds: Set<String>) -> Loaded? {
        guard let parts = entries(data) else { return nil }
        let decoder = JSONDecoder()
        var loaded = Loaded(kept: [], retired: [], foreign: [], foreignIDs: [])
        for part in parts {
            let peek = try? decoder.decode(Peek.self, from: part)
            if let peek, let kind = peek.source?.kind, retiredKinds.contains(kind) {
                loaded.retired.append(peek.id)
            } else if let folder = try? decoder.decode(LiveFolder.self, from: part) {
                loaded.kept.append(folder)
            } else {
                loaded.foreign.append(part)
                if let id = peek?.id { loaded.foreignIDs.insert(id) }
            }
        }
        return loaded
    }

    static func written(_ folders: [LiveFolder], foreign: [Data]) -> Data? {
        let encoder = JSONEncoder()
        var parts: [Data] = []
        for folder in folders {
            guard let part = try? encoder.encode(folder) else { return nil }
            parts.append(part)
        }
        parts += foreign
        var out = Data("[".utf8)
        for (index, part) in parts.enumerated() {
            if index > 0 { out.append(contentsOf: Array(",".utf8)) }
            out.append(part)
        }
        out.append(contentsOf: Array("]".utf8))
        return out
    }
}

extension LiveFolders {
    static let lostWords = "Your live folders couldn't be loaded. Their tabs were kept as ordinary folders."
}
