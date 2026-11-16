import Foundation

extension AgentLinks {
    static func actPass(_ act: AgentAct, site: String?, quote: String) -> String {
        "act|\(act.rawValue)|\(site ?? "")|\(AgentQuestion.clean(quote))"
    }

    func giveActPass(_ session: UUID, _ act: AgentAct, site: String?, quote: String, at now: Date = Date()) {
        givePass(session, Self.actPass(act, site: site, quote: quote), at: now)
    }

    func takeActPass(_ session: UUID, _ act: AgentAct, site: String?, quote: String, at now: Date = Date()) -> Bool {
        takePass(session, Self.actPass(act, site: site, quote: quote), at: now)
    }

    private static var refusals: [String: Date] = [:]

    func noteRefusal(_ session: UUID, _ act: AgentAct, site: String?, quote: String, at now: Date = Date()) {
        Self.refusals["\(session.uuidString)|\(Self.actPass(act, site: site, quote: quote))"] = now
    }

    func refusedLately(_ session: UUID, _ act: AgentAct, site: String?, quote: String, at now: Date = Date()) -> Bool {
        guard let when = Self.refusals["\(session.uuidString)|\(Self.actPass(act, site: site, quote: quote))"] else { return false }
        return now.timeIntervalSince(when) <= Self.passLife
    }
}
