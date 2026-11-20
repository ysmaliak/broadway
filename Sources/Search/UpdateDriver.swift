import AppKit
import Sparkle

@MainActor
final class UpdateDriver: NSObject, SPUUserDriver {
    let flow: UpdateFlow

    init(flow: UpdateFlow) {
        self.flow = flow
        super.init()
    }

    static func choice(_ choice: UpdateChoice) -> SPUUserUpdateChoice {
        switch choice {
        case .install: return .install
        case .dismiss: return .dismiss
        case .cancel: return .skip
        }
    }

    static func stage(_ stage: SPUUserUpdateStage) -> UpdateStage {
        switch stage {
        case .downloaded: return .downloaded
        case .installing: return .installing
        default: return .notDownloaded
        }
    }

    static func found(_ item: SUAppcastItem) -> UpdateFound {
        UpdateFound(version: item.displayVersionString, build: item.versionString)
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        flow.checkStarted()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        var answered = false
        flow.found(Self.found(appcastItem), stage: Self.stage(state.stage), informational: appcastItem.isInformationOnlyUpdate) { choice in
            guard !answered else { return }
            answered = true
            reply(Self.choice(choice))
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        flow.notFound()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        flow.failed(UpdateWords.reason(error))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        flow.downloadStarted()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        flow.expect(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        flow.receive(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        flow.extractStarted()
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        var answered = false
        flow.ready { choice in
            guard !answered else { return }
            answered = true
            reply(Self.choice(choice))
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        flow.installing()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {}
}
