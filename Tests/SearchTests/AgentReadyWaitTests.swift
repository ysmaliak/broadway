import Foundation
import Testing
@testable import Search

@Suite
struct AgentReadyWaitTests {
    @Test func waitsForWhatCanChange() {
        for reason in ["hidden", "disabled", "moving"] {
            #expect(AgentReadyWait.waits(["failed": "x", "code": "not_actionable", "reason": reason]))
        }
        #expect(AgentReadyWait.waits(["failed": "x", "code": "not_actionable", "reason": "covered", "by": ["buttons": [Any](), "cookies": false]]))
        #expect(!AgentReadyWait.waits(["failed": "x", "code": "not_actionable", "reason": "covered", "by": ["buttons": [["ref": "e3", "name": "Close"]], "cookies": false]]))
        #expect(!AgentReadyWait.waits(["failed": "x", "code": "not_actionable", "reason": "covered", "by": ["buttons": [Any](), "cookies": true]]))
        #expect(!AgentReadyWait.waits(["failed": "x", "code": "not_actionable", "reason": "outside"]))
        #expect(!AgentReadyWait.waits(["failed": "x", "code": "not_actionable", "reason": "readonly"]))
        #expect(!AgentReadyWait.waits(["failed": "x", "code": "stale_ref"]))
        #expect(!AgentReadyWait.waits(["ok": true]))
    }

    @Test func saysWhatItWaitedFor() {
        let what = "@e3 button \"Pay\""
        #expect(AgentReadyWait.told(["failed": what + " is disabled", "what": what], seconds: 3)["failed"] as? String == "Waited 3 s. @e3 button \"Pay\" stayed disabled")
        #expect(AgentReadyWait.told(["failed": what + " is moving", "what": what], seconds: 5)["failed"] as? String == "Waited 5 s. @e3 button \"Pay\" kept moving")
        #expect(AgentReadyWait.told(["failed": what + " is covered by element \"\"", "what": what], seconds: 3)["failed"] as? String == "Waited 3 s. @e3 button \"Pay\" stayed covered by element \"\"")
    }

    @Test func settleRaisesTheBound() {
        #expect(AgentReadyWait.patience([:]) == 3)
        #expect(AgentReadyWait.patience(["settle": 0]) == 3)
        #expect(AgentReadyWait.patience(["settle": 8]) == 8)
        #expect(AgentReadyWait.patience(["settle": 300]) == AgentSettleRule.longest)
        #expect(AgentReadyWait.patience(["settle": true]) == 3)
    }
}
