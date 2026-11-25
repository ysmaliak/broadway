import Darwin
import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(5)))
struct PlaceTests {
    private let binary = "/Applications/Broadway.app/Contents/Helpers/broadway"
    private let ssh = ["SSH_CONNECTION": "192.0.2.5 50000 192.0.2.9 22"]

    @Test func overSshACommandDoesNotStartBroadwayButSaysWhatToRun() {
        let place = Place.resolve(socket: nil, world: nil, environment: ssh, binary: binary)

        let why = place.whyNot(boxed: { _ in false }, elsewhere: { nil })

        #expect(place.overSSH)
        #expect(why?.code == "not_running")
        #expect(why?.message == "Broadway isn't running, and a command over ssh doesn't start it")
        #expect(why?.hint?.contains("broadway serve") == true)
    }

    @Test func serveStartsBroadwayOverSsh() {
        var place = Place.resolve(socket: nil, world: nil, environment: ssh, binary: binary)
        place.starting = true

        #expect(place.whyNot(boxed: { _ in false }, elsewhere: { nil }) == nil)
    }

    @Test func onThisMacACommandStillStartsBroadway() {
        let place = Place.resolve(socket: nil, world: nil, environment: [:], binary: binary)

        #expect(!place.overSSH)
        #expect(place.whyNot(boxed: { _ in false }, elsewhere: { "sam" }) == nil)
    }

    @Test func overSshBroadwayOfAnotherUserIsNamed() {
        let place = Place.resolve(socket: nil, world: nil, environment: ssh, binary: binary)

        let why = place.whyNot(boxed: { _ in false }, elsewhere: { "sam" })

        #expect(why?.code == "other_user")
        #expect(why?.message.contains("sam") == true)
        #expect(why?.hint?.hasPrefix("Run broadway as sam") == true)
    }

    @Test func aSocketInAnotherUsersFolderIsTheirsNotASandbox() {
        let owners: [String: uid_t] = ["/Users/sam/Library": 502, "/Users/sam": 502, "/Users": 0]

        let found = Place.foreignOwner("/Users/sam/Library/Application Support/Broadway/broadway.sock", owner: { owners[$0] }, me: 501) { $0 == 502 ? "sam" : nil }
        let mine = Place.foreignOwner("/Users/me/Library/Application Support/Broadway/broadway.sock", owner: { $0.hasPrefix("/Users/me") ? 501 : 0 }, me: 501) { _ in "me" }
        let system = Place.foreignOwner("/var/run/broadway.sock", owner: { _ in 0 }, me: 501) { _ in "root" }

        #expect(found == "sam")
        #expect(mine == nil)
        #expect(system == nil)
    }

    @Test func broadwayOfAnotherUserIsFoundByItsProcess() {
        let apps: [(uid: uid_t, name: String)] = [(501, "Broadway"), (502, "Finder"), (503, "Broadway")]

        let found = Place.runningElsewhere(apps: { apps }, me: 501) { $0 == 503 ? "kim" : nil }
        let none = Place.runningElsewhere(apps: { [(501, "Broadway")] }, me: 501) { _ in nil }

        #expect(found == "kim")
        #expect(none == nil)
    }

    @Test func theSandboxHintNamesCodexsSetting() {
        let place = Place.resolve(socket: nil, world: nil, environment: [:], binary: binary)

        #expect(place.sandboxed.hint?.contains("sandbox_workspace_write.network_access = true") == true)
    }

    @Test func doctorNamesTheBroadwayThatAnswersWhenItIsAnotherCopy() {
        let paths = Setup.Paths(home: NSTemporaryDirectory() + "place-\(UUID().uuidString)")

        let other = Setup.checks(paths: paths, binary: binary, environment: [:], status: ["app": "/Users/me/build/Broadway.app"], running: true).first { $0.name == "running" }
        let same = Setup.checks(paths: paths, binary: binary, environment: [:], status: ["app": "/Applications/Broadway.app"], running: true).first { $0.name == "running" }
        let away = Setup.checks(paths: paths, binary: binary, environment: ssh, status: nil, running: false)

        #expect(other?.detail == "Broadway at /Users/me/build/Broadway.app is answering")
        #expect(same?.detail == "Broadway is answering")
        #expect(away.first { $0.name == "running" }?.fix == "Run broadway serve to start it hidden and keep it open")
        #expect(away.first { $0.name == "ssh login" }?.detail.contains("192.0.2.5") == true)
    }

    @Test func theSshCheckAsksANonInteractiveShellWithTheBarePathSshGives() throws {
        let folder = NSTemporaryDirectory() + "shell-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let finds = folder + "/finds"
        let misses = folder + "/misses"
        try "#!/bin/sh\n[ \"$1\" = -c ] && [ \"$PATH\" = /usr/bin:/bin:/usr/sbin:/sbin ] && [ -n \"$SSH_CONNECTION\" ] && echo /Users/me/.local/bin/broadway\n".write(toFile: finds, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 1\n".write(toFile: misses, atomically: true, encoding: .utf8)
        chmod(finds, 0o755)
        chmod(misses, 0o755)

        #expect(Setup.sshFinds(shell: finds))
        #expect(!Setup.sshFinds(shell: misses))
        #expect(!Setup.sshFinds(shell: nil))
    }
}
