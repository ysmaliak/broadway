import Foundation
import FoundationModels

struct AIGroupSubject: Equatable, Sendable {
    var subject: String
    var city: String

    static let kinds: Set<String> = [
        "trip", "trips", "travel", "traveling", "travelling", "vacation", "holiday", "holidays", "journey", "flight", "flights",
        "airline", "airlines", "airfare", "hotel", "hotels", "booking", "bookings", "accommodation", "lodging", "stay", "rental",
        "rentals", "apartment", "apartments", "ticket", "tickets", "tour", "tours", "sightseeing", "attraction", "attractions",
        "product", "products", "shopping", "purchase", "purchases", "comparison", "deal", "deals", "sale", "store", "shop",
        "article", "articles", "story", "stories", "blog", "post", "podcast", "episode", "recipe", "recipes", "cooking", "food",
        "issue", "bug", "error", "problem", "fix", "solution", "tutorial", "course", "lesson", "learning", "help", "support",
        "website", "site", "service", "services", "account", "accounts", "app", "application", "software", "tool", "tools",
        "information", "info", "overview", "details", "list", "results", "search", "general", "unknown", "none", "nothing",
        "specific", "thing", "things", "various", "topic", "content", "media", "entertainment", "music", "song", "songs",
        "movie", "movies", "film", "films", "show", "series", "book", "books", "novel", "event", "events", "concert",
        "weather", "forecast", "email", "inbox", "mail", "calendar", "schedule", "notes", "document", "documents", "job",
        "jobs", "career", "careers", "work", "project", "projects", "code", "programming", "development", "technology", "tech",
        "finance", "money", "banking", "bank", "health", "sports", "sport", "game", "games", "politics", "science", "history",
        "education", "study", "research", "city", "country", "region", "world", "local", "international", "online", "digital",
        "personal", "daily", "weekly", "today", "tomorrow", "experience", "experiences", "options", "planning", "plan", "plans",
        "buying", "reading", "watching", "testing", "playing", "finding", "renting", "choosing", "comparing",
        "using", "making", "getting", "looking", "checking", "visiting", "managing", "doing", "person", "people",
    ]

    var words: [String] {
        var out: [String] = []
        let place = AIGroupEvidence.tokens(city).allSatisfy(Self.kinds.contains) ? "" : city
        for word in AIGroupEvidence.tokens(subject + " " + place) where !Self.kinds.contains(word) && !out.contains(word) {
            out.append(word)
        }
        return out
    }

    var line: String {
        let place = city.trimmingCharacters(in: .whitespaces)
        let said = subject.trimmingCharacters(in: .whitespaces)
        guard !place.isEmpty, !AIGroupEvidence.tokens(place).allSatisfy(Self.kinds.contains) else { return said }
        return said.isEmpty ? place : "\(said), in \(place)"
    }

    static func shared(_ one: AIGroupTab, _ mine: AIGroupSubject?, _ two: AIGroupTab, _ theirs: AIGroupSubject?) -> [String] {
        guard AIGroupEvidence.site(one) != AIGroupEvidence.site(two) else { return [] }
        let sites: Set<String> = [AIGroupEvidence.site(one), AIGroupEvidence.site(two)]
        let meant = { (subject: AIGroupSubject?) in (subject?.words ?? []).filter { !sites.contains($0) } }
        let said = { (tab: AIGroupTab) in AIGroupEvidence.tokens(tab.title).filter { !sites.contains($0) && !kinds.contains($0) } }
        let left = meant(mine), right = meant(theirs)
        guard !left.isEmpty || !right.isEmpty else { return [] }
        var out: [String] = []
        for word in left where !out.contains(word) && (right + said(two)).contains(where: { AIGroupEvidence.same(word, $0) }) {
            out.append(word)
        }
        for word in said(one) where !out.contains(word) && right.contains(where: { AIGroupEvidence.same(word, $0) }) {
            out.append(word)
        }
        return out
    }
}

enum AIGroupSubjects {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: AIGroupSubject] = [:]
    nonisolated(unsafe) private static var judged: [String: Bool] = [:]

    static func address(_ tab: AIGroupTab) -> String {
        tab.key + "\n" + tab.title
    }

    static func known(_ tab: AIGroupTab) -> AIGroupSubject? {
        lock.withLock { known[address(tab)] }
    }

    static func remember(_ subject: AIGroupSubject, for tab: AIGroupTab) {
        lock.withLock {
            if known.count > 2000 { known = [:] }
            known[address(tab)] = subject
        }
    }

    static func verdict(_ question: String) -> Bool? {
        lock.withLock { judged[question] }
    }

    static func note(_ question: String, _ yes: Bool) {
        lock.withLock {
            if judged.count > 2000 { judged = [:] }
            judged[question] = yes
        }
    }

    static func forget() {
        lock.withLock {
            known = [:]
            judged = [:]
        }
    }

    static func near(_ one: AIGroupTab, _ two: AIGroupTab) -> Bool {
        !AIGroupSubject.shared(one, known(one), two, known(two)).isEmpty
    }
}

extension MacGroupEngine {
    static let describing = """
    You describe one browser tab so that tabs about the same subject can be found. Answer in English, even when the tab is \
    in another language. Use what you know: a district, sight, airport or venue belongs to its city, and a model belongs to \
    its kind of product. Say none when the tab gives no sign.
    """

    static let described: [[String: Any]] = [
        ["name": "subject", "description": "What a person with this tab open is doing or reading about, in two to five English words, such as a trip to Prague, buying a coffee grinder or a printer driver error"],
        ["name": "city", "description": "The city the tab is about, or none. Only a city the tab itself points to"],
    ]

    static func subject(_ tab: AIGroupTab) async throws -> AIGroupSubject? {
        if let known = AIGroupSubjects.known(tab) { return known }
        let said: [String: Any]
        do {
            said = try await probe(instructions: describing, prompt: tab.localLine, fields: described, most: 60)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AIGroupTrace.note("subject", ["tab": tab.title, "failed": error.localizedDescription])
            AIGroupSubjects.remember(AIGroupSubject(subject: "", city: ""), for: tab)
            return nil
        }
        let found = AIGroupSubject(subject: said["subject"] as? String ?? "", city: said["city"] as? String ?? "")
        AIGroupTrace.note("subject", ["tab": tab.title, "subject": found.subject, "city": found.city, "words": found.words])
        AIGroupSubjects.remember(found, for: tab)
        return found
    }

    static func meant(_ one: AIGroupTab, _ mine: AIGroupSubject, _ two: AIGroupTab, _ theirs: AIGroupSubject) async throws -> Bool {
        let question = "Tab 1: \(one.localLine) — about \(mine.line)\nTab 2: \(two.localLine) — about \(theirs.line)"
        if let known = AIGroupSubjects.verdict(question) { return known }
        var said: [String: Any] = [:]
        do {
            said = try await probe(instructions: judging, prompt: question, fields: verdict, most: 200)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            said = ["link": "no answer: \(error.localizedDescription)"]
        }
        let yes = together.contains(said["link"] as? String ?? "")
        AIGroupTrace.note("judge", ["one": one.title, "two": two.title, "link": said["link"] as? String ?? "",
                                    "thing": said["thing"] as? String ?? "", "together": yes, "by": "subject"])
        AIGroupSubjects.note(question, yes)
        return yes
    }
}
