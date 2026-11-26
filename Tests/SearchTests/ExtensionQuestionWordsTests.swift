import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct ExtensionQuestionWordsTests {
    @Test func aQuestionAskedWhileRunningUsesTheSentencesOfTheInstallQuestion() {
        let detail = Extensions.abilities(named: ["tabs", "cookies"])

        #expect(detail == "It will be able to:\n• Read and change cookies\n• See your open tabs and their addresses")
    }

    @Test func permissionsBroadwayAnswersItselfReadAsSentencesToo() {
        let detail = Extensions.abilities(named: ["history", "downloads.open"])

        #expect(detail == "It will be able to:\n• Open files it downloads\n• Read and change your history")
    }

    @Test func twoPermissionsWithOneMeaningAreSaidOnce() {
        let detail = Extensions.abilities(named: ["declarativeNetRequest", "declarativeNetRequestWithHostAccess"])

        #expect(detail == "It will be able to:\n• Block or change requests pages make")
    }

    @Test func aPermissionWithNoSentenceKeepsItsNameWithoutDots() {
        #expect(Extensions.sentence(for: "system.storage") == "system storage")
    }
}
