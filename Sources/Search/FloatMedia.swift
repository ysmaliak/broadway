import Foundation

extension Isolate {
    static func rate(_ value: Double) -> String {
        guard FloatRate.steps.contains(value) || Tempo.allows(value) else { return "null" }
        return """
        (function () {
          var video = document.querySelector('[data-office-float]') || document.querySelector('video');
          if (!video || !video.readyState) return null;
          try { video.dispatchEvent(new CustomEvent('\(Tempo.rateEvent)', { detail: '\(value)' })); } catch (e) {}
          try {
            video.playbackRate = \(value);
            return video.playbackRate;
          } catch (e) { return null; }
        })();
        """
    }

    static let mute = """
    (function () {
      var video = document.querySelector('[data-office-float]') || document.querySelector('video');
      if (!video) return false;
      video.muted = !video.muted;
      return video.muted;
    })();
    """
}

extension Isolate {
    static let mediaRange = """
    function ranges(video) {
      var result = [];
      for (var i = 0; i < video.seekable.length; i++) {
        var start = video.seekable.start(i), end = video.seekable.end(i);
        if (isFinite(start) && isFinite(end) && start >= 0 && end > start) result.push([start, end]);
      }
      return result;
    }
    function clamp(time, list) {
      var closest = null, distance = Infinity;
      list.forEach(function (range) {
        if (time >= range[0] && time <= range[1]) { closest = time; distance = 0; }
        range.forEach(function (edge) {
          if (Math.abs(time - edge) < distance) { closest = edge; distance = Math.abs(time - edge); }
        });
      });
      return closest;
    }
    """

    static let media = """
    (function () {
      var video = document.querySelector('[data-office-float]') || document.querySelector('video');
      if (!video || !video.readyState) return {};
      \(mediaRange)
      var watchers = window.__broadwayFloatWatchers || (window.__broadwayFloatWatchers = new WeakMap());
      var state = watchers.get(video);
      if (!state) {
        state = { since: null };
        watchers.set(video, state);
        ['waiting', 'stalled'].forEach(function (event) {
          video.addEventListener(event, function () {
            if (!video.paused && video.readyState < 3 && state.since === null) state.since = performance.now();
          });
        });
        ['playing', 'pause', 'ended', 'emptied'].forEach(function (event) {
          video.addEventListener(event, function () { state.since = null; });
        });
      }
      if (video.paused || video.ended || video.readyState >= 3) state.since = null;
      else if (state.since === null) state.since = performance.now();
      var captions = [], chapters = [];
      Array.from(video.textTracks || []).forEach(function (track, index) {
        if (track.kind === 'subtitles' || track.kind === 'captions') {
          captions.push({ id: index, name: track.label || track.language || 'Track ' + (captions.length + 1), selected: track.mode === 'showing' });
        }
        if (track.kind === 'chapters') {
          if (track.mode === 'disabled') track.mode = 'hidden';
          Array.from(track.cues || []).forEach(function (cue) {
            chapters.push({ start: cue.startTime, end: cue.endTime, name: String(cue.text || '').replace(/<[^>]*>/g, '') });
          });
        }
      });
      return { current: video.currentTime, playing: !video.paused || video.hasAttribute('\(Tempo.holdMark)'), rate: video.playbackRate,
        ranges: ranges(video), live: video.duration === Infinity, captions: captions, chapters: chapters,
        waiting: state.since === null ? 0 : (performance.now() - state.since) / 1000 };
    })();
    """

    static func captions(_ selection: Int?) -> String {
        let action = selection.map(String.init) ?? "null"
        return """
        (function () {
          var video = document.querySelector('[data-office-float]') || document.querySelector('video');
          if (!video) return false;
          var tracks = Array.from(video.textTracks || []), choice = \(action);
          var captions = tracks.filter(function (track) { return track.kind === 'subtitles' || track.kind === 'captions'; });
          if (choice === null) {
            var active = captions.some(function (track) { return track.mode === 'showing'; });
            choice = active || !captions.length ? -1 : tracks.indexOf(captions[0]);
          }
          if (choice !== -1 && (!tracks[choice] || captions.indexOf(tracks[choice]) < 0)) return false;
          captions.forEach(function (track) { track.mode = tracks.indexOf(track) === choice ? 'showing' : 'disabled'; });
          return true;
        })();
        """
    }
}
