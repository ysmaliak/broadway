import AppKit
import JavaScriptCore
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FloatRateTests {
    @Test func noVideoRefusesChangesAndInvalidRatesDisableTheControl() {
        var rate = FloatRate()

        let picked = rate.pick(1.5, at: 1)
        rate.polled(.nan, at: 2)

        #expect(!picked)
        #expect(!rate.available)
        #expect(rate.value == 1)
    }

    @Test func everyStepAndCycleBoundary() {
        var rate = FloatRate()
        rate.polled(0.5, at: 0)
        var values: [Double] = [rate.value]

        for tick in 1...6 {
            _ = rate.pick(rate.step(1), at: Double(tick))
            values.append(rate.value)
        }

        #expect(values == FloatRate.steps)
        #expect(rate.step(1) == 2)
        #expect(rate.step(1, wrapping: true) == 0.5)
        #expect(rate.step(-1) == 1.75)
    }

    @Test func stalePollCannotUndoAPickAndLaterPageChangesAreReflected() {
        var rate = FloatRate()
        rate.polled(1, at: 0)

        _ = rate.pick(1.5, at: 1)
        rate.polled(1, at: 1.1)
        let immediate = rate.value
        rate.polled(1.25, at: 2)

        #expect(immediate == 1.5)
        #expect(rate.value == 1.25)
    }

    @Test func catchUpAndOffGridRatesStepWithoutRoundingAwayTheCurrentRate() {
        var rate = FloatRate()

        rate.polled(1.04, at: 0)
        let up = rate.step(1), down = rate.step(-1)
        rate.polled(1.0001, at: 1)

        #expect(up == 1.25)
        #expect(down == 1)
        #expect(rate.value == 1)
        #expect(FloatRate.label(rate.value) == "1.0×")
    }

    @Test func missingVideoClearsPendingPickAndUnsupportedChoiceIsIgnored() {
        var rate = FloatRate()
        rate.polled(1, at: 0)
        _ = rate.pick(2, at: 1)

        rate.polled(nil, at: 1.1)
        let missing = rate.available
        rate.polled(0.75, at: 1.2)
        let invalid = rate.pick(3.5, at: 1.3)

        #expect(!missing)
        #expect(!invalid)
        #expect(rate.value == 0.75)
    }

    @Test func floatRateUsesThePageSetterAndPreservesLiveSmoothing() {
        let context = JSContext()!
        context.evaluateScript("""
        var HTMLMediaElement = function () { this.real = 1; this.readyState = 4; };
        Object.defineProperty(HTMLMediaElement.prototype, 'playbackRate', {
          get: function () { return this.real; },
          set: function (rate) { this.real = rate; }, configurable: true
        });
        var video = new HTMLMediaElement();
        var document = { querySelector: function () { return video; } };
        """)
        context.evaluateScript(LiveRate.script)

        context.evaluateScript(Isolate.rate(1.5))
        context.evaluateScript(Isolate.rate(1))
        let menuReturn = context.evaluateScript("video.real")!.toDouble()
        context.evaluateScript("video.playbackRate = 1.04")
        context.evaluateScript(Isolate.rate(2))
        context.evaluateScript(Isolate.rate(1))

        #expect(context.exception == nil)
        #expect(menuReturn == 1)
        #expect(context.evaluateScript("video.real")!.toDouble() == 1.0001)
        #expect(context.evaluateScript("video.playbackRate")!.toDouble() == 1)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FloatCommandTests {
    @Test func physicalKeysWorkWithRussianCharactersAndArrowFunctionFlags() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "ь", charactersIgnoringModifiers: "ь",
                                    isARepeat: false, keyCode: 46)!

        let mute = FloatCommand.read(code: event.keyCode, flags: event.modifierFlags)
        let seek = FloatCommand.read(code: 124, flags: [.function, .numericPad, .shift])

        #expect(mute == .mute)
        #expect(seek == .seek(5))
        #expect(FloatCommand.read(code: 123, flags: []) == .seek(-15))
        #expect(FloatCommand.read(code: 43, flags: .shift) == .speed(-1))
        #expect(FloatCommand.read(code: 47, flags: .shift) == .speed(1))
    }

    @Test func browserChordsAndTypingAreNeverHandled() {
        let codes: [UInt16] = [49, 123, 124, 43, 47, 46, 36, 53]

        let chords = codes.flatMap { code in
            [NSEvent.ModifierFlags.command, .control, .option].map { FloatCommand.read(code: code, flags: $0) }
        }

        #expect(chords.allSatisfy { $0 == nil })
        #expect(FloatCommand.read(code: 0, flags: []) == nil)
        #expect(FloatCommand.read(code: 43, flags: []) == nil)
        #expect(FloatCommand.read(code: 49, flags: [], repeated: true) == nil)
        #expect(FloatCommand.read(code: 36, flags: []) == .back)
        #expect(FloatCommand.read(code: 53, flags: []) == .back)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FloatFeedbackTests {
    @Test func keyboardFeedbackNeverPretendsThePointerEntered() {
        var reveal = FloatReveal()

        reveal.signal(at: 10, for: 1.3)
        let deadline = reveal.deadline
        reveal.tick(at: 11.3)

        #expect(!reveal.inside)
        #expect(abs((deadline ?? 0) - 11.3) <= 0.001)
        #expect(!reveal.shown)
    }
}
