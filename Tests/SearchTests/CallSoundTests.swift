import Foundation
import Testing
import WebKit
@testable import Search

@Suite
struct CallSoundTests {
    private func url(_ text: String) -> URL { URL(string: text)! }

    private func policy(_ text: String, shy: Bool = false, agent: Bool = false, waits: Bool = false,
                        made: WKAudiovisualMediaTypes = .audio, allowed: Set<String> = []) -> Int? {
        Autoplay.policy(for: url(text), shy: shy, agent: agent, waits: waits, made: made, allowed: { allowed.contains($0) })
    }

    @Test func everyServicesCallAddressPlaysByItself() {
        let calls = [
            "https://meet.google.com/qwe-rtyu-iop",
            "https://example.zoom.us/j/81234567890",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0",
            "https://app.slack.com/huddle/T000/C000",
            "https://example.webex.com/meet/someone",
            "https://around.co/r/standup",
            "https://facetime.apple.com/join#v=1&p=x",
        ]
        for call in calls {
            #expect(CallSound.plays(url(call), agent: false), "\(call)")
            #expect(policy(call) == 1, "\(call)")
        }
    }

    @Test func aServicesOtherPagesAreNotCalls() {
        for page in ["https://meet.google.com/", "https://zoom.us/pricing", "https://teams.microsoft.com/chat",
                     "https://slack.com/intl/en-gb", "https://www.webex.com/pricing", "https://around.co/"] {
            #expect(!CallSound.plays(url(page), agent: false), "\(page)")
            #expect(policy(page) == nil, "\(page)")
        }
    }

    @Test func aCallPlaysWithVideosWaitingForAClick() {
        #expect(policy("https://meet.google.com/qwe-rtyu-iop", waits: true, made: .all) == 1)
        #expect(policy("https://meet.google.com/qwe-rtyu-iop", waits: true, made: .audio) == 1)
        #expect(policy("https://meet.google.com/qwe-rtyu-iop", waits: false, made: .all) == 1)
    }

    @Test func aCallPlaysInAPrivateWindow() {
        #expect(policy("https://meet.google.com/qwe-rtyu-iop", shy: true) == 1)
    }

    @Test func anAgentsTabAtACallAddressIsLeftAsAnyOtherPage() {
        #expect(!CallSound.plays(url("https://meet.google.com/qwe-rtyu-iop"), agent: true))
        #expect(policy("https://meet.google.com/qwe-rtyu-iop", agent: true) == nil)
        #expect(policy("https://meet.google.com/qwe-rtyu-iop", agent: true, waits: true, made: .audio) == 3)
        #expect(policy("https://meet.google.com/qwe-rtyu-iop", agent: true, waits: false, made: .all) == 2)
    }

    @Test func anotherSiteKeepsWhatItHadBefore() {
        #expect(policy("https://news.example.test/story") == nil)
        #expect(policy("https://news.example.test/story", waits: true, made: .audio) == 3)
        #expect(policy("https://news.example.test/story", waits: true, made: .all) == nil)
        #expect(policy("https://news.example.test/story", waits: false, made: .all) == 2)
        #expect(policy("https://news.example.test/story", allowed: ["news.example.test"]) == 1)
        #expect(policy("https://news.example.test/story", shy: true, allowed: ["news.example.test"]) == nil)
        #expect(policy("https://news.example.test/story", waits: true, made: .all, allowed: ["news.example.test"]) == nil)
    }
}
