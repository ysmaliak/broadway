import Foundation

struct ChatTrouble: Equatable {
    enum Kind: String {
        case signedOut, usedUp, offline, notInstalled, other
    }

    let kind: Kind
    let title: String
    let detail: String

    @MainActor
    init(_ message: ChatMessage, offline: Bool? = nil, now: Date = Date()) {
        let plan = message.model?.plan ?? .claude
        let limit = Plans.shared.limits[plan]
        self.init(failed: message.failed ?? "", plan: plan,
                  ranOut: Plans.shared.ranOut[plan] != nil || limit?.out == true,
                  resets: limit?.resets,
                  offline: offline ?? (NetworkPath.shared.available == false), now: now)
    }

    init(failed: String, plan: Plan, ranOut: Bool, resets: Date?, offline: Bool, now: Date = Date()) {
        let tool = plan.tool
        let lower = failed.lowercased()
        let signIn = ["isn't signed in", "not logged in", "please run /login", "invalid api key", "unauthorized", "authentication"]
        let limits = ["usage limit", "rate limit", "hit your limit", "limit reached", "quota", "credit balance",
                      "usage_limit_reached", "rate_limit", "insufficient_quota", "has run out"]
        let network = ["offline", "internet connection", "network connection", "network is down", "could not resolve",
                       "timed out", "nsurlerrordomain", "enotfound", "econnrefused", "econnreset", "connection was lost"]
        if lower.contains("isn't installed") || lower.contains("not installed") || lower.contains("command not found") {
            kind = .notInstalled
            title = "\(tool) isn't installed on this Mac"
            detail = plan == .thisMac ? "Pick another agent at the top" : "Install it, or pick another agent at the top"
        } else if signIn.contains(where: lower.contains) {
            kind = .signedOut
            title = "\(tool) is signed out"
            detail = plan.signIn.isEmpty ? "Sign in again, then try again" : "Run \(plan.signIn) in Terminal, then try again"
        } else if ranOut || limits.contains(where: lower.contains) {
            kind = .usedUp
            title = "\(tool) has used up its allowance for now"
            if let resets, resets > now {
                detail = "It comes back \(ChatTrouble.when(resets, now: now)). Try again then, or pick another agent at the top."
            } else {
                detail = "Try again later, or pick another agent at the top"
            }
        } else if offline || network.contains(where: lower.contains) {
            kind = .offline
            title = "This Mac is offline"
            detail = "Connect to the internet, then try again"
        } else {
            kind = .other
            title = "\(tool) couldn't answer"
            detail = ChatTrouble.said(failed) ?? "Try again"
        }
    }

    static func when(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        return "on \(date.formatted(.dateTime.weekday(.wide).day().month(.wide))) at \(time)"
    }

    static func said(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard line.count >= 4, line.filter(\.isLetter).count >= 4, !line.contains("{") else { return nil }
        let cut = line.count > 160 ? String(line.prefix(159)) + "…" : line
        return cut.replacingOccurrences(of: ";", with: ",")
    }
}
