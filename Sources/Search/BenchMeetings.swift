import AppKit

extension Bench {
    func meetingAlertCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let alerts = MeetingAlerts.shared
        let prefs = MeetingAlertPrefs.shared
        func state() -> [String: Any] {
            let now = Date()
            return [
                "running": alerts.running, "on": prefs.on, "access": Meetings.shared.hasAccess, "lead": prefs.lead.rawValue,
                "reads": alerts.reads, "shown": alerts.panelShown,
                "fireIn": alerts.fireAt.map { $0.timeIntervalSince(now) } ?? -1,
                "frame": [alerts.panelFrame.minX, alerts.panelFrame.minY, alerts.panelFrame.width, alerts.panelFrame.height],
                "opened": alerts.opened.map(\.absoluteString),
                "next": Meetings.shared.next?.event.title ?? "",
                "pinLabel": browser.pinLabel(for: Meetings.shared.next, at: now).map { $0 == .join ? "join" : $0.text } ?? "",
                "pinSaid": browser.pinLabel(for: Meetings.shared.next, at: now)
                    .map { $0.said(title: Meetings.shared.next?.event.title ?? "") } ?? "",
                "badge": Bench.meetingBadge.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
                "tile": Bench.meetingTile.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
                "due": alerts.due.map { meeting -> [String: Any] in
                    ["title": meeting.event.title, "key": meeting.alertKey, "link": meeting.link?.absoluteString ?? "",
                     "service": meeting.service?.rawValue ?? "", "pending": meeting.event.pending,
                     "respond": MeetingAlertRules.reply(for: meeting.event)?.absoluteString ?? "",
                     "people": meeting.event.people.map(MeetingAlertRules.initials)]
                },
            ]
        }
        let action = request["action"] as? String ?? "state"
        guard action == "state" || Store.testing else { answer(["error": "meeting alert changes only work on a --test run"]); return }
        switch action {
        case "state":
            answer(state())
        case "fixture":
            let now = Date()
            let events = (request["events"] as? [[String: Any]] ?? []).enumerated().map { index, given -> CalendarEvent in
                let start = now.addingTimeInterval((given["in"] as? Double ?? 1) * 60)
                let people = (given["people"] as? [[String: String]] ?? []).map { MeetingPerson(name: $0["name"] ?? "", email: $0["email"] ?? "") }
                return CalendarEvent(id: given["id"] as? String ?? "alert-\(index)", title: given["title"] as? String ?? "Meeting",
                                     start: start, end: start.addingTimeInterval((given["minutes"] as? Double ?? 30) * 60),
                                     allDay: given["allDay"] as? Bool ?? false, declined: given["declined"] as? Bool ?? false,
                                     location: given["location"] as? String ?? "", notes: given["notes"] as? String ?? "",
                                     url: (given["link"] as? String).flatMap(URL.init(string:)), people: people,
                                     pending: given["pending"] as? Bool ?? false, calendar: given["calendar"] as? String ?? "work",
                                     external: given["external"] as? String ?? "", account: given["account"] as? String ?? "")
            }
            MeetingLink.testHosts = (request["hosts"] as? [String: String] ?? [:]).compactMapValues { name in
                MeetingLink.Service.allCases.first { $0.name == name }
            }
            if let lead = (request["lead"] as? String).flatMap(MeetingLead.init) { prefs.lead = lead }
            prefs.skipped = Set(request["skip"] as? [String] ?? [])
            prefs.chosen = request["on"] as? Bool ?? true
            alerts.forgetOpened()
            Meetings.testCalendars = Set(request["calendars"] as? [String] ?? [])
            Meetings.shared.use(FixedCalendar(events: events))
            alerts.sync()
            alerts.reread()
            Task { @MainActor in
                await Meetings.shared.refresh()
                await alerts.reading?.value
                answer(state())
            }
        case "press":
            let index = request["index"] as? Int ?? 0
            guard alerts.due.indices.contains(index) else { answer(["error": "no alert \(index)"]); return }
            let meeting = alerts.due[index]
            switch request["button"] as? String ?? "join" {
            case "join": alerts.join(meeting, in: browser)
            case "dismiss": alerts.dismiss(meeting)
            case "snooze": alerts.snooze(meeting)
            case "respond": alerts.respond(meeting, in: browser)
            default: answer(["error": "press join, dismiss, snooze or respond"]); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { answer(state()) }
        case "set":
            if let on = request["on"] as? Bool { prefs.chosen = on }
            if let lead = (request["lead"] as? String).flatMap(MeetingLead.init) { prefs.lead = lead }
            if let skip = request["skip"] as? [String] { prefs.skipped = Set(skip) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                Task { @MainActor in
                    await alerts.reading?.value
                    answer(state())
                }
            }
        case "changed":
            NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
            Task { @MainActor in
                await alerts.reading?.value
                answer(state())
            }
        case "shot-start":
            answer(alerts.shot(dark: request["dark"] as? Bool ?? false) ?? ["error": "no alert to capture"])
        case "shot-take":
            alerts.takeShot { png in answer(["png": png?.base64EncodedString() ?? ""]) }
        case "render":
            answer(["png": alerts.render(dark: request["dark"] as? Bool ?? false)?.base64EncodedString() ?? ""])
        case "shot-end":
            alerts.endShot()
            answer(state())
        case "off":
            Meetings.shared.use(nil)
            MeetingLink.testHosts = [:]
            Meetings.testCalendars = []
            alerts.sync()
            answer(state())
        default:
            answer(["error": "meetalert state|fixture|press|set|changed|shot-start|shot-take|shot-end|render|off"])
        }
    }
}
