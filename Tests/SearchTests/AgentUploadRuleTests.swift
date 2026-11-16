import Foundation
import Testing
@testable import Search

@Suite
struct AgentUploadRuleTests {
    private let home = "/Users/sam"
    private let own = "/Users/sam/Library/Application Support/Broadway"
    private let kept = "/Users/sam/Library/Application Support/Broadway/Agent Downloads"

    private func refusal(_ path: String) -> String? {
        AgentUploadRule.refusal(path, home: home, own: own, kept: kept)
    }

    @Test func filesInHomeAndTemporaryFoldersAreGiven() {
        let paths = ["/Users/sam/Desktop/report.pdf", "/Users/sam/Documents/a b/photo.png", "/tmp/out.csv",
                     "/private/var/folders/x1/abc/T/request.certSigningRequest"]

        let refused = paths.compactMap(refusal)

        #expect(refused.isEmpty)
    }

    @Test func hiddenFilesAndDotfoldersAreRefused() {
        let paths = ["/Users/sam/.zshrc", "/Users/sam/.config/app/settings.json", "/Users/sam/Desktop/.env", "/tmp/.secret"]

        let refused = paths.map(refusal)

        #expect(refused.allSatisfy { $0?.contains("Hidden") == true })
    }

    @Test func secretsLibraryAndBroadwaysOwnDataAreRefused() {
        let paths = ["/Users/sam/Library/Keychains/login.keychain-db", "/Users/sam/Library/Preferences/x.plist",
                     "/Users/sam/Library/Application Support/Broadway/History.json", "/Users/sam/Desktop/id_ed25519",
                     "/Users/sam/Desktop/work.keychain"]

        let refused = paths.map(refusal)

        #expect(refused.allSatisfy { $0 != nil })
    }

    @Test func anythingOutsideHomeAndTemporaryFoldersIsRefused() {
        let paths = ["/etc/hosts", "/Volumes/Backup/taxes.pdf", "/Users/alex/Desktop/theirs.pdf", "relative/path.txt"]

        let refused = paths.map(refusal)

        #expect(refused.allSatisfy { $0 != nil })
    }

    @Test func agentDownloadsCanBeGivenOnward() {
        let path = kept + "/Claude Code/certificate.cer"

        let refused = refusal(path)

        #expect(refused == nil)
    }

    @Test func acceptMatchesExtensionsAndTypes() {
        let accept = ".certSigningRequest, image/*, application/pdf"

        let taken = [AgentAccept.takes(accept, name: "req.certsigningrequest", type: "application/octet-stream"),
                     AgentAccept.takes(accept, name: "photo.heic", type: "image/heic"),
                     AgentAccept.takes(accept, name: "doc.pdf", type: "application/pdf"),
                     AgentAccept.takes("", name: "any.bin", type: "application/octet-stream")]
        let refused = AgentAccept.takes(accept, name: "notes.txt", type: "text/plain")

        #expect(taken == [true, true, true, true])
        #expect(!refused)
    }
}
