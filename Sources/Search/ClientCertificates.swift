import Foundation

struct DERItem {
    var tag: UInt8
    var whole: Data
    var content: Data

    static func read(_ data: Data) -> [DERItem] {
        let bytes = [UInt8](data)
        var items: [DERItem] = []
        var at = 0
        while at < bytes.count {
            let start = at
            let tag = bytes[at]
            at += 1
            guard at < bytes.count else { break }
            var length = Int(bytes[at])
            at += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count > 0, count <= 4, at + count <= bytes.count else { break }
                length = 0
                for _ in 0..<count {
                    length = length << 8 | Int(bytes[at])
                    at += 1
                }
            }
            guard length >= 0, at + length <= bytes.count else { break }
            items.append(DERItem(tag: tag, whole: Data(bytes[start..<(at + length)]), content: Data(bytes[at..<(at + length)])))
            at += length
        }
        return items
    }

    var children: [DERItem] { DERItem.read(content) }

    var text: String? {
        switch tag {
        case 0x0C, 0x13, 0x16, 0x14: return String(data: content, encoding: .utf8) ?? String(data: content, encoding: .isoLatin1)
        case 0x1E: return String(data: content, encoding: .utf16BigEndian)
        default: return nil
        }
    }

    var date: Date? {
        guard let text = String(data: content, encoding: .ascii), text.hasSuffix("Z") else { return nil }
        var digits = String(text.dropLast())
        if tag == 0x17 {
            guard let year = Int(digits.prefix(2)) else { return nil }
            digits = (year >= 50 ? "19" : "20") + digits
        } else if tag != 0x18 {
            return nil
        }
        if digits.count == 12 { digits += "00" }
        guard digits.count == 14 else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyyMMddHHmmss"
        return format.date(from: digits)
    }
}

struct DistinguishedName: Equatable {
    var parts: [[String]]

    static let commonName = Data([0x55, 0x04, 0x03])

    init?(der: Data) {
        guard let name = DERItem.read(der).first, name.tag == 0x30 else { return nil }
        var parts: [[String]] = []
        var common: String?
        for set in name.children where set.tag == 0x31 {
            var rdn: [String] = []
            for pair in set.children where pair.tag == 0x30 {
                let fields = pair.children
                guard fields.count >= 2, fields[0].tag == 0x06 else { continue }
                let value = fields[1].text ?? fields[1].content.base64EncodedString()
                let folded = value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                rdn.append(fields[0].content.base64EncodedString() + "=" + folded)
                if fields[0].content == Self.commonName { common = value }
            }
            parts.append(rdn.sorted())
        }
        self.parts = parts
        self.common = common
    }

    var common: String?

    static func == (a: DistinguishedName, b: DistinguishedName) -> Bool { a.parts == b.parts }
}

struct ClientCandidate: Equatable, Sendable {
    var id: String
    var name: String
    var issuer: Data
    var issuerName: String
    var notBefore: Date?
    var notAfter: Date
    var canSign: Bool

    static let keyUsage = Data([0x55, 0x1D, 0x0F])

    init(id: String, name: String, issuer: Data, issuerName: String, notBefore: Date?, notAfter: Date, canSign: Bool) {
        self.id = id
        self.name = name
        self.issuer = issuer
        self.issuerName = issuerName
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.canSign = canSign
    }

    init?(der: Data, id: String, name: String? = nil) {
        guard let certificate = DERItem.read(der).first, certificate.tag == 0x30,
              let tbs = certificate.children.first, tbs.tag == 0x30 else { return nil }
        var fields = tbs.children
        if fields.first?.tag == 0xA0 { fields.removeFirst() }
        guard fields.count >= 6 else { return nil }
        let issuer = fields[2]
        let validity = fields[3].children
        let subject = fields[4]
        guard issuer.tag == 0x30, validity.count == 2, let until = validity[1].date else { return nil }
        var canSign = true
        if let extensions = fields.first(where: { $0.tag == 0xA3 })?.children.first {
            for item in extensions.children {
                let parts = item.children
                guard parts.first?.tag == 0x06, parts.first?.content == Self.keyUsage, let value = parts.last, value.tag == 0x04,
                      let bits = DERItem.read(value.content).first, bits.tag == 0x03 else { continue }
                let bytes = [UInt8](bits.content)
                canSign = bytes.count >= 2 && bytes[1] & 0x80 != 0
            }
        }
        self.init(
            id: id,
            name: name ?? DistinguishedName(der: subject.whole)?.common ?? "",
            issuer: issuer.whole,
            issuerName: DistinguishedName(der: issuer.whole)?.common ?? "",
            notBefore: validity[0].date,
            notAfter: until,
            canSign: canSign
        )
    }
}

struct ClientEndpoint: Hashable, Sendable {
    var holder: CertificateHolder
    var host: String
    var port: Int

    init(holder: CertificateHolder, host: String, port: Int) {
        self.holder = holder
        self.host = CertificateExceptions.normal(host)
        self.port = port
    }
}

enum ClientChoice: Equatable, Sendable {
    case identity(String)
    case refused
}

enum ClientReply: Equatable, Sendable {
    case none
    case use(String)
}

final class ClientCertificates {
    struct Request {
        var endpoint: ClientEndpoint
        var isPage: Bool
        var onScreen: Bool
        var agent: Bool
        var fitting: [ClientCandidate]
    }

    enum Step: Equatable {
        case answered
        case joined
        case queued(showNow: Bool)
    }

    static func fitting(_ candidates: [ClientCandidate], asked names: [Data], at now: Date) -> [ClientCandidate] {
        let wanted = names.compactMap(DistinguishedName.init(der:))
        return candidates.filter { candidate in
            guard candidate.canSign, now < candidate.notAfter, candidate.notBefore.map({ $0 <= now }) ?? true else { return false }
            guard !names.isEmpty else { return true }
            guard let issuer = DistinguishedName(der: candidate.issuer) else { return false }
            return wanted.contains(issuer)
        }
    }

    private(set) var kept: [ClientEndpoint: ClientChoice] = [:]
    private var waiting: [ClientEndpoint: [(ClientReply) -> Void]] = [:]
    private(set) var queue: [ClientEndpoint] = []
    private(set) var showing: ClientEndpoint?

    func request(_ request: Request, reply: @escaping (ClientReply) -> Void) -> Step {
        let endpoint = request.endpoint
        guard request.isPage, !request.agent else {
            reply(.none)
            return .answered
        }
        if let choice = kept[endpoint] {
            reply(Self.reply(for: choice, fitting: request.fitting))
            return .answered
        }
        if waiting[endpoint] != nil {
            waiting[endpoint, default: []].append(reply)
            return .joined
        }
        guard request.onScreen, !request.fitting.isEmpty else {
            reply(.none)
            return .answered
        }
        waiting[endpoint] = [reply]
        queue.append(endpoint)
        guard showing == nil else { return .queued(showNow: false) }
        showing = queue.removeFirst()
        return .queued(showNow: true)
    }

    static func reply(for choice: ClientChoice, fitting: [ClientCandidate]) -> ClientReply {
        guard case .identity(let id) = choice, fitting.contains(where: { $0.id == id }) else { return .none }
        return .use(id)
    }

    @discardableResult
    func answer(_ endpoint: ClientEndpoint, with choice: ClientChoice) -> ClientEndpoint? {
        kept[endpoint] = choice
        let reply: ClientReply = if case .identity(let id) = choice { .use(id) } else { .none }
        return finish(endpoint, reply)
    }

    @discardableResult
    func abandon(_ endpoint: ClientEndpoint) -> ClientEndpoint? {
        finish(endpoint, .none)
    }

    private func finish(_ endpoint: ClientEndpoint, _ reply: ClientReply) -> ClientEndpoint? {
        let handlers = waiting.removeValue(forKey: endpoint) ?? []
        queue.removeAll { $0 == endpoint }
        if showing == endpoint { showing = nil }
        for handler in handlers { handler(reply) }
        guard showing == nil, !queue.isEmpty else { return nil }
        showing = queue.removeFirst()
        return showing
    }

    func clearEverything() {
        kept = [:]
    }

    func clear(_ holder: CertificateHolder, where belongs: (String) -> Bool) {
        kept = kept.filter { $0.key.holder != holder || !belongs($0.key.host) }
    }

    func forget(_ holder: CertificateHolder) {
        kept = kept.filter { $0.key.holder != holder }
    }
}
