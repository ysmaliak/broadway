import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct AgentWaitTests {
    @Test func waitingForTextASelectorOrAnAddressGoesTo60SecondsLikeTheOtherForms() {
        #expect(BrowserToolbox.waitCap(90) == 60)
        #expect(BrowserToolbox.waitCap(45) == 45)
        #expect(BrowserToolbox.waitCap(nil) == 10)
        #expect(BrowserToolbox.waitMost == 60)
    }
}
