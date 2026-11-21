import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentPlacesTests {
    private let personal = AgentSpaceName(id: UUID(), name: "Personal")
    private let work = AgentSpaceName(id: UUID(), name: "Work")
    private let home = "/Users/sam"
    private var links: AgentLinks!
    private var front: UUID?

    init() {
        links = AgentLinks()
        links.places = AgentPlaces(store: nil)
        front = work.id
        links.here = { [unowned self] in front }
        links.spaceNames = { [unowned self] in [personal, work] }
    }

    private func choose(_ wish: AgentWish, learned: UUID? = nil, spaces: [AgentSpaceName]? = nil) -> AgentPlace {
        AgentPlaces.choose(wish, spaces: spaces ?? [personal, work], learned: learned, front: work.id, home: home)
    }

    @Test func anExplicitSpaceWinsOverEverythingElse() {
        let wish = AgentWish(folder: "/Users/sam/Projects/personal/broadway", space: " work ")

        let place = choose(wish, learned: personal.id)

        #expect(place == AgentPlace(space: work.id, why: .setting))
    }

    @Test func aLearnedPlaceWinsOverANameMatch() {
        let wish = AgentWish(folder: "/Users/sam/Projects/personal/broadway")

        let place = choose(wish, learned: work.id)

        #expect(place == AgentPlace(space: work.id, why: .learned))
    }

    @Test func aFolderUnderASpacesNameGoesThere() {
        let mine = choose(AgentWish(folder: "/Users/sam/Projects/personal/broadway"))
        let job = choose(AgentWish(folder: "/Users/sam/work/acme"))
        let outside = choose(AgentWish(folder: "/Volumes/Work/site"))

        #expect(mine == AgentPlace(space: personal.id, why: .named("~/Projects/personal")))
        #expect(job == AgentPlace(space: work.id, why: .named("~/work")))
        #expect(outside == AgentPlace(space: work.id, why: .named("/Volumes/Work")))
    }

    @Test func aNameOfSeveralWordsMatchesWithSpacesDashesOrUnderscores() {
        let side = AgentSpaceName(id: UUID(), name: "Side Projects")
        let spaces = [personal, side]

        let found = ["side-projects", "side_projects", "Side Projects", "side--projects"].map {
            choose(AgentWish(folder: "/Users/sam/\($0)/app"), spaces: spaces).space
        }
        let near = choose(AgentWish(folder: "/Users/sam/side/projects"), spaces: spaces)
        let one = choose(AgentWish(folder: "/Users/sam/work-stuff/app"))

        #expect(found == [side.id, side.id, side.id, side.id])
        #expect(near == AgentPlace(space: work.id, why: .front))
        #expect(one == AgentPlace(space: work.id, why: .front))
    }

    @Test func twoSpacesMatchedIsNoMatch() {
        let place = choose(AgentWish(folder: "/Users/sam/work/personal/notes"))

        #expect(place == AgentPlace(space: work.id, why: .front))
    }

    @Test func theHomeFolderItselfNeverMatches() {
        let sam = AgentSpaceName(id: UUID(), name: "Sam")
        let users = AgentSpaceName(id: UUID(), name: "Users")

        let place = choose(AgentWish(folder: "/Users/sam/code/app"), spaces: [sam, users, personal])

        #expect(place == AgentPlace(space: work.id, why: .front))
    }

    @Test func withOneSpaceOrSpacesOffItIsTheFrontAsBefore() {
        let wish = AgentWish(folder: "/Users/sam/personal/app", space: "Personal")

        let one = AgentPlaces.choose(wish, spaces: [personal], learned: personal.id, front: personal.id, home: home)
        let off = AgentPlaces.choose(wish, spaces: nil, learned: personal.id, front: nil, home: home)

        #expect(one == AgentPlace(space: personal.id, why: .front))
        #expect(off == AgentPlace(space: nil, why: .front))
    }

    @Test func aSpaceThatIsGoneFallsThroughToTheNextRule() {
        let wish = AgentWish(folder: "/Users/sam/personal/app", space: "Clients")

        let place = choose(wish, learned: UUID())
        let nothing = choose(AgentWish(space: "Clients"), learned: UUID())

        #expect(place == AgentPlace(space: personal.id, why: .named("~/personal")))
        #expect(nothing == AgentPlace(space: work.id, why: .front))
    }

    @Test func aSessionJoinsInTheChosenSpaceAndKeepsItsFolder() {
        let made = links.join(.named("a"), name: "Claude Code", wish: AgentWish(folder: NSHomeDirectory() + "/Projects/personal/app"))
        let plain = links.join(.named("b"), name: "Codex")

        #expect(made.space == personal.id)
        #expect(made.placed == .named("~/Projects/personal"))
        #expect(made.folder == NSHomeDirectory() + "/Projects/personal/app")
        #expect(plain.space == work.id)
        #expect(plain.placed == .front)
    }

    @Test func aFolderHeardLaterIsKeptButDoesNotMoveTheSession() {
        let made = links.join(.named("a"), name: "Claude Code")

        let again = links.join(.named("a"), name: nil, wish: AgentWish(folder: NSHomeDirectory() + "/personal/app"))

        #expect(again.id == made.id)
        #expect(again.folder == NSHomeDirectory() + "/personal/app")
        #expect(again.space == work.id)
    }

    @Test func aMoveTeachesTheFolderAndTheNextSessionThereFollows() {
        let folder = NSHomeDirectory() + "/Projects/personal/app"
        let first = links.join(.named("a"), name: "Claude Code", wish: AgentWish(folder: folder))
        _ = links.tell(first.id)

        links.settle(first.id, in: work.id, because: .moved)
        let moved = links.link(first.id)
        links.end(first.id, .done(nil))
        let next = links.join(.named("b"), name: "Claude Code", wish: AgentWish(folder: folder))

        #expect(moved?.space == work.id)
        #expect(moved?.placed == .moved)
        #expect(moved?.told == false)
        #expect(links.places.learned(folder) == work.id)
        #expect(next.space == work.id)
        #expect(next.placed == .learned)
    }

    @Test func anExplicitOpenTeachesTheFolderButASessionWithNoFolderWritesNothing() {
        let folder = NSHomeDirectory() + "/code/app"
        let known = links.join(.named("a"), name: "Claude Code", wish: AgentWish(folder: folder))
        let unknown = links.join(.named("b"), name: "Script")

        links.settle(known.id, in: personal.id, because: .asked)
        links.settle(unknown.id, in: personal.id, because: .asked)

        #expect(links.places.learned(folder) == personal.id)
        #expect(links.link(unknown.id)?.space == personal.id)
        #expect(links.link(unknown.id)?.placed == .asked)
    }

    @Test func aMovedTabOfAnEndedSessionStillTeaches() {
        let folder = NSHomeDirectory() + "/code/app"
        let made = links.join(.named("a"), name: "Claude Code", wish: AgentWish(folder: folder))
        links.end(made.id, .done(nil))

        links.settle(made.id, in: personal.id, because: .moved)

        #expect(links.places.learned(folder) == personal.id)
        #expect(links.link(made.id)?.space == work.id)
    }

    @Test func theStoreKeepsTheNewestFolders() {
        let places = AgentPlaces(store: nil)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

        for index in 0...AgentPlaces.most {
            places.learn("/f/\(index)", work.id, at: start.addingTimeInterval(Double(index)))
        }

        #expect(places.learned("/f/0") == nil)
        #expect(places.learned("/f/1") == work.id)
        #expect(places.learned("/f/\(AgentPlaces.most)") == work.id)
    }

    @Test func aSessionIsToldWhereOnceUntilItsSpaceChanges() {
        let made = links.join(.named("a"), name: "Claude Code")

        let first = links.tell(made.id)
        let second = links.tell(made.id)
        links.settle(made.id, in: personal.id, because: .moved)
        let after = links.tell(made.id)

        #expect(first)
        #expect(!second)
        #expect(after)
    }

    @Test func theAnswerSaysWhereAndWhyAndHowToChangeIt() {
        let named: [String: Any] = ["name": "Personal", "why": AgentPlaces.reason(.named("~/Projects/personal"), onScreen: false), "first": true]
        let front: [String: Any] = ["name": "Work", "why": AgentPlaces.reason(.front, onScreen: true), "first": true]
        let asked: [String: Any] = ["name": "Work", "why": AgentPlaces.reason(.asked, onScreen: true), "first": true, "kept": true]
        let later: [String: Any] = ["name": "Work", "why": "the space on screen", "first": false]

        #expect(AgentPlaces.line(named) == "In Personal, matching ~/Projects/personal. Open with space NAME to pick another and keep it for this folder.")
        #expect(AgentPlaces.line(front, how: "Run x") == "In Work, the space on screen. Run x to pick another and keep it for this folder.")
        #expect(AgentPlaces.line(asked) == "In Work, as asked. This folder's tabs go there from now on.")
        #expect(AgentPlaces.line(later) == nil)
        #expect(AgentPlaces.reason(.learned, onScreen: true) == "where this folder's sessions go")
        #expect(AgentPlaces.reason(.front, onScreen: false) == "the space on screen when you connected")
    }

    @Test func aSpaceIsFoundByItsNameOrTheStartOfIt() {
        let spaces = [personal, work, AgentSpaceName(id: UUID(), name: "Workshop")]

        #expect(AgentPlaces.find("work", in: spaces).map(\.id) == [work.id])
        #expect(AgentPlaces.find("pers", in: spaces).map(\.id) == [personal.id])
        #expect(AgentPlaces.find("wo", in: spaces).count == 2)
        #expect(AgentPlaces.find("home", in: spaces).isEmpty)
    }
}
