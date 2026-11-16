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

    private func refusalKeys(_ session: UUID, _ act: AgentAct, site: String?, quote: String) -> [String] {
        let pass = Self.actPass(act, site: site, quote: quote)
        return ["\(session.uuidString)|\(pass)"] + (link(session).map { ["\($0.key)|\(pass)"] } ?? [])
    }

    func noteRefusal(_ session: UUID, _ act: AgentAct, site: String?, quote: String, at now: Date = Date()) {
        for key in refusalKeys(session, act, site: site, quote: quote) { Self.refusals[key] = now }
    }

    func refusedLately(_ session: UUID, _ act: AgentAct, site: String?, quote: String, at now: Date = Date()) -> Bool {
        refusalKeys(session, act, site: site, quote: quote).contains { key in
            Self.refusals[key].map { now.timeIntervalSince($0) <= Self.passLife } == true
        }
    }

    private static var asks: [UUID: Task<AgentAnswer, Never>] = [:]

    func openAsk(_ session: UUID) -> Task<AgentAnswer, Never>? { Self.asks[session] }

    func keepAsk(_ session: UUID, _ asking: Task<AgentAnswer, Never>) { Self.asks[session] = asking }

    func dropAsk(_ session: UUID) { Self.asks[session] = nil }
}
