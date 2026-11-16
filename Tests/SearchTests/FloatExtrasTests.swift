import Foundation
import JavaScriptCore
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FloatExtrasTests {
    @Test func movingDVRRangeUsesAbsoluteTimeAndClampsDiscontinuities() {
        let timeline = FloatTimeline(ranges: [[150, 180], [100, 130], [.nan, 9], [8, 8]], live: true)

        let middle = timeline.target(0.5)
        let shifted = FloatTimeline(ranges: [[110, 190]], live: true)

        #expect(timeline.start == 100)
        #expect(timeline.end == 180)
        #expect(middle == 130)
        #expect(timeline.target(1) == 180)
        #expect(timeline.clamp(90) == 100)
        #expect(timeline.fraction(120) == 0.25)
        #expect(shifted.fraction(130) == 0.25)
        #expect(FloatTimeline(live: true).target(1) == nil)
    }

    @Test func snapshotFiltersBadCuesAndDelaysWaiting() {
        var value: [String: Any] = ["waiting": 0.399, "current": 120.0, "live": true,
                                  "ranges": [[100.0, 160.0]], "chapters": [
                                    ["start": 100.0, "end": 130.0, "name": "First"],
                                    ["start": 100.0, "end": 140.0, "name": "Duplicate"],
                                    ["start": Double.infinity, "end": 160.0, "name": "Bad"]]]

        let short = FloatMediaState(value)
        value["waiting"] = 0.4
        let long = FloatMediaState(value)

        #expect(!short.waiting)
        #expect(long.waiting)
        #expect(long.chapters.count == 1)
        #expect(long.timeline.live)
        #expect((long.timeline.end - long.current) == 40)
    }

    @Test func captionToggleLanguageSelectionAndMissingTracks() {
        let context = JSContext()!
        context.evaluateScript("""
        var video = { textTracks: [
          {kind:'subtitles',label:'English',language:'en',mode:'disabled'},
          {kind:'captions',label:'Polski',language:'pl',mode:'disabled'},
          {kind:'chapters',mode:'hidden'} ] };
        var document = {querySelector: function () {return video;}};
        """)

        context.evaluateScript(Isolate.captions(nil))
        let first = context.evaluateScript("video.textTracks[0].mode")!.toString()
        context.evaluateScript(Isolate.captions(1))
        let second = context.evaluateScript("video.textTracks[1].mode")!.toString()
        context.evaluateScript(Isolate.captions(nil))

        #expect(context.exception == nil)
        #expect(first == "showing")
        #expect(second == "showing")
        #expect(context.evaluateScript("video.textTracks[0].mode")!.toString() == "disabled")
        #expect(context.evaluateScript("video.textTracks[1].mode")!.toString() == "disabled")
        #expect(context.evaluateScript("video.textTracks[2].mode")!.toString() == "hidden")
        #expect(!context.evaluateScript(Isolate.captions(2))!.toBool())
        context.evaluateScript("video=null")
        #expect(!context.evaluateScript(Isolate.captions(nil))!.toBool())
        #expect(FloatCommand.read(code: 8, flags: []) == .captions)
        #expect(FloatCommand.read(code: 8, flags: .command) == nil)
        #expect(FloatCommand.read(code: 8, flags: [], repeated: true) == nil)
    }

    @Test func mediaScriptReadsTracksAndStallRecoveryWithoutChangingRate() {
        let context = JSContext()!
        context.evaluateScript("""
        var now = 0, performance = {now:function(){return now;}};
        var events = {};
        var video = {readyState:4, paused:false, ended:false, duration:Infinity, currentTime:120, playbackRate:1.04,
          seekable:{length:2,start:function(i){return [100,150][i];},end:function(i){return [130,180][i];}},
          textTracks:[{kind:'chapters',mode:'disabled',cues:[{startTime:100,endTime:130,text:'<b>Opening</b>'}]}],
          addEventListener:function(name, handler){events[name]=handler;}};
        var window = {}, document = {querySelector:function(){return video;}};
        """)

        let initial = context.evaluateScript(Isolate.media)!
        context.evaluateScript("video.readyState=2; events.waiting(); now=399")
        let short = context.evaluateScript(Isolate.media)!
        context.evaluateScript("now=400")
        let long = context.evaluateScript(Isolate.media)!
        context.evaluateScript("video.readyState=4; events.playing()")
        let recovered = context.evaluateScript(Isolate.media)!

        #expect(context.exception == nil)
        #expect(initial.forProperty("chapters")!.atIndex(0)!.forProperty("name")!.toString() == "Opening")
        #expect(context.evaluateScript("video.textTracks[0].mode")!.toString() == "hidden")
        #expect(short.forProperty("waiting")!.toDouble() < 0.4)
        #expect(long.forProperty("waiting")!.toDouble() == 0.4)
        #expect(recovered.forProperty("waiting")!.toDouble() == 0)
        #expect(context.evaluateScript("video.playbackRate")!.toDouble() == 1.04)
        #expect(initial.forProperty("live")!.toBool())
    }

    @Test func seekAndSkipUseRangesWithGapsAndIgnoreMissingRange() {
        let context = JSContext()!
        context.evaluateScript("""
        var video = {duration:Infinity,currentTime:120,
          seekable:{length:2,start:function(i){return [100,150][i];},end:function(i){return [130,180][i];}}};
        var document = {querySelector:function(){return video;}};
        """)

        context.evaluateScript(Isolate.seek(0.5))
        let gap = context.evaluateScript("video.currentTime")!.toDouble()
        context.evaluateScript(Isolate.skip(500))
        let edge = context.evaluateScript("video.currentTime")!.toDouble()
        context.evaluateScript("video.seekable.length=0")
        let missing = context.evaluateScript(Isolate.seek(1))!.toBool()

        #expect(context.exception == nil)
        #expect(gap == 130)
        #expect(edge == 180)
        #expect(!missing)
        #expect(context.evaluateScript("video.currentTime")!.toDouble() == 180)
    }
}
