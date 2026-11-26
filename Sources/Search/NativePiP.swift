import WebKit

/// The floating video as macOS's own picture in picture, for whoever picks
/// it in Settings › General › The floating video (idea 376). Search's own
/// window (Float.swift) stays the default: it floats without a click and
/// keeps the page alive in it. This hands the playing video to WebKit's
/// picture in picture instead, the window Safari uses, with the system's
/// controls, its corners and its place across spaces.
///
/// WebKit wants a user gesture for it. A script the app runs in a page
/// counts as one (WKWebView's evaluateJavaScript is run with the gesture
/// forced), so ⇧⌘P and leaving the tab or the app can ask; a page that
/// refuses anyway says so through `answer`.
enum FloatStyle: String, CaseIterable, Identifiable {
    case search, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: return "Broadway's window"
        case .system: return "Picture in picture"
        }
    }
}

enum NativePiP {
    /// Whether picture in picture is the choice (Prefs.floatStyle).
    static var chosen: Bool { Store.settings.string(forKey: "float.style") == FloatStyle.system.rawValue }

    /// WebKit lets a page into picture in picture on macOS only with a
    /// preference outside the public framework, off by default there (Safari
    /// turns it on). On only while picture in picture is the choice, so with
    /// Search's window nothing changes for any page; asked for first, as
    /// Web.inspector asks, and a WebKit without it answers "refused".
    static func allow(_ preferences: WKPreferences, on: Bool = chosen) {
        let set = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, on)
    }

    /// Every page there is, after the choice changed.
    @MainActor static func allowEverywhere() {
        for web in Web.pages.allObjects { allow(web.configuration.preferences) }
    }

    static func held(toggle: Bool) -> String {
        """
        (function () {
          var toggle = \(toggle ? "true" : "false");
          var videos = document.querySelectorAll('video');
          for (var i = 0; i < videos.length; i++) {
            var v = videos[i];
            if (v.webkitPresentationMode === 'picture-in-picture') {
              if (!toggle) return 'in';
              try { v.webkitSetPresentationMode('inline'); return 'out'; } catch (e) { return 'refused'; }
            }
          }
          return 'none';
        })();
        """
    }

    static let pick = """
    (function () {
      var v = window.__officeFloatPick;
      window.__officeFloatPick = null;
      if (!v || v.tagName !== 'VIDEO') return 'none';
      if (!v.webkitSupportsPresentationMode || !v.webkitSupportsPresentationMode('picture-in-picture')) return 'refused';
      try { v.webkitSetPresentationMode('picture-in-picture'); return 'in'; } catch (e) { return 'refused'; }
    })();
    """

    static let paused = """
    (function () {
      var videos = document.querySelectorAll('video'), best = null, area = 0;
      for (var i = 0; i < videos.length; i++) {
        var u = videos[i];
        if (u.readyState < 2) continue;
        var b = u.getBoundingClientRect();
        if (b.width * b.height >= area) { area = b.width * b.height; best = u; }
      }
      if (!best) return 'none';
      if (!best.webkitSupportsPresentationMode || !best.webkitSupportsPresentationMode('picture-in-picture')) return 'refused';
      try { best.webkitSetPresentationMode('picture-in-picture'); return 'in'; } catch (e) { return 'refused'; }
    })();
    """

    /// Back into the page, whatever is in picture in picture there.
    static let off = """
    (function () {
      var videos = document.querySelectorAll('video'), out = false;
      for (var i = 0; i < videos.length; i++) {
        if (videos[i].webkitPresentationMode === 'picture-in-picture') {
          try { videos[i].webkitSetPresentationMode('inline'); out = true; } catch (e) {}
        }
      }
      return out ? 'out' : 'none';
    })();
    """
}
