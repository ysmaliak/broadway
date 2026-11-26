import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct ExtensionRowDetailTests {
    private let item = Installed(id: "row-detail-extension", name: "Row", version: "2", enabled: true, fromStore: true, permissions: [])

    @Test func anExtensionNotYetLoadedWhileBroadwayStartsThemSaysStarting() {
        let detail = ExtensionsLogic.detail(item, nil, Extensions.shared, starting: true, updateTrouble: nil)

        #expect(detail == "Version 2 · Chrome Web Store · Starting")
    }

    @Test func anExtensionStillNotLoadedOnceStartedSaysItCouldNotStart() {
        let detail = ExtensionsLogic.detail(item, nil, Extensions.shared, starting: false, updateTrouble: nil)

        #expect(detail == "Version 2 · Chrome Web Store · couldn't start")
    }

    @Test func aStoreReplyWithoutAnUpdateCheckIsNotAnAnswer() {
        let page = Data("<html><body>Sign in to the network</body></html>".utf8)

        #expect(Extensions.updateCheck(in: page) == nil)
    }

    @Test func aStoreReplySayingNoUpdateIsAnAnswer() {
        let reply = Data(#"<?xml version="1.0"?><gupdate><app appid="abc" status="ok"><updatecheck status="noupdate"/></app></gupdate>"#.utf8)

        #expect(Extensions.updateCheck(in: reply) == #"<updatecheck status="noupdate"/>"#)
    }

    @Test func aFailedUpdateShowsInTheRowWithItsReason() {
        let off = Installed(id: "row-detail-extension", name: "Row", version: "2", enabled: false, fromStore: true, permissions: [])

        let detail = ExtensionsLogic.detail(off, nil, Extensions.shared, starting: false, updateTrouble: "The extension's signature doesn't hold up")

        #expect(detail == "Version 2 · Chrome Web Store · Couldn't update: The extension's signature doesn't hold up")
    }
}
