import Foundation

enum Tempo {
    @MainActor static var on = true

    static let key = "video.keys"
    static let handedOffKey = "extensions.tempoHandedOff"
    static let extensionID = "jmeijciilikghhkcojjcfmfnancpaklk"
    static let rateEvent = "aveplaybackrate"

    static let slowest = 0.5
    static let fastest = 3.0
    static let step = 0.1
    static let reset = 1.0
    static let fallbackSeek = 15.0
    static let holdDelay = 180
    static let holdEvery = 100
    static let hudFor = 900
    static let resumeAfter = 220
    static let holdMark = "data-broadway-tempo-hold"

    static func rounded(_ rate: Double) -> Double {
        (rate * 10).rounded() / 10
    }

    static func clamped(_ rate: Double) -> Double {
        min(max(rate, slowest), fastest)
    }

    static func allows(_ rate: Double) -> Bool {
        rate.isFinite && rate >= slowest - 1e-9 && rate <= fastest + 1e-9
    }

    static func next(from rate: Double, _ direction: Int) -> Double {
        guard direction != 0 else { return clamped(reset) }
        let base = rate.isFinite && rate > 0 ? rate : reset
        return rounded(clamped(base + Double(direction.signum()) * step))
    }

    static func label(_ rate: Double) -> String {
        String(format: "%.1f", rounded(rate))
    }

    static func handOff(on: Bool, installed: [Installed], handedOff: Bool) -> String? {
        guard on, !handedOff, installed.contains(where: { $0.id == extensionID && $0.enabled }) else { return nil }
        return extensionID
    }

    static let handOffNote = "Tempo is off, because its keys are built into Broadway now. Settings › Extensions turns it back on."

    static let off = "window.__broadwayTempoOff = true;"

    static let script = #"""
    (() => {
      window.__broadwayTempoOff = false;
      if (window.__broadwayTempo) return;
      window.__broadwayTempo = true;

      const SETTINGS = {
        minimumSpeed: \#(slowest),
        maximumSpeed: \#(fastest),
        fallbackSeekSeconds: \#(fallbackSeek),
        speedStep: \#(step),
        resetSpeed: \#(reset)
      };
      const RATE_EVENT = "\#(rateEvent)";
      const REPEATABLE_KEYS = new Set(["s", "f"]);
      const INTERCEPTED_KEYS = new Set(["s", "d", "f", "e"]);
      const INTERCEPTED_KEY_CODES = new Map([
        ["KeyS", "s"],
        ["KeyD", "d"],
        ["KeyF", "f"],
        ["KeyE", "e"]
      ]);
      const LATIN_LETTER_PATTERN = /^[a-z]$/;
      const HOLD_REPEAT_DELAY_MS = \#(holdDelay);
      const HOLD_REPEAT_INTERVAL_MS = \#(holdEvery);
      const HUD_SHOWN_MS = \#(hudFor);
      const RESUME_AFTER_RATE_CHANGE_DELAY_MS = \#(resumeAfter);
      const HOLD_MARK = "\#(holdMark)";
      const SPEED_OVERLAY_OPACITY = 0.5;
      const SPEED_CELL_GAP_EM = 0.035;
      const SPEED_DIGIT_GAP_EM = 0.06;
      const SPEED_DOT_GAP = 0.12;
      const SPEED_DIGITS = "0123456789";
      const GLYPH_PROBE_PX = 100;
      const FIT_PROBE_PX = 100;
      const HUD_FADE_MS = 200;
      const SAME_BOX_SLACK = 0.01;
      const EXIT_OVERLAY_TEXT = "exit";
      const FRAME_COMMAND_MESSAGE_TYPE = "broadway-tempo-frame-command";
      const FRAME_RELEASE_MESSAGE_TYPE = "broadway-tempo-frame-release";
      const AD_KEYWORDS = [
        "ad", "ads", "advert", "advertisement", "sponsored", "promo", "commercial",
        "preroll", "midroll", "pre-roll", "mid-roll"
      ];
      const AD_EXIT_KEYWORDS = [
        "skip ad", "skip ads", "skip", "skip this ad", "close ad", "dismiss ad", "close", "dismiss",
        "continue to video", "return to video", "continue",
        "пропустить", "пропуск", "пропустити", "закрыть", "продолжить", "далі", "далее", "рекламу"
      ];
      const SECTION_EXIT_KEYWORDS = [
        "skip intro", "skip recap", "skip summary", "skip opening", "skip credits", "skip preview",
        "skip scene", "next chapter", "next scene", "next episode", "play next episode",
        "continue watching", "jump ahead", "skip ahead",
        "пропустить заставку", "пропустить вступление", "пропустить титры", "следующая серия", "наступна серія"
      ];
      const AD_CONTROL_DISCOVERY_KEYWORDS = [
        ...AD_EXIT_KEYWORDS, "uiskip", "skipads", "skipad", "vast", "vpaid", "advertiser"
      ];
      const AD_SIGNAL_PATTERNS = [
        /\bad\b/, /\bads\b/, /ad-showing/, /adshowing/, /ad-interrupting/, /adinterrupting/, /ad-break/,
        /advert/, /advertisement/, /реклам/, /preroll/, /midroll/, /pre-roll/, /mid-roll/, /sponsored/,
        /commercial break/, /skip ad/, /visit advertiser/, /learn more/, /vastnow/, /adshown/,
        /waitingads/, /vpaid/
      ];

      let hudTimeout = null;
      let hudHost = null;
      let hudBadge = null;
      let hudFit = null;
      let hudShownUntil = 0;
      let activeVideo = null;
      let heldKeyState = null;
      let glyphCanvas = null;
      const glyphInkCache = new Map();
      const suppressedKeys = new Set();
      const delegatedKeys = new Set();
      const pendingResumeByVideo = new WeakMap();

      const isOn = () => !window.__broadwayTempoOff;
      window.__broadwayTempoBadge = () => hudBadge;

      observeVideoActivity();
      document.addEventListener("visibilitychange", handleVisibilityChange, true);
      window.addEventListener("keydown", handleKeydown, true);
      window.addEventListener("keypress", handleKeypress, true);
      window.addEventListener("keyup", handleKeyup, true);
      window.addEventListener("blur", handleWindowBlur, true);
      window.addEventListener("message", handleWindowMessage, true);

      function handleVisibilityChange() {
        if (document.visibilityState !== "visible") {
          stopHeldKeyAction();
          releaseAllDelegatedKeys();
          suppressedKeys.clear();
        }
      }

      function observeVideoActivity() {
        document.addEventListener("play", event => {
          const target = event.target;
          if (target instanceof HTMLVideoElement) {
            activeVideo = target;
          }
        }, true);

        document.addEventListener("pointerdown", event => {
          const video = event.target instanceof Element ? event.target.closest("video") : null;
          if (video instanceof HTMLVideoElement) {
            activeVideo = video;
          }
        }, true);
      }

      function handleKeydown(event) {
        if (event.defaultPrevented || isEditable(event.target)) {
          return;
        }

        if (event.isComposing || event.keyCode === 229) {
          return;
        }

        if (event.metaKey || event.ctrlKey || event.altKey) {
          stopHeldKeyAction();
          releaseAllDelegatedKeys();
          return;
        }

        const key = resolveTempoKey(event);
        if (key === null) {
          return;
        }

        if (!isOn()) {
          stopHeldKeyAction();
          releaseDelegatedKey(key);
          return;
        }

        interceptEvent(event);
        suppressedKeys.add(key);
        runTempoCommand(key, { repeat: event.repeat });
      }

      function handleKeypress(event) {
        if (suppressedKeys.size === 0) {
          return;
        }

        const key = resolveTempoKey(event);
        if (key === null || !suppressedKeys.has(key)) {
          return;
        }

        interceptEvent(event);
      }

      function handleKeyup(event) {
        const key = resolveTempoKey(event);
        if (key === null) {
          return;
        }

        if (suppressedKeys.has(key)) {
          interceptEvent(event);
          suppressedKeys.delete(key);
        }

        if (heldKeyState?.key === key) {
          stopHeldKeyAction();
        }

        releaseDelegatedKey(key);
      }

      function handleWindowBlur() {
        stopHeldKeyAction();
        releaseAllDelegatedKeys();
        suppressedKeys.clear();
      }

      function handleWindowMessage(event) {
        if (window.top !== window || event.source === window) {
          return;
        }

        const message = event.data;
        if (!message || typeof message !== "object" || message.broadwayTempoType == null) {
          return;
        }

        if (message.broadwayTempoType === FRAME_RELEASE_MESSAGE_TYPE) {
          if (heldKeyState?.key === message.key) {
            stopHeldKeyAction();
          }
          return;
        }

        if (message.broadwayTempoType !== FRAME_COMMAND_MESSAGE_TYPE || !INTERCEPTED_KEYS.has(message.key)) {
          return;
        }

        runTempoCommand(message.key, {
          repeat: message.repeat === true,
          allowDelegation: false
        });
      }

      function resolveTempoKey(event) {
        const key = typeof event.key === "string" ? event.key.toLowerCase() : "";
        if (LATIN_LETTER_PATTERN.test(key)) {
          return INTERCEPTED_KEYS.has(key) ? key : null;
        }

        return INTERCEPTED_KEY_CODES.get(event.code) ?? null;
      }

      function interceptEvent(event) {
        event.preventDefault();
        event.stopPropagation();
        if (typeof event.stopImmediatePropagation === "function") {
          event.stopImmediatePropagation();
        }
      }

      function isEditable(target) {
        if (!(target instanceof Element)) {
          return false;
        }

        if (target instanceof HTMLElement && target.isContentEditable) {
          return true;
        }

        return Boolean(
          target.closest("input, textarea, select, [contenteditable=''], [contenteditable='true'], [contenteditable='plaintext-only'], [role='textbox']")
        );
      }

      function runTempoCommand(key, { repeat = false, allowDelegation = true } = {}) {
        if (!isOn()) {
          stopHeldKeyAction();
          releaseDelegatedKey(key);
          return false;
        }

        const video = findActiveVideo();
        if (!video) {
          stopHeldKeyAction();

          if (allowDelegation && forwardTempoCommandToTopFrame(key, repeat)) {
            delegatedKeys.add(key);
            return true;
          }

          releaseDelegatedKey(key);
          return false;
        }

        releaseDelegatedKey(key);

        if (repeat) {
          if (!REPEATABLE_KEYS.has(key)) {
            return false;
          }

          startHeldKeyAction(key);
          return true;
        }

        switch (key) {
          case "s":
            adjustSpeed(video, -SETTINGS.speedStep);
            startHeldKeyAction(key);
            return true;
          case "d":
            stopHeldKeyAction();
            resetSpeed(video);
            return true;
          case "f":
            adjustSpeed(video, SETTINGS.speedStep);
            startHeldKeyAction(key);
            return true;
          case "e":
            stopHeldKeyAction();
            runExitCommand(video);
            return true;
          default:
            return false;
        }
      }

      function forwardTempoCommandToTopFrame(key, repeat) {
        return postTempoFrameMessage(FRAME_COMMAND_MESSAGE_TYPE, { key, repeat });
      }

      function releaseDelegatedKey(key) {
        if (!delegatedKeys.has(key)) {
          return;
        }

        delegatedKeys.delete(key);
        postTempoFrameMessage(FRAME_RELEASE_MESSAGE_TYPE, { key });
      }

      function releaseAllDelegatedKeys() {
        for (const key of delegatedKeys) {
          postTempoFrameMessage(FRAME_RELEASE_MESSAGE_TYPE, { key });
        }

        delegatedKeys.clear();
      }

      function postTempoFrameMessage(broadwayTempoType, payload) {
        if (window.top === window) {
          return false;
        }

        const message = { broadwayTempoType, ...payload };
        const targetOrigin = window.location.origin && window.location.origin !== "null"
          ? window.location.origin
          : "*";

        try {
          window.top.postMessage(message, targetOrigin);
          return true;
        } catch (_) {
          return false;
        }
      }

      function findActiveVideo() {
        const videos = Array.from(document.querySelectorAll("video"));
        if (activeVideo instanceof HTMLVideoElement && videos.includes(activeVideo) && isUsableVideo(activeVideo)) {
          return activeVideo;
        }

        const ranked = videos
          .filter(isUsableVideo)
          .sort((lhs, rhs) => videoScore(rhs) - videoScore(lhs));

        activeVideo = ranked[0] ?? null;
        return activeVideo;
      }

      function isUsableVideo(video) {
        const rect = video.getBoundingClientRect();
        return rect.width > 120 && rect.height > 80 && rect.bottom > 0 && rect.right > 0;
      }

      function videoScore(video) {
        const rect = video.getBoundingClientRect();
        const area = rect.width * rect.height;
        const visibilityBoost = rect.top < window.innerHeight && rect.left < window.innerWidth ? 50000 : 0;
        const playingBoost = !video.paused && !video.ended ? 100000 : 0;
        const focusBoost = document.activeElement === video ? 25000 : 0;
        return area + visibilityBoost + playingBoost + focusBoost;
      }

      function adjustSpeed(video, delta) {
        const shouldResume = beginRateChange(video);
        const nextRate = clamp(video.playbackRate + delta, SETTINGS.minimumSpeed, SETTINGS.maximumSpeed);
        const appliedRate = applyPlaybackRate(video, roundRate(nextRate));
        scheduleResumeAfterRateChange(video, shouldResume);
        showVideoOverlay(appliedRate.toFixed(1), video);
      }

      function resetSpeed(video) {
        const shouldResume = beginRateChange(video);
        const appliedRate = applyPlaybackRate(video, clamp(SETTINGS.resetSpeed, SETTINGS.minimumSpeed, SETTINGS.maximumSpeed));
        scheduleResumeAfterRateChange(video, shouldResume);
        showVideoOverlay(appliedRate.toFixed(1), video);
      }

      function beginRateChange(video) {
        const pendingResume = pendingResumeByVideo.get(video);
        if (pendingResume?.timeoutToken != null) {
          window.clearTimeout(pendingResume.timeoutToken);
        }

        const shouldResume = pendingResume?.shouldResume ?? (!video.paused && !video.ended);
        if (shouldResume) {
          try { window.webkit?.messageHandlers?.\#(MediaKeys.name)?.postMessage("\#(MediaKeys.tempo)"); } catch (_) {}
        }
        if (shouldResume && !pendingResume && typeof video.pause === "function") {
          try {
            video.setAttribute(HOLD_MARK, "");
            video.pause();
          } catch (_) {}
        }

        pendingResumeByVideo.set(video, { shouldResume, timeoutToken: null });
        return shouldResume;
      }

      function scheduleResumeAfterRateChange(video, shouldResume) {
        if (!shouldResume || typeof video.play !== "function") {
          pendingResumeByVideo.delete(video);
          video.removeAttribute(HOLD_MARK);
          return;
        }

        const timeoutToken = window.setTimeout(() => {
          const pendingResume = pendingResumeByVideo.get(video);
          if (!pendingResume || pendingResume.timeoutToken !== timeoutToken) {
            return;
          }

          pendingResumeByVideo.delete(video);
          try {
            const playResult = video.play();
            const release = () => video.removeAttribute(HOLD_MARK);
            if (playResult?.then) {
              playResult.then(release, release);
            } else {
              release();
            }
          } catch (_) {
            video.removeAttribute(HOLD_MARK);
          }
        }, RESUME_AFTER_RATE_CHANGE_DELAY_MS);

        pendingResumeByVideo.set(video, { shouldResume, timeoutToken });
      }

      function applyPlaybackRate(video, desiredRate) {
        try {
          if (window.__broadwayVideo) window.__broadwayVideo.said();
        } catch (_) {}

        try {
          video.dispatchEvent(new CustomEvent(RATE_EVENT, { detail: String(desiredRate) }));
        } catch (_) {}

        if (Math.abs(video.playbackRate - desiredRate) > 0.001) {
          try {
            video.playbackRate = desiredRate;
          } catch (_) {}
        }

        try {
          video.defaultPlaybackRate = desiredRate;
        } catch (_) {}

        return roundRate(video.playbackRate);
      }

      function startHeldKeyAction(key) {
        if (!REPEATABLE_KEYS.has(key)) {
          return;
        }

        if (heldKeyState?.key === key) {
          return;
        }

        stopHeldKeyAction();

        const tick = () => {
          if (!isOn()) {
            stopHeldKeyAction();
            return;
          }

          const video = findActiveVideo();
          if (!video) {
            stopHeldKeyAction();
            return;
          }

          adjustSpeed(video, key === "f" ? SETTINGS.speedStep : -SETTINGS.speedStep);
        };

        const delayToken = window.setTimeout(() => {
          tick();
          if (!heldKeyState || heldKeyState.key !== key) {
            return;
          }

          heldKeyState.intervalToken = window.setInterval(tick, HOLD_REPEAT_INTERVAL_MS);
        }, HOLD_REPEAT_DELAY_MS);

        heldKeyState = { key, delayToken, intervalToken: null };
      }

      function stopHeldKeyAction() {
        if (!heldKeyState) {
          return;
        }

        window.clearTimeout(heldKeyState.delayToken);
        if (heldKeyState.intervalToken !== null) {
          window.clearInterval(heldKeyState.intervalToken);
        }
        heldKeyState = null;
      }

      function showExitOverlay(video) {
        showVideoOverlay(EXIT_OVERLAY_TEXT, video);
      }

      function activateExitControl(control, video) {
        if (!(control instanceof HTMLElement)) {
          return false;
        }

        showExitOverlay(video);
        activateElement(control);
        return true;
      }

      function seekVideo(video, targetTime) {
        if (!Number.isFinite(targetTime) || targetTime <= video.currentTime + 0.5) {
          return false;
        }

        showExitOverlay(video);
        video.currentTime = targetTime;
        return true;
      }

      function runExitCommand(video) {
        if (startAdExitSequence(video)) {
          return true;
        }

        if (activateExitControl(findSectionExitControl(video), video)) {
          return true;
        }

        if (seekVideo(video, findNextChapterStart(video))) {
          return true;
        }

        if (seekVideo(video, findFullVideoSeekTarget(video))) {
          return true;
        }

        return seekVideo(video, findFallbackSeekTarget(video));
      }

      function startAdExitSequence(video) {
        if (!hasAdExitOpportunity(video)) {
          return false;
        }

        performAdExitAttempt(video);
        return true;
      }

      function performAdExitAttempt(video) {
        if (tryAggressiveMediaExit(video)) {
          return true;
        }

        if (trySiteSpecificAdExit(video)) {
          return true;
        }

        if (tryKnownPlayerAdExit(video)) {
          return true;
        }

        if (activateExitControl(findAdExitControl(video), video)) {
          return true;
        }

        return isAdPlayback(video) && seekVideo(video, findAdSeekTarget(video));
      }

      function hasAdExitOpportunity(video) {
        return (
          hasSiteSpecificAdSignal(video) ||
          hasKnownPlayerAdSignal() ||
          Boolean(findAdExitControl(video)) ||
          isAdPlayback(video)
        );
      }

      function hasSiteSpecificAdSignal(video) {
        const hostname = window.location.hostname;

        if (hostname.includes("youtube.com") || hostname.includes("youtu.be")) {
          return isYouTubeAdActive(video);
        }

        if (hostname.includes("rezka.")) {
          return isRezkaAdActive();
        }

        return false;
      }

      function isYouTubeAdActive(video) {
        const player = document.querySelector("#movie_player");
        const playerDescriptor = describeNode(player);
        if (playerDescriptor.includes("ad-showing") || playerDescriptor.includes("ad-interrupting")) {
          return true;
        }

        if (!(video instanceof HTMLVideoElement)) {
          return false;
        }

        return Boolean(findVisibleElement([
          ".ytp-ad-skip-button",
          ".ytp-ad-skip-button-modern",
          ".ytp-skip-ad-button",
          ".ytp-ad-overlay-close-button",
          ".ytp-ad-survey-x-button",
          ".ytp-ad-overlay-slot button",
          ".ytp-ad-player-overlay button"
        ], [player, document]));
      }

      function isRezkaAdActive() {
        const playerState = readRezkaPlayerState();
        return playerState?.adActive === true || playerState?.hasSkipLikeNode === true;
      }

      function hasKnownPlayerAdSignal() {
        const result = evaluatePageScript(`
          const safe = callback => {
            try {
              return callback();
            } catch (_) {
              return null;
            }
          };

          const textFor = node => {
            if (!node) {
              return "";
            }
            return [
              node.id,
              node.className,
              node.getAttribute && node.getAttribute("aria-label"),
              node.getAttribute && node.getAttribute("title"),
              node.textContent
            ].filter(Boolean).join(" ").toLowerCase();
          };

          let adActive = false;

          const cdnPlayer = window.CDNPlayer;
          if (cdnPlayer && typeof cdnPlayer.api === "function") {
            adActive = adActive || safe(() => cdnPlayer.api("vastnow")) === true;
          }

          if (!adActive && typeof window.jwplayer === "function") {
            const instances = [];
            const pushInstance = value => {
              if (value && typeof value.getContainer === "function" && !instances.includes(value)) {
                instances.push(value);
              }
            };

            pushInstance(safe(() => window.jwplayer()));
            document.querySelectorAll("[id]").forEach(node => {
              pushInstance(safe(() => window.jwplayer(node.id)));
            });

            adActive = instances.some(player => {
              const container = safe(() => player.getContainer());
              return /jw-flag-ads|jw-ad|jw-skip/.test(textFor(container));
            });
          }

          if (!adActive && window.videojs) {
            const players = [];
            if (typeof window.videojs.getAllPlayers === "function") {
              players.push(...safe(() => window.videojs.getAllPlayers()) || []);
            }
            if (window.videojs.players) {
              players.push(...Object.values(window.videojs.players));
            }

            adActive = players.some(player => {
              if (!player) {
                return false;
              }

              const container = safe(() => player.el && player.el());
              return (
                safe(() => player.ads && player.ads.isInAdMode && player.ads.isInAdMode()) === true ||
                safe(() => player.ads && player.ads.inAdBreak && player.ads.inAdBreak()) === true ||
                /vjs-ad-playing|vjs-ad-loading|ima-ad-container|vjs-ima/.test(textFor(container))
              );
            });
          }

          return { adActive };
        `);

        return result?.adActive === true;
      }

      function tryAggressiveMediaExit(video) {
        const result = evaluatePageScript(`
          const safe = callback => {
            try {
              return callback();
            } catch (_) {
              return null;
            }
          };

          const isVisibleVideo = element => {
            if (!(element instanceof HTMLVideoElement)) {
              return false;
            }

            const rect = element.getBoundingClientRect();
            const style = element.ownerDocument?.defaultView?.getComputedStyle(element);
            return (
              rect.width > 0 &&
              rect.height > 0 &&
              style &&
              style.display !== "none" &&
              style.visibility !== "hidden"
            );
          };

          const findMaxTarget = element => {
            const seekableRanges = element.seekable;
            if (seekableRanges?.length) {
              return seekableRanges.end(seekableRanges.length - 1) - 0.1;
            }

            if (Number.isFinite(element.duration) && element.duration > 0) {
              return element.duration - 0.1;
            }

            return null;
          };

          const windows = [];
          const seen = new Set();
          const addWindow = candidateWindow => {
            if (!candidateWindow || seen.has(candidateWindow)) {
              return;
            }

            seen.add(candidateWindow);
            windows.push(candidateWindow);

            const frames = safe(() => Array.from(candidateWindow.document.querySelectorAll("iframe, frame"))) || [];
            for (const frame of frames) {
              const childWindow = safe(() => frame.contentWindow);
              const childDocument = safe(() => frame.contentDocument);
              if (childWindow && childDocument) {
                addWindow(childWindow);
              }
            }
          };

          addWindow(window);

          let updatedCount = 0;
          windows.forEach(frameWindow => {
            const videos = safe(() => Array.from(frameWindow.document.querySelectorAll("video"))) || [];
            videos.forEach(element => {
              if (!isVisibleVideo(element)) {
                return;
              }

              const target = findMaxTarget(element);
              if (!Number.isFinite(target) || target <= element.currentTime + 0.5) {
                return;
              }

              element.currentTime = target;
              updatedCount += 1;
            });
          });

          return { updatedCount };
        `);

        if (!result?.updatedCount) {
          return false;
        }

        showExitOverlay(video);
        return true;
      }

      function findVisibleElement(selectors, roots = [document]) {
        for (const root of roots) {
          if (!root) {
            continue;
          }

          for (const selector of selectors) {
            for (const element of queryAll(root, selector)) {
              if (element instanceof HTMLElement && isVisibleElement(element)) {
                return element;
              }
            }
          }
        }

        return null;
      }

      function trySiteSpecificAdExit(video) {
        const hostname = window.location.hostname;

        if (hostname.includes("youtube.com") || hostname.includes("youtu.be")) {
          return tryYouTubeAdExit(video);
        }

        if (hostname.includes("rezka.")) {
          return tryRezkaAdExit(video);
        }

        return false;
      }

      function tryRezkaAdExit(video) {
        if (activateExitControl(findRezkaAdExitControl(video), video)) {
          return true;
        }

        const playerState = readRezkaPlayerState();
        if (!playerState?.hasPlayer && !playerState?.hasSkipLikeNode) {
          return false;
        }

        if (!playerState.adActive && !playerState.hasSkipLikeNode) {
          return false;
        }

        const apiResult = invokeRezkaPlayerSkip();
        if (!apiResult?.attempted) {
          return false;
        }

        const refreshedState = readRezkaPlayerState();
        if (refreshedState && !refreshedState.adActive && !refreshedState.hasSkipLikeNode) {
          showExitOverlay(video);
          return true;
        }

        if (activateExitControl(findRezkaAdExitControl(video), video)) {
          return true;
        }

        return Boolean((refreshedState?.adActive || playerState.adActive) && seekVideo(video, findAdSeekTarget(video)));
      }

      function findRezkaAdExitControl(video) {
        const roots = [
          document.getElementById("oframecdnplayer"),
          document.getElementById("cdnplayer"),
          document.getElementById("cdnplayer-container")
        ].filter(root => root instanceof HTMLElement);

        if (roots.length < 1) {
          return null;
        }

        return findBestControl(video, {
          seedRoots: roots,
          selectors: [
            "[id*='skip' i]",
            "[class*='skip' i]",
            "[id*='vast' i]",
            "[class*='vast' i]",
            "[id*='vpaid' i]",
            "[class*='vpaid' i]",
            "[id*='ad' i]",
            "[class*='ad' i]"
          ],
          keywordHints: AD_CONTROL_DISCOVERY_KEYWORDS,
          scorer: scoreRezkaAdExitControl
        });
      }

      function scoreRezkaAdExitControl(element, videoRect) {
        const descriptor = describeNode(element);
        if (!descriptor) {
          return 0;
        }

        let score = scoreAdExitControl(element, videoRect);

        if (
          descriptor.includes("uiskip") ||
          descriptor.includes("skipads") ||
          descriptor.includes("skipad") ||
          descriptor.includes("vast_skip") ||
          descriptor.includes("vpaid")
        ) {
          score += 220;
        }

        if (
          descriptor.includes("пропустить") ||
          descriptor.includes("рекла") ||
          descriptor.includes("continue") ||
          descriptor.includes("advertiser")
        ) {
          score += 120;
        }

        if (element.closest("#oframecdnplayer, #cdnplayer, #cdnplayer-container")) {
          score += 40;
        }

        return score;
      }

      function tryKnownPlayerAdExit(video) {
        const result = evaluatePageScript(`
          const output = { success: false };
          const safe = callback => {
            try {
              return callback();
            } catch (_) {
              return null;
            }
          };

          const textFor = node => {
            if (!node) {
              return "";
            }
            return [
              node.id,
              node.className,
              node.getAttribute && node.getAttribute("aria-label"),
              node.getAttribute && node.getAttribute("title"),
              node.textContent
            ].filter(Boolean).join(" ").toLowerCase();
          };

          const hasSkipText = text =>
            /(skip|skip ad|continue|close ad|dismiss|пропуст|закрыть|продолжить|реклам)/.test(text || "");

          const collectRoots = () => {
            const roots = [];
            const seen = new Set();
            const add = root => {
              if (!root || seen.has(root)) {
                return;
              }
              seen.add(root);
              roots.push(root);
            };
            add(document);
            for (let index = 0; index < roots.length; index += 1) {
              const root = roots[index];
              if (!root.querySelectorAll) {
                continue;
              }
              const elements = root.querySelectorAll("*");
              for (const element of elements) {
                if (element.shadowRoot) {
                  add(element.shadowRoot);
                }
                if (element instanceof HTMLIFrameElement || element instanceof HTMLFrameElement) {
                  try {
                    if (element.contentDocument) {
                      add(element.contentDocument);
                    }
                  } catch (_) {}
                }
              }
            }
            return roots;
          };

          const visible = element => {
            if (!(element instanceof HTMLElement)) {
              return false;
            }
            const rect = element.getBoundingClientRect();
            const style = window.getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && style.display !== "none" && style.visibility !== "hidden";
          };

          const isActivatable = element => {
            if (!(element instanceof HTMLElement)) {
              return false;
            }
            if (element.matches("button, [role='button'], a, [tabindex], summary")) {
              return true;
            }
            if (typeof element.onclick === "function") {
              return true;
            }
            return window.getComputedStyle(element).cursor === "pointer";
          };

          const resolveTarget = element => {
            let current = element;
            while (current instanceof HTMLElement) {
              if (isActivatable(current)) {
                return current;
              }
              current = current.parentElement;
            }
            return element;
          };

          const clickNode = target => {
            if (!(target instanceof HTMLElement)) {
              return false;
            }
            ["pointerdown", "mousedown", "mouseup", "pointerup", "click"].forEach(type => {
              try {
                target.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, composed: true, view: window }));
              } catch (_) {}
            });
            try {
              target.click();
            } catch (_) {}
            return true;
          };

          const clickSkipNode = () => {
            const selectors = [
              "[id*='skip' i]",
              "[class*='skip' i]",
              "[id*='vast' i]",
              "[class*='vast' i]",
              "[id*='vpaid' i]",
              "[class*='vpaid' i]",
              "[class*='jw-skip' i]",
              "[class*='vjs-ima' i]",
              "[aria-label*='Skip' i]",
              "[title*='Skip' i]",
              "button",
              "[role='button']",
              "a",
              "[tabindex]"
            ];
            const roots = collectRoots();
            const matches = [];
            for (const root of roots) {
              for (const selector of selectors) {
                if (!root.querySelectorAll) {
                  continue;
                }
                for (const node of root.querySelectorAll(selector)) {
                  matches.push(node);
                }
              }
              if (!root.querySelectorAll) {
                continue;
              }
              for (const node of root.querySelectorAll("*")) {
                const text = textFor(node);
                if (hasSkipText(text) || /(uiskip|skipads|skipad|vast_skip|jw-skip|vjs-ima|vpaid|advert|sponsor)/.test(text)) {
                  matches.push(resolveTarget(node));
                }
              }
            }

            const candidates = Array.from(new Set(matches))
              .filter(visible)
              .map(node => {
                const text = textFor(node);
                let score = 0;
                if (hasSkipText(text)) {
                  score += 100;
                }
                if (/(uiskip|skipads|skipad|vast_skip|jw-skip|vjs-ima|vpaid)/.test(text)) {
                  score += 180;
                }
                if (/(реклам|advert|sponsor)/.test(text)) {
                  score += 60;
                }
                if (window.getComputedStyle(node).cursor === "pointer") {
                  score += 30;
                }
                return { node, score };
              })
              .filter(candidate => candidate.score > 0)
              .sort((lhs, rhs) => rhs.score - lhs.score);

            return clickNode(candidates[0] && candidates[0].node);
          };

          const tryPlayerJs = () => {
            const player = window.CDNPlayer;
            if (!player || typeof player.api !== "function") {
              return false;
            }
            const adActive = safe(() => player.api("vastnow")) === true;
            if (!adActive && !clickSkipNode()) {
              return false;
            }
            for (const command of ["skipAd", "vpaidSkipAd", "skipads", "vast_stop", "vastgo"]) {
              safe(() => player.api(command));
            }
            if (clickSkipNode()) {
              return true;
            }
            return safe(() => player.api("vastnow")) === false;
          };

          const tryJwPlayer = () => {
            if (typeof window.jwplayer !== "function") {
              return false;
            }
            const instances = [];
            const pushInstance = value => {
              if (value && typeof value.getContainer === "function" && !instances.includes(value)) {
                instances.push(value);
              }
            };
            pushInstance(safe(() => window.jwplayer()));
            document.querySelectorAll("[id]").forEach(node => {
              pushInstance(safe(() => window.jwplayer(node.id)));
            });
            for (const player of instances) {
              const container = safe(() => player.getContainer());
              const descriptor = textFor(container);
              const adActive =
                /jw-flag-ads|jw-ad|jw-skip/.test(descriptor) ||
                Boolean(container && container.querySelector("[class*='jw-skip' i], [aria-label*='Skip' i]"));
              if (!adActive) {
                continue;
              }
              safe(() => player.skipAd());
              safe(() => player.skipAdBreak());
              if (!/jw-flag-ads|jw-ad|jw-skip/.test(textFor(safe(() => player.getContainer())))) {
                return true;
              }
            }
            return false;
          };

          const tryVideoJs = () => {
            const videojs = window.videojs;
            if (!videojs) {
              return false;
            }
            const players = [];
            if (typeof videojs.getAllPlayers === "function") {
              players.push(...safe(() => videojs.getAllPlayers()) || []);
            }
            if (videojs.players) {
              players.push(...Object.values(videojs.players));
            }
            for (const player of players) {
              if (!player) {
                continue;
              }
              const container = safe(() => player.el && player.el());
              const descriptor = textFor(container);
              const adActive =
                safe(() => player.ads && player.ads.isInAdMode && player.ads.isInAdMode()) === true ||
                safe(() => player.ads && player.ads.inAdBreak && player.ads.inAdBreak()) === true ||
                /vjs-ad-playing|vjs-ad-loading|ima-ad-container|vjs-ima/.test(descriptor);
              if (!adActive) {
                continue;
              }
              safe(() => player.ima && player.ima.controller && player.ima.controller.getAdsManager && player.ima.controller.getAdsManager().skip());
              safe(() => player.ads && player.ads.skipLinearAdMode && player.ads.skipLinearAdMode());
              safe(() => player.trigger && player.trigger("adskip"));
              const refreshedDescriptor = textFor(safe(() => player.el && player.el()));
              const stillInAd =
                safe(() => player.ads && player.ads.isInAdMode && player.ads.isInAdMode()) === true ||
                safe(() => player.ads && player.ads.inAdBreak && player.ads.inAdBreak()) === true ||
                /vjs-ad-playing|vjs-ad-loading|ima-ad-container|vjs-ima/.test(refreshedDescriptor);
              if (!stillInAd) {
                return true;
              }
            }
            return false;
          };

          if (clickSkipNode()) {
            output.success = true;
            return output;
          }
          if (tryPlayerJs()) {
            output.success = true;
            return output;
          }
          if (tryJwPlayer()) {
            output.success = true;
            return output;
          }
          if (tryVideoJs()) {
            output.success = true;
            return output;
          }
          output.success = clickSkipNode();
          return output;
        `);

        if (!result?.success) {
          return false;
        }

        showExitOverlay(video);
        return true;
      }

      function readRezkaPlayerState() {
        return evaluatePageScript(`
          const player = window.CDNPlayer;
          const root =
            document.getElementById("oframecdnplayer") ||
            document.getElementById("cdnplayer") ||
            document.getElementById("cdnplayer-container");
          const descriptor = root
            ? [root.id, root.className, root.textContent].filter(Boolean).join(" ").toLowerCase()
            : "";
          let adActive = false;
          if (player && typeof player.api === "function") {
            try {
              adActive = player.api("vastnow") === true;
            } catch (_) {}
          }
          return {
            descriptor,
            hasPlayer: Boolean(player && typeof player.api === "function"),
            adActive,
            hasSkipLikeNode: /(skip|uiskip|vast|vpaid|пропустить|реклам)/.test(descriptor)
          };
        `);
      }

      function invokeRezkaPlayerSkip() {
        return evaluatePageScript(`
          const player = window.CDNPlayer;
          const result = { attempted: false };
          if (!player || typeof player.api !== "function") {
            return result;
          }
          const commands = ["skipAd", "vpaidSkipAd", "skipads", "vast_stop", "vastgo"];
          for (const command of commands) {
            try {
              player.api(command);
              result.attempted = true;
            } catch (_) {}
          }
          return result;
        `);
      }

      function evaluatePageScript(source) {
        const resultAttribute = `data-broadway-tempo-page-result-${Math.random().toString(36).slice(2)}`;
        const target = document.documentElement;
        if (!target) {
          return null;
        }

        const script = document.createElement("script");
        script.textContent = `
          (() => {
            let result = null;
            try {
              result = (() => { ${source} })();
            } catch (error) {
              result = null;
            }
            document.documentElement.setAttribute(${JSON.stringify(resultAttribute)}, JSON.stringify(result));
          })();
        `;

        try {
          target.appendChild(script);
          const rawResult = target.getAttribute(resultAttribute);
          target.removeAttribute(resultAttribute);
          return rawResult ? JSON.parse(rawResult) : null;
        } catch (_) {
          target.removeAttribute(resultAttribute);
          return null;
        } finally {
          script.remove();
        }
      }

      function tryYouTubeAdExit(video) {
        const player = document.querySelector("#movie_player");
        const skipSelectors = [
          ".ytp-ad-skip-button",
          ".ytp-ad-skip-button-modern",
          ".ytp-skip-ad-button",
          ".ytp-ad-overlay-close-button",
          ".ytp-ad-survey-x-button",
          ".ytp-ad-overlay-slot button",
          ".ytp-ad-player-overlay button"
        ];

        for (const selector of skipSelectors) {
          const element = player?.querySelector(selector) ?? document.querySelector(selector);
          if (activateExitControl(element, video)) {
            return true;
          }
        }

        const playerDescriptor = describeNode(player);
        const playerShowsAd = playerDescriptor.includes("ad-showing") || playerDescriptor.includes("ad-interrupting");
        return playerShowsAd && seekVideo(video, findAdSeekTarget(video));
      }

      function findAdExitControl(video) {
        return findBestControl(video, {
          selectors: [
            "button[aria-label*='Skip' i]",
            "button[aria-label*='Close' i]",
            "button[aria-label*='Dismiss' i]",
            "button[aria-label*='Continue' i]",
            "button[title*='Skip' i]",
            "button[title*='Close' i]",
            "button[title*='Dismiss' i]",
            "[role='button'][aria-label*='Skip' i]",
            "[role='button'][aria-label*='Close' i]",
            "[role='button'][aria-label*='Dismiss' i]",
            "button[class*='skip' i]",
            "button[class*='ad' i]",
            "[id*='skip' i]",
            "[class*='skip' i]",
            "[id*='vast' i]",
            "[class*='vast' i]",
            "[id*='vpaid' i]",
            "[class*='vpaid' i]",
            "[class*='skip-ad' i]",
            "[class*='ad-skip' i]",
            "[class*='ytp-ad-skip-button' i]",
            "[class*='ytp-ad-overlay-close-button' i]",
            "button[data-title-no-tooltip*='Skip' i]"
          ],
          keywordHints: AD_CONTROL_DISCOVERY_KEYWORDS,
          scorer: scoreAdExitControl
        });
      }

      function findSectionExitControl(video) {
        return findBestControl(video, {
          selectors: [
            "button[aria-label*='Skip Intro' i]",
            "button[aria-label*='Skip Recap' i]",
            "button[aria-label*='Skip Credits' i]",
            "button[aria-label*='Next Episode' i]",
            "button[aria-label*='Continue Watching' i]",
            "button[title*='Skip Intro' i]",
            "button[title*='Skip Recap' i]",
            "button[title*='Next Episode' i]",
            "[role='button'][aria-label*='Skip Intro' i]",
            "[role='button'][aria-label*='Skip Recap' i]",
            "[role='button'][aria-label*='Next Episode' i]",
            "[data-uia*='skip-intro' i]",
            "[data-uia*='skip-recap' i]",
            "[data-uia*='next-episode' i]",
            "[data-testid*='skip-intro' i]",
            "[data-testid*='skip-recap' i]",
            "[data-testid*='next-episode' i]",
            "[class*='skip-intro' i]",
            "[class*='skip-recap' i]",
            "[class*='next-episode' i]",
            "[class*='skipIntro' i]",
            "[class*='skipRecap' i]",
            "[class*='nextEpisode' i]"
          ],
          keywordHints: SECTION_EXIT_KEYWORDS,
          scorer: scoreSectionExitControl
        });
      }

      function isAdPlayback(video) {
        const candidates = dedupeElements([
          video,
          video?.parentElement,
          video instanceof Element
            ? video.closest("[class*='ad' i], [id*='ad' i], [data-ad], [data-ad-state], [aria-label*='ad' i]")
            : null,
          document.documentElement,
          document.body
        ].filter(Boolean));

        for (const node of candidates) {
          const signal = describeNode(node);
          if (!signal) {
            continue;
          }

          if (matchesAdSignal(signal) && !matchesContentSignal(signal)) {
            return true;
          }
        }

        return false;
      }

      function describeNode(node) {
        if (!(node instanceof Element)) {
          return "";
        }

        return [
          node.id,
          node.className,
          node.getAttribute("src"),
          node.getAttribute("href"),
          node.getAttribute("data-ad"),
          node.getAttribute("data-ad-state"),
          node.getAttribute("data-ad-format"),
          node.getAttribute("data-ad-preview"),
          node.getAttribute("data-player-state"),
          node.getAttribute("aria-label"),
          node.getAttribute("title"),
          node.textContent
        ]
          .filter(Boolean)
          .join(" ")
          .toLowerCase();
      }

      function matchesAdSignal(value) {
        return AD_SIGNAL_PATTERNS.some(pattern => pattern.test(value));
      }

      function matchesContentSignal(value) {
        return ["chapter", "episode", "playlist", "queue", "up next", "transcript"].some(signal => value.includes(signal));
      }

      function canSeekToEnd(video) {
        return Number.isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration;
      }

      function findAdSeekTarget(video) {
        if (!canSeekToEnd(video)) {
          return null;
        }

        return Math.max(video.currentTime, video.duration - 0.1);
      }

      function findNextChapterStart(video) {
        const chapterTracks = Array.from(video.textTracks ?? [])
          .filter(track => track.kind === "chapters" || /chapter/i.test(track.label ?? ""));

        for (const track of chapterTracks) {
          const cues = Array.from(track.cues ?? []);
          const nextCue = cues.find(cue => cue?.startTime > video.currentTime + 1);
          if (nextCue?.startTime != null) {
            return nextCue.startTime;
          }
        }

        return null;
      }

      function findFullVideoSeekTarget(video) {
        if (!canSeekToEnd(video)) {
          return null;
        }

        return video.duration - 0.1;
      }

      function findFallbackSeekTarget(video) {
        const fallbackSeconds = Math.max(SETTINGS.fallbackSeekSeconds, 5);
        const maxSeekTarget = findMaxSeekTarget(video);

        if (!Number.isFinite(maxSeekTarget) || maxSeekTarget <= video.currentTime + 1) {
          return null;
        }

        return Math.min(video.currentTime + fallbackSeconds, maxSeekTarget);
      }

      function findMaxSeekTarget(video) {
        const seekableRanges = video.seekable;

        if (seekableRanges?.length) {
          return seekableRanges.end(seekableRanges.length - 1) - 0.1;
        }

        if (Number.isFinite(video.duration) && video.duration > 0) {
          return video.duration - 0.1;
        }

        return null;
      }

      function dedupeElements(elements) {
        return Array.from(new Set(elements));
      }

      function collectSearchRoots(seedRoots = []) {
        const roots = [];
        const seen = new Set();

        const addRoot = root => {
          if (!root || seen.has(root)) {
            return;
          }
          seen.add(root);
          roots.push(root);
        };

        addRoot(document);
        seedRoots.forEach(addRoot);

        for (let index = 0; index < roots.length; index += 1) {
          const root = roots[index];
          if (!("querySelectorAll" in root)) {
            continue;
          }

          const elements = root.querySelectorAll("*");
          for (const element of elements) {
            if (element.shadowRoot) {
              addRoot(element.shadowRoot);
            }

            if (element instanceof HTMLIFrameElement || element instanceof HTMLFrameElement) {
              try {
                if (element.contentDocument) {
                  addRoot(element.contentDocument);
                }
              } catch (_) {}
            }
          }
        }

        return roots;
      }

      function queryAll(root, selectorOrSelectors) {
        if (!root || !("querySelectorAll" in root)) {
          return [];
        }

        const selectors = Array.isArray(selectorOrSelectors) ? selectorOrSelectors : [selectorOrSelectors];
        return selectors.flatMap(selector => {
          try {
            return Array.from(root.querySelectorAll(selector));
          } catch (_) {
            return [];
          }
        });
      }

      function findBestControl(video, { selectors = [], keywordHints = [], seedRoots = [], scorer }) {
        const roots = collectSearchRoots(seedRoots);
        const selectorCandidates = selectors.flatMap(selector => roots.flatMap(root => queryAll(root, selector)));
        const activatableCandidates = roots.flatMap(root => queryAll(root, "button, [role='button'], a, [tabindex], summary"));
        const keywordCandidates = collectKeywordControlCandidates(roots, keywordHints);
        const candidates = dedupeElements([
          ...selectorCandidates,
          ...activatableCandidates,
          ...keywordCandidates
        ])
          .filter(element => element instanceof HTMLElement)
          .filter(isVisibleElement);

        if (candidates.length < 1) {
          return null;
        }

        const rect = video.getBoundingClientRect();
        const scoredCandidates = candidates
          .map(element => ({ element, score: scorer(element, rect) }))
          .filter(candidate => candidate.score > 0)
          .sort((lhs, rhs) => rhs.score - lhs.score);

        return scoredCandidates[0]?.element ?? null;
      }

      function collectKeywordControlCandidates(roots, keywordHints) {
        if (keywordHints.length < 1) {
          return [];
        }

        const candidates = [];
        for (const root of roots) {
          for (const element of queryAll(root, "*")) {
            if (!(element instanceof HTMLElement) || !isVisibleElement(element)) {
              continue;
            }

            const descriptor = describeNode(element);
            if (!descriptor || !keywordHints.some(keyword => descriptor.includes(keyword))) {
              continue;
            }

            candidates.push(resolveControlCandidate(element));
          }
        }

        return candidates;
      }

      function resolveControlCandidate(element) {
        let current = element;
        while (current instanceof HTMLElement) {
          if (isActivatableElement(current)) {
            return current;
          }
          current = current.parentElement;
        }

        return element;
      }

      function isActivatableElement(element) {
        if (!(element instanceof HTMLElement)) {
          return false;
        }

        if (element.matches("button, [role='button'], a, [tabindex], summary")) {
          return true;
        }

        if (typeof element.onclick === "function") {
          return true;
        }

        return window.getComputedStyle(element).cursor === "pointer";
      }

      function scoreAdExitControl(element, videoRect) {
        const descriptor = describeNode(element);
        let score = 0;

        if (!descriptor) {
          return score;
        }

        if (AD_EXIT_KEYWORDS.some(keyword => descriptor.includes(keyword))) {
          score += 120;
        }
        if (AD_KEYWORDS.some(keyword => descriptor.includes(keyword))) {
          score += 50;
        }
        if (descriptor.includes("ytp-ad-skip-button") || descriptor.includes("ytp-ad-overlay-close-button")) {
          score += 180;
        }

        const rect = element.getBoundingClientRect();
        const overlapsHorizontally = rect.right >= videoRect.left && rect.left <= videoRect.right;
        const overlapsVertically = rect.bottom >= videoRect.top && rect.top <= videoRect.bottom;
        if (overlapsHorizontally && overlapsVertically) {
          score += 25;
        }

        const centerX = rect.left + rect.width / 2;
        const centerY = rect.top + rect.height / 2;
        const targetX = videoRect.right - Math.min(120, videoRect.width * 0.15);
        const targetY = videoRect.bottom - Math.min(90, videoRect.height * 0.18);
        const distance = Math.hypot(centerX - targetX, centerY - targetY);
        score += Math.max(0, 80 - distance / 8);

        return score;
      }

      function scoreSectionExitControl(element, videoRect) {
        const descriptor = describeNode(element);
        if (!descriptor) {
          return 0;
        }

        let score = 0;

        if (SECTION_EXIT_KEYWORDS.some(keyword => descriptor.includes(keyword))) {
          score += 180;
        }

        if (descriptor.includes("skip") || descriptor.includes("next")) {
          score += 45;
        }

        if (AD_KEYWORDS.some(keyword => descriptor.includes(keyword))) {
          score -= 40;
        }

        const rect = element.getBoundingClientRect();
        const overlapsHorizontally = rect.right >= videoRect.left && rect.left <= videoRect.right;
        const overlapsVertically = rect.bottom >= videoRect.top && rect.top <= videoRect.bottom;
        if (overlapsHorizontally && overlapsVertically) {
          score += 25;
        }

        const centerX = rect.left + rect.width / 2;
        const centerY = rect.top + rect.height / 2;
        const targetX = videoRect.right - Math.min(140, videoRect.width * 0.18);
        const targetY = videoRect.bottom - Math.min(120, videoRect.height * 0.2);
        const distance = Math.hypot(centerX - targetX, centerY - targetY);
        score += Math.max(0, 70 - distance / 8);

        return score;
      }

      function activateElement(element) {
        if (!(element instanceof HTMLElement)) {
          return;
        }

        for (const eventType of ["pointerdown", "mousedown", "mouseup", "pointerup", "click"]) {
          try {
            element.dispatchEvent(new MouseEvent(eventType, {
              bubbles: true,
              cancelable: true,
              composed: true,
              view: window
            }));
          } catch (_) {}
        }

        element.click();
      }

      function isVisibleElement(element) {
        const rect = element.getBoundingClientRect();
        const style = window.getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
      }

      function showVideoOverlay(text, video) {
        const overlayRoot = resolveOverlayRoot(video);
        const host = ensureSpeedOverlay(overlayRoot);
        const badge = hudBadge;
        if (!badge) {
          return;
        }
        const scale = getOverlayRootScale(overlayRoot);
        const rect = scaleRect(getOverlayFrameRect(video, overlayRoot), scale);
        if (rect.width < 1 || rect.height < 1) {
          return;
        }

        const rootRect = scaleRect(getOverlayRootRect(overlayRoot), scale);
        const rootScroll = getOverlayRootScroll(overlayRoot);
        const variant = getOverlayVariant(text);
        const sizeRect = isNearlySameBox(rect, rootRect) ? rootRect : rect;
        const layout = { ...getOverlayLayout(sizeRect, variant), scale };
        badge.style.fontSize = `${FIT_PROBE_PX}px`;
        renderOverlayContent(badge, text, variant, scale);

        const overlaySize = fitOverlayBadge(host, badge, layout);
        positionOverlayHost(host, rect, rootRect, rootScroll, overlaySize, layout);
        setHostStyle(host, { opacity: "1" });
        hudShownUntil = performance.now() + HUD_SHOWN_MS + HUD_FADE_MS;

        window.clearTimeout(hudTimeout);
        hudTimeout = window.setTimeout(() => {
          setHostStyle(host, { opacity: "0" });
        }, HUD_SHOWN_MS);
      }

      function getOverlayRootScale(root) {
        if (!(root instanceof HTMLElement) || root === document.body || root === document.documentElement) {
          return 1;
        }
        const width = root.offsetWidth;
        const drawn = root.getBoundingClientRect().width;
        const scale = width > 0 && drawn > 0 ? drawn / width : 1;
        return Number.isFinite(scale) && scale > 0.05 ? scale : 1;
      }

      function isNearlySameBox(rect, other) {
        if (!(other.width > 0 && other.height > 0)) {
          return false;
        }
        const near = (lhs, rhs) => Math.abs(lhs - rhs) <= Math.max(2, rhs * SAME_BOX_SLACK);
        return near(rect.width, other.width) && near(rect.height, other.height);
      }

      function scaleRect(rect, scale) {
        if (scale === 1) {
          return rect;
        }
        return rectFromDimensions(rect.left / scale, rect.top / scale, rect.width / scale, rect.height / scale);
      }

      function getOverlayVariant(text) {
        return /^\d+(\.\d+)?$/.test(text) ? "speed" : "exit";
      }

      function getOverlayLayout(frame, variant) {
        const rect = { width: Math.round(frame.width), height: Math.round(frame.height) };
        const shortSide = Math.min(rect.width, rect.height);
        const isPortrait = rect.height > rect.width * 1.05;
        const baseFontSize = rect.width * (isPortrait ? 0.55 : 0.33);
        const box = { boxWidth: rect.width, boxHeight: rect.height, maxFontSize: shortSide * 0.5 };

        if (variant === "speed") {
          return {
            variant,
            ...box,
            fontSize: baseFontSize,
            minFontSize: baseFontSize * 0.72,
            maxWidth: rect.width * (isPortrait ? 0.82 : 0.62),
            maxHeight: rect.height * (isPortrait ? 0.32 : 0.5),
            rightInset: Math.max(isPortrait ? 14 : 24, shortSide * (isPortrait ? 0.058 : 0.07)),
            bottomInset: Math.max(isPortrait ? 10 : 24, shortSide * (isPortrait ? 0.04 : 0.065))
          };
        }

        return {
          variant,
          ...box,
          fontSize: baseFontSize,
          minFontSize: baseFontSize * 0.72,
          maxWidth: rect.width * (isPortrait ? 0.56 : 0.42),
          maxHeight: rect.height * (isPortrait ? 0.18 : 0.26),
          rightInset: Math.max(isPortrait ? 16 : 28, shortSide * (isPortrait ? 0.062 : 0.074)),
          bottomInset: Math.max(isPortrait ? 12 : 28, shortSide * (isPortrait ? 0.044 : 0.07))
        };
      }

      function renderOverlayContent(badge, text, variant, scale = 1) {
        badge.dataset.variant = variant;

        if (variant === "speed") {
          renderSpeedOverlay(badge, text, scale);
          return;
        }

        badge.replaceChildren(document.createTextNode(text));
      }

      function fitOverlayBadge(host, badge, layout) {
        const key = `${layout.variant}|${badge.textContent.length}`;
        const scale = layout.scale || 1;
        let fontSize;
        if (hudFit && hudFit.key === key && (performance.now() < hudShownUntil || sameOverlayBox(hudFit, layout))) {
          fontSize = hudFit.fontSize;
        } else {
          fontSize = measureOverlayFit(host, badge, layout);
          hudFit = { key, boxWidth: layout.boxWidth, boxHeight: layout.boxHeight, fontSize };
        }

        badge.style.fontSize = `${fontSize}px`;
        const overlaySize = measureOverlayBadge(badge, scale);
        return {
          width: Math.ceil(overlaySize.width),
          height: Math.ceil(overlaySize.height)
        };
      }

      function sameOverlayBox(fit, layout) {
        const near = (lhs, rhs) => Math.abs(lhs - rhs) <= Math.max(2, rhs * SAME_BOX_SLACK);
        return near(layout.boxWidth, fit.boxWidth) && near(layout.boxHeight, fit.boxHeight);
      }

      function measureOverlayFit(host, badge, layout) {
        badge.style.fontSize = `${FIT_PROBE_PX}px`;
        setHostStyle(host, { width: "auto", height: "auto" });
        const probe = measureOverlayBadge(badge, layout.scale || 1);
        const slack = parseFloat(badge.querySelector(".tempo-number")?.dataset.slack) || 0;
        const widthEm = Math.max(probe.width / FIT_PROBE_PX + slack, 0.01);
        const heightEm = Math.max(probe.height / FIT_PROBE_PX, 0.01);
        const fitted = Math.min(layout.fontSize, layout.maxWidth / widthEm, layout.maxHeight / heightEm);
        const bounded = Math.min(Math.max(fitted, layout.minFontSize), layout.maxFontSize);
        return Math.max(1, Math.floor(bounded));
      }

      function measureOverlayBadge(badge, scale = 1) {
        const rect = badge.getBoundingClientRect();
        return { width: rect.width / scale, height: rect.height / scale };
      }

      function positionOverlayHost(host, frameRect, rootRect, rootScroll, overlaySize, layout) {
        const minLeft = frameRect.left - rootRect.left + rootScroll.left;
        const maxLeft = frameRect.right - rootRect.left + rootScroll.left - overlaySize.width;
        const minTop = frameRect.top - rootRect.top + rootScroll.top;
        const maxTop = frameRect.bottom - rootRect.top + rootScroll.top - overlaySize.height;
        const targetLeft = frameRect.right - rootRect.left + rootScroll.left - layout.rightInset - overlaySize.width;
        const targetTop = frameRect.bottom - rootRect.top + rootScroll.top - layout.bottomInset - overlaySize.height;

        setHostStyle(host, {
          left: `${clamp(targetLeft, minLeft, Math.max(minLeft, maxLeft))}px`,
          top: `${clamp(targetTop, minTop, Math.max(minTop, maxTop))}px`,
          width: `${overlaySize.width}px`,
          height: `${overlaySize.height}px`
        });
      }

      function setHostStyle(host, styles) {
        for (const [name, value] of Object.entries(styles)) {
          host.style.setProperty(name, value, "important");
        }
      }

      function renderSpeedOverlay(badge, text, scale = 1) {
        const [whole, fraction = "0"] = text.split(".");
        const numberNode = document.createElement("span");
        numberNode.className = "tempo-number";

        const dotNode = document.createElement("span");
        dotNode.className = "tempo-dot";
        dotNode.textContent = ".";

        const glyphNodes = [
          ...Array.from(whole, (digit) => createDigitNode(digit)),
          dotNode,
          ...Array.from(fraction, (digit) => createDigitNode(digit))
        ];
        numberNode.append(...glyphNodes);
        badge.replaceChildren(numberNode);
        tightenSpeedGlyphs(badge, numberNode, glyphNodes, scale);
      }

      function createDigitNode(digit) {
        const node = document.createElement("span");
        node.className = "tempo-digit";
        node.textContent = digit;
        return node;
      }

      function tightenSpeedGlyphs(badge, numberNode, glyphNodes, scale = 1) {
        const style = window.getComputedStyle(badge);
        const fontSize = parseFloat(style.fontSize);
        const metrics = glyphNodes.map((node) => measureGlyphInk(node.textContent, style));
        const matchesLayout = metrics.every((metric, index) => {
          if (!metric || !(fontSize > 0)) {
            return false;
          }
          const laidOut = glyphNodes[index].getBoundingClientRect().width / scale / fontSize;
          return Math.abs(laidOut - metric.advance) < 0.02;
        });
        if (!matchesLayout) {
          return;
        }

        const digitMetrics = Array.from(SPEED_DIGITS, (digit) => measureGlyphInk(digit, style));
        if (digitMetrics.some((metric) => !metric)) {
          return;
        }
        const cell = Math.max(...digitMetrics.map((metric) => metric.ink));
        const bearing = Math.max(0, (digitMetrics[0].advance - cell) / 2);
        const isDot = glyphNodes.map((node) => node.classList.contains("tempo-dot"));
        const dotInk = metrics[isDot.indexOf(true)].ink;
        const room = metrics.map((metric, index) => (isDot[index] ? 0 : (cell - metric.ink) / 2));
        const last = glyphNodes.length - 1;
        const margins = [];
        let slack = 0;
        numberNode.style.gap = "0";
        const first = room[0] + bearing - metrics[0].left;
        glyphNodes[0].style.marginLeft = `${first.toFixed(4)}em`;
        margins.push(first);
        for (let index = 1; index < glyphNodes.length; index += 1) {
          const touchesDot = isDot[index - 1] || isDot[index];
          const cellGap = touchesDot ? dotInk * SPEED_DOT_GAP : SPEED_DIGIT_GAP_EM;
          const inkGap = cellGap + room[index - 1] + room[index];
          const margin = inkGap - metrics[index - 1].right - metrics[index].left;
          glyphNodes[index].style.marginLeft = `${margin.toFixed(4)}em`;
          margins.push(margin);
          slack += touchesDot ? SPEED_CELL_GAP_EM : 0;
        }
        const end = room[last] + bearing - metrics[last].right;
        glyphNodes[last].style.marginRight = `${end.toFixed(4)}em`;
        margins.push(end);
        slack -= margins.reduce((sum, margin) => sum + margin, 0);
        numberNode.dataset.slack = slack.toFixed(4);
        numberNode.dataset.cell = cell.toFixed(4);
      }

      function measureGlyphInk(glyph, style) {
        const family = style.fontFamily;
        const weight = style.fontWeight;
        const key = `${weight}|${family}|${glyph}`;
        if (glyphInkCache.has(key)) {
          return glyphInkCache.get(key);
        }

        let metric = null;
        try {
          const side = GLYPH_PROBE_PX * 2;
          const origin = GLYPH_PROBE_PX / 2;
          if (!glyphCanvas) {
            glyphCanvas = document.createElement("canvas");
            glyphCanvas.width = side;
            glyphCanvas.height = side;
          }
          const context = glyphCanvas.getContext("2d", { willReadFrequently: true });
          context.clearRect(0, 0, side, side);
          context.font = `${weight} ${GLYPH_PROBE_PX}px ${family}`;
          context.textAlign = "left";
          context.textBaseline = "alphabetic";
          context.fillStyle = "#000";
          context.fillText(glyph, origin, GLYPH_PROBE_PX * 1.4);
          const measured = context.measureText(glyph);
          const pixels = context.getImageData(0, 0, side, side).data;
          let inkLeft = Infinity;
          let inkRight = -Infinity;
          for (let y = 0; y < side; y += 1) {
            for (let x = 0; x < side; x += 1) {
              if (pixels[(y * side + x) * 4 + 3] >= 128) {
                inkLeft = Math.min(inkLeft, x - origin);
                inkRight = Math.max(inkRight, x + 1 - origin);
              }
            }
          }
          if (measured.width > 0 && inkRight > inkLeft) {
            metric = {
              advance: measured.width / GLYPH_PROBE_PX,
              left: inkLeft / GLYPH_PROBE_PX,
              right: (measured.width - inkRight) / GLYPH_PROBE_PX,
              ink: (inkRight - inkLeft) / GLYPH_PROBE_PX
            };
          }
        } catch (_) {}

        glyphInkCache.set(key, metric);
        return metric;
      }

      function resolveOverlayRoot(video) {
        const preferredRoot = video.closest(
          "#movie_player, .html5-video-player, .video-js, .jwplayer, .jwplayer-container, .plyr, [data-player], [class*='player' i]"
        );
        if (preferredRoot instanceof HTMLElement) {
          return preferredRoot;
        }

        const videoRect = video.getBoundingClientRect();
        let bestRoot = video.parentElement instanceof HTMLElement ? video.parentElement : document.body;
        let bestScore = Number.POSITIVE_INFINITY;

        for (let current = video.parentElement; current instanceof HTMLElement; current = current.parentElement) {
          const rect = current.getBoundingClientRect();
          if (rect.width < 1 || rect.height < 1) {
            continue;
          }

          const score = scoreOverlayRoot(rect, videoRect);
          if (score < bestScore) {
            bestScore = score;
            bestRoot = current;
          }
        }

        return bestRoot;
      }

      function scoreOverlayRoot(rootRect, videoRect) {
        const widthDelta = Math.abs(rootRect.width - videoRect.width);
        const heightDelta = Math.abs(rootRect.height - videoRect.height);
        const leftDelta = Math.abs(rootRect.left - videoRect.left);
        const topDelta = Math.abs(rootRect.top - videoRect.top);

        return widthDelta + heightDelta + (leftDelta * 2) + (topDelta * 2);
      }

      function getOverlayRootRect(root) {
        if (root === document.body || root === document.documentElement) {
          return { left: 0, top: 0, width: 0, height: 0 };
        }

        return root.getBoundingClientRect();
      }

      function getOverlayFrameRect(video, root) {
        const videoRect = getRenderedVideoRect(video);
        if (root instanceof HTMLElement && root !== document.body && root !== document.documentElement) {
          const rootRect = root.getBoundingClientRect();
          if (rootRect.width > 0 && rootRect.height > 0) {
            return intersectRects(videoRect, rootRect) ?? rootRect;
          }
        }

        return videoRect;
      }

      function getRenderedVideoRect(video) {
        const videoRect = video.getBoundingClientRect();
        if (
          videoRect.width < 1 ||
          videoRect.height < 1 ||
          !Number.isFinite(video.videoWidth) ||
          !Number.isFinite(video.videoHeight) ||
          video.videoWidth < 1 ||
          video.videoHeight < 1
        ) {
          return videoRect;
        }

        const mediaAspect = video.videoWidth / video.videoHeight;
        const rectAspect = videoRect.width / videoRect.height;
        const rawFit = window.getComputedStyle(video).objectFit.trim().toLowerCase();
        const fit = rawFit === "fill" && Math.abs(rectAspect - mediaAspect) > 0.04 ? "contain" : rawFit;

        if (fit === "fill" || fit === "cover") {
          return videoRect;
        }

        if (fit === "none") {
          const width = Math.min(videoRect.width, video.videoWidth);
          const height = Math.min(videoRect.height, video.videoHeight);
          return rectFromDimensions(
            videoRect.left + (videoRect.width - width) / 2,
            videoRect.top + (videoRect.height - height) / 2,
            width,
            height
          );
        }

        if (fit === "scale-down") {
          const fitsWithoutScaling = video.videoWidth <= videoRect.width && video.videoHeight <= videoRect.height;
          if (fitsWithoutScaling) {
            const width = video.videoWidth;
            const height = video.videoHeight;
            return rectFromDimensions(
              videoRect.left + (videoRect.width - width) / 2,
              videoRect.top + (videoRect.height - height) / 2,
              width,
              height
            );
          }
        }

        if (!Number.isFinite(mediaAspect) || mediaAspect <= 0) {
          return videoRect;
        }

        if (mediaAspect > rectAspect) {
          const width = videoRect.width;
          const height = width / mediaAspect;
          return rectFromDimensions(videoRect.left, videoRect.top + (videoRect.height - height) / 2, width, height);
        }

        const height = videoRect.height;
        const width = height * mediaAspect;
        return rectFromDimensions(videoRect.left + (videoRect.width - width) / 2, videoRect.top, width, height);
      }

      function intersectRects(lhs, rhs) {
        const left = Math.max(lhs.left, rhs.left);
        const top = Math.max(lhs.top, rhs.top);
        const right = Math.min(lhs.right, rhs.right);
        const bottom = Math.min(lhs.bottom, rhs.bottom);

        if (right <= left || bottom <= top) {
          return null;
        }

        return rectFromDimensions(left, top, right - left, bottom - top);
      }

      function rectFromDimensions(left, top, width, height) {
        return { left, top, width, height, right: left + width, bottom: top + height };
      }

      function getOverlayRootScroll(root) {
        if (root === document.body || root === document.documentElement) {
          return { left: window.scrollX, top: window.scrollY };
        }

        return { left: root.scrollLeft, top: root.scrollTop };
      }

      function ensureOverlayRootPosition(root) {
        if (!(root instanceof HTMLElement)) {
          return;
        }

        if (window.getComputedStyle(root).position === "static") {
          root.style.position = "relative";
        }
      }

      function ensureSpeedOverlay(root) {
        ensureOverlayRootPosition(root);

        if (hudHost && hudBadge) {
          if (hudHost.parentElement !== root) {
            root.appendChild(hudHost);
          }
          return hudHost;
        }

        const host = document.createElement("div");
        host.id = "tempo-hud-host";
        setHostStyle(host, {
          all: "initial",
          display: "block",
          position: "absolute",
          top: "0",
          left: "0",
          width: "auto",
          height: "auto",
          margin: "0",
          padding: "0",
          border: "0",
          zoom: "1",
          transform: "none",
          visibility: "visible",
          overflow: "visible",
          "z-index": "2147483647",
          opacity: "0",
          "pointer-events": "none",
          transition: "opacity 200ms ease"
        });

        const shadow = host.attachShadow({ mode: "closed" });
        const style = document.createElement("style");
        style.textContent = `
          #tempo-speed-overlay {
            all: initial;
            pointer-events: none;
            display: inline-flex;
            align-items: flex-end;
            justify-content: flex-end;
            overflow: visible;
            color: rgba(255, 255, 255, ${SPEED_OVERLAY_OPACITY});
            font-family: "Ceph Mono", "SF Mono", "SFMono-Regular", ui-monospace, Menlo, Monaco, monospace;
            font-weight: 700;
            line-height: 0.82;
            letter-spacing: 0;
            text-align: right;
            white-space: nowrap;
          }

          #tempo-speed-overlay[data-variant="exit"] {
            line-height: 0.78;
            letter-spacing: -0.02em;
          }

          .tempo-number {
            display: inline-flex;
            align-items: flex-end;
            justify-content: flex-end;
            line-height: 0.82;
            letter-spacing: 0;
            gap: ${SPEED_CELL_GAP_EM}em;
            white-space: nowrap;
            overflow: visible;
          }

          .tempo-digit,
          .tempo-dot {
            display: block;
            line-height: 1;
            flex: 0 0 auto;
          }
        `;

        const overlay = document.createElement("div");
        overlay.id = "tempo-speed-overlay";
        shadow.appendChild(style);
        shadow.appendChild(overlay);

        root.appendChild(host);
        hudHost = host;
        hudBadge = overlay;
        return host;
      }

      function clamp(value, min, max) {
        return Math.min(Math.max(value, min), max);
      }

      function roundRate(value) {
        return Math.round(value * 10) / 10;
      }
    })();
    """#
}
