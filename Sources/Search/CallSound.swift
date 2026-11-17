import Foundation

enum CallSound {
    static let always = "A call always plays sound by itself"

    static func plays(_ url: URL, agent: Bool) -> Bool {
        !agent && MeetingLink.service(of: url) != nil
    }
}
