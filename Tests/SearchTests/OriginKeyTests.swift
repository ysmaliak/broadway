import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct OriginKeyTests {
    @Test func theCameraKeyIsTheOriginEveryOtherPermissionKeeps() {
        #expect(Browser.origin("https", "example.com", 0) == "https://example.com")
        #expect(Browser.origin("http", "shop.example", 8080) == "http://shop.example:8080")
        #expect(Browser.origin("https", "example.com", 8443) == "https://example.com:8443")
        #expect(Browser.origin("webkit-extension", "abcdef", 0) == "webkit-extension://abcdef")
        #expect(Browser.origin("https", "example.com", 443) == "https://example.com")
    }
}
