// content.js — iPocketTube Safari Extension
//
// Detects YouTube watch/shorts URLs and sends the video ID to the background
// service worker, which navigates the tab to ipockettube://video/<id> via
// browser.tabs.update. Direct window.location navigation of custom URL schemes
// is blocked by Safari without a user gesture, so we delegate to the background.
//
// Mirrors the URL formats supported by YouTubeLinkHandler.videoID(from:):
//   - https://www.youtube.com/watch?v=VIDEO_ID
//   - https://m.youtube.com/watch?v=VIDEO_ID
//   - https://www.youtube.com/shorts/VIDEO_ID
//   - https://music.youtube.com/watch?v=VIDEO_ID
//   - https://youtu.be/VIDEO_ID
//
// The 11-character video ID regex [A-Za-z0-9_-]{11} matches YouTubeLinkHandler's
// validID() exactly — keep in sync if that method's constraints change.

(function () {
  'use strict';

  var hostname = window.location.hostname.replace(/^www\./, '').replace(/^m\./, '');
  var path     = window.location.pathname;
  var params   = new URLSearchParams(window.location.search);
  var videoID  = null;

  if (hostname === 'youtube.com' || hostname === 'music.youtube.com') {
    if (path === '/watch' || path.indexOf('/watch') === 0) {
      // https://www.youtube.com/watch?v=VIDEO_ID
      videoID = params.get('v');
    } else {
      // https://www.youtube.com/shorts/VIDEO_ID
      var shortsMatch = path.match(/^\/shorts\/([A-Za-z0-9_-]{11})/);
      if (shortsMatch) {
        videoID = shortsMatch[1];
      }
    }
  } else if (hostname === 'youtu.be') {
    // https://youtu.be/VIDEO_ID
    var idMatch = path.match(/^\/([A-Za-z0-9_-]{11})/);
    if (idMatch) {
      videoID = idMatch[1];
    }
  }

  if (videoID && /^[A-Za-z0-9_-]{11}$/.test(videoID)) {
    browser.runtime.sendMessage({ action: 'openIniPocketTube', videoID: videoID });
  }
})();
