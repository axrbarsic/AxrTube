#if !os(tvOS)
import Foundation

/// JS source strings and embed-URL/HTML-wrapper helpers shared by the Task 1
/// iframe-src-swap spike (`ShortsEmbedSrcSwapSpikeViewModel`) and, from Task 4
/// onward, `ShortsEmbedPlayerViewModel`.
///
/// `embedURL`/`htmlWrapper` intentionally duplicate what Task 2 extracts as a pure
/// function in `iPocketTubeCore` (`ShortsEmbedURL.swift`). Task 1 cannot depend on
/// Task 2 — the spike must be self-contained and runnable first. Once Task 2 lands,
/// `ShortsEmbedPlayerViewModel` (Task 4) uses the `iPocketTubeCore` version; these
/// copies remain spike-only.
enum ShortsEmbedJS {

    /// Injected at `.atDocumentStart` into every frame — verbatim copy of
    /// `TOSPlayerViewModel.webkitHiderJS` (TOSPlayerViewModel.swift:460-475). Hides
    /// `window.webkit` before any page script runs so YouTube's player can't detect
    /// the WKWebView environment, and stashes the native `ytCallback` handler as
    /// `window.__nativeYTCallback` for `stateDetectionJS` to use.
    static let webkitHiderJS: String = """
    (function() {
        try {
            var wk = window.webkit;
            if (!wk) return;
            var mh = wk.messageHandlers;
            window.__nativeYTCallback = (mh && mh.ytCallback) ? mh.ytCallback : null;
            Object.defineProperty(window, 'webkit', {
                get: function() { return undefined; },
                set: function() {},
                configurable: true,
                enumerable: false
            });
        } catch(e) {}
    })();
    """

    /// Injected at `.atDocumentStart` into every frame. Hides all YouTube Shorts
    /// chrome without depending on class names or z-index tricks.
    ///
    /// Key insight: `visibility:hidden` on an ancestor can be overridden by
    /// `visibility:visible !important` on a descendant (unlike `display:none`,
    /// which cannot). So blanket-hiding `body *` and re-showing only `video`
    /// works regardless of how YouTube nests its stacking contexts or what
    /// class names it uses — channel header, Shorts logo, share button, and
    /// pause bezel all disappear; the raw video element stays visible.
    ///
    /// #275 investigated a black-screen report by trying a more defensive
    /// rewrite of this CSS (never hiding any ancestor of `<video>`, in case
    /// `visibility:hidden` on an ancestor broke WebKit's hardware video-layer
    /// compositing). That rewrite did not fix the reported black screens — the
    /// actual root cause turned out to be `MEDIA_ERR_DECODE` from the browser
    /// itself (a codec/decode-capability issue, confirmed via the `[diag]`
    /// logging added in `stateDetectionJS` below), unrelated to this CSS.
    /// Reverted back to this simpler version since the added complexity wasn't
    /// earning its keep.
    ///
    /// `window === window.top` guard: bails immediately in the wrapper page so
    /// we do not accidentally hide the `<iframe>` itself in the outer document.
    ///
    /// MutationObserver re-adds the `<style>` tag if YouTube's JS removes it.
    static let playerControlsHiderJS: String = """
    (function() {
        // Only run inside the YouTube embed iframe, not the wrapper page.
        if (window === window.top) return;

        function apply() {
            try {
                if (!document.getElementById('__st_css')) {
                    var s = document.createElement('style');
                    s.id = '__st_css';
                    // Blanket-hide every body descendant, then re-show only the
                    // <video>. visibility:hidden (unlike display:none) is
                    // overridable by a child's visibility:visible !important, so
                    // the video stays rendered even while all its ancestors are
                    // invisible — no z-index or class-name dependency needed.
                    // position:fixed is required: height:100% on the video resolves
                    // to 0 when the parent div has height:auto (no explicit height).
                    // With position:fixed the containing block is the iframe viewport,
                    // so height:100% = full iframe height (confirmed via [DIAG] eval:
                    // w=402 h=0 before fix — width was correct but height was zero).
                    s.textContent =
                        'html,body{background:#000!important;' +
                            'margin:0!important;padding:0!important}' +
                        'body *{visibility:hidden!important}' +
                        'video{visibility:visible!important;' +
                            'position:fixed!important;top:0!important;left:0!important;' +
                            'width:100%!important;height:100%!important;' +
                            'object-fit:cover!important;background:#000!important}';
                    (document.head || document.documentElement).appendChild(s);
                }
            } catch(e) {}
        }

        apply();
        new MutationObserver(apply).observe(document.documentElement, {childList: true, subtree: true});
    })();
    """

    /// Injected at `.atDocumentEnd` into every frame — verbatim copy of
    /// `TOSPlayerViewModel.stateDetectionJS` (TOSPlayerViewModel.swift:480-587). Polls
    /// the `<video>` element every 250ms and relays `ping`/`ready`/`tick`/`stateChange`/
    /// `autoUnmuted`/`error` via `window.__nativeYTCallback.postMessage`.
    static let stateDetectionJS: String = """
    (function() {
        try {
            var _cb = window.__nativeYTCallback;
            if (_cb) _cb.postMessage('{"type":"ping"}');
        } catch(e) {}

        var _prevState = -2;
        var _playAttempts = 0;
        var _autoUnmuted = false;
        var _pausedCandidate = false;

        function postMsg(obj) {
            try {
                var cb = window.__nativeYTCallback;
                if (cb) cb.postMessage(JSON.stringify(obj));
            } catch(e) {}
        }

        var _errorReported = false;
        function checkErrorOverlay(node) {
            if (_errorReported) return;
            var errEl = node.nodeType === 1 && (
                (node.classList && node.classList.contains('ytp-error')) ||
                node.querySelector && node.querySelector('.ytp-error')
            );
            if (!errEl) return;
            _errorReported = true;
            var txt = (typeof errEl === 'object' ? (errEl.textContent || '') : (node.textContent || ''));
            var m = txt.match(/Error\\s+(\\d+)/i);
            postMsg({type: 'error', code: m ? parseInt(m[1], 10) : 153, text: txt.trim().substring(0, 200)});
        }
        var _observer = new MutationObserver(function(mutations) {
            for (var i = 0; i < mutations.length; i++) {
                var added = mutations[i].addedNodes;
                for (var j = 0; j < added.length; j++) { checkErrorOverlay(added[j]); }
            }
        });
        _observer.observe(document.documentElement, {childList: true, subtree: true});

        var _pollCount = 0;
        function pollVideo() {
            var video = document.querySelector('video');
            if (!video) return;
            _pollCount++;

            // DIAG: every 2s, report the raw <video> element state the browser
            // itself exposes — networkState/error/buffered ranges — the only way
            // to see WHY playback never starts beyond our own state classification.
            // Added while chasing #275 (currentTime stuck at 0 with no Swift-side
            // explanation; this asks the browser directly).
            if (_pollCount % 8 === 0) {
                try {
                    var ranges = [];
                    for (var i = 0; i < video.buffered.length; i++) {
                        ranges.push([video.buffered.start(i), video.buffered.end(i)]);
                    }
                    postMsg({
                        type: 'diag',
                        networkState: video.networkState,
                        readyState: video.readyState,
                        errorCode: video.error ? video.error.code : -1,
                        errorMsg: video.error ? (video.error.message || '') : '',
                        buffered: ranges,
                        paused: video.paused,
                        muted: video.muted,
                        src: video.currentSrc || ''
                    });
                } catch (e) {}
            }

            // video.paused can flicker true→false within a single poll interval right
            // after a resume (confirmed via live device log — a "paused" state was
            // reported, then a check 22ms later already found paused=false again,
            // with no further action from us). Reporting this transient blip as a
            // real pause made the controls overlay pop up and stay open, which the
            // user perceived as "unpause doesn't stick." Debounce: only commit to the
            // paused state on the 2nd consecutive poll observing it after a playing
            // state — a genuine pause is held by definition, so this costs at most
            // one extra ~250ms poll cycle of latency and only on the playing→paused
            // edge. Already-paused readings (and ended) report immediately.
            var rawPaused = video.paused;
            var s;
            if (video.ended) {
                s = 0;
                _pausedCandidate = false;
            } else if (rawPaused) {
                var wasActivelyPlaying = (_prevState === 1 || _prevState === 3);
                if (wasActivelyPlaying && !_pausedCandidate) {
                    _pausedCandidate = true;
                    s = _prevState;
                } else {
                    s = 2;
                }
            } else {
                _pausedCandidate = false;
                s = (video.readyState >= 3) ? 1 : 3;
            }

            var t = video.currentTime || 0;

            if (_prevState === -2) {
                var dur = video.duration || 0;
                if (dur <= 0) {
                    // Metadata not loaded yet on this poll — stay in the "not yet
                    // ready" sentinel state and try again on the next 250ms tick
                    // rather than firing "ready" with a bogus duration of 0.
                    return;
                }
                _prevState = s;
                postMsg({type: 'ready', duration: dur,
                         readyState: video.readyState, buffered: video.buffered.length});
            }

            if (video.paused && t === 0 && _playAttempts < 20) {
                _playAttempts++;
                video.muted = true;
                var p = video.play();
                if (p && p['catch']) { p['catch'](function() {}); }
            }

            if (!_autoUnmuted && !video.paused && t > 0.1) {
                _autoUnmuted = true;
                video.muted = false;
                var ytPlayer = document.getElementById('movie_player');
                if (ytPlayer && typeof ytPlayer.unMute === 'function') { ytPlayer.unMute(); }
                postMsg({type: 'autoUnmuted', t: t, muted: video.muted});
            }

            postMsg({type: 'tick', t: t, state: s});

            if (s !== _prevState) {
                _prevState = s;
                postMsg({type: 'stateChange', state: s});
            }
        }

        setInterval(pollVideo, 250);
    })();
    """

    /// Builds `https://www.youtube.com/embed/{videoId}?...` — mirrors
    /// `TOSPlayerViewModel.loadEmbed`'s query items (TOSPlayerViewModel.swift:405-416).
    static func embedURL(videoId: String, startTime: Double = 0) -> URL {
        var comps = URLComponents(string: "https://www.youtube.com/embed/\(videoId)")!
        comps.queryItems = [
            URLQueryItem(name: "autoplay",       value: "1"),
            URLQueryItem(name: "mute",           value: "1"),
            URLQueryItem(name: "controls",       value: "0"),
            URLQueryItem(name: "playsinline",    value: "1"),
            URLQueryItem(name: "rel",            value: "0"),
            URLQueryItem(name: "iv_load_policy", value: "3"),
            URLQueryItem(name: "start",          value: "\(Int(startTime))"),
            URLQueryItem(name: "origin",         value: "https://www.example.com"),
        ]
        return comps.url!
    }

    /// Wraps an embed URL in the `<iframe id="yt">` HTML page — mirrors
    /// `TOSPlayerViewModel.loadEmbed`'s HTML template (TOSPlayerViewModel.swift:427-446).
    static func htmlWrapper(embedURL: URL) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
                html,body,iframe{margin:0;padding:0;border:0;width:100%;height:100%;background:#000}
                iframe{position:absolute;top:0;left:0}
            </style>
        </head>
        <body>
            <iframe id="yt"
                src="\(embedURL.absoluteString)"
                frameborder="0"
                allow="autoplay; encrypted-media; fullscreen"
                allowfullscreen>
            </iframe>
        </body>
        </html>
        """
    }
}
#endif
