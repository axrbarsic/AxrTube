# Brave Playlist attribution

AxrTube contains adapted source code from the Brave iOS Playlist module.

- Upstream repository: <https://github.com/brave/brave-ios>
- Upstream revision: `398f8b763aa88cdc23289138863d62f05b2c2a23`
- Upstream paths: `Sources/Playlist/PlaylistDownloadManager.swift`, `Sources/Playlist/PlaylistMimeTypeDetector.swift`, `Sources/Playlist/PlaylistMediaStreamer.swift`
- License: Mozilla Public License 2.0, <https://www.mozilla.org/MPL/2.0/>
- Copyright: The Brave Authors

The AxrTube adaptations retain MPL headers in the derived source files. Brave browser persistence and WebKit types are replaced only where required by AxrTube's existing native video model, resolver and application container.

Current adapted files under `AxrTube/Sources/iPocketTube/Services/`:

- `PlaylistDownloadBackend.swift`: native file/HLS transport, task restoration and request handling.
- `VideoDownloadService.swift`: application queue integration, separated from transport during the September 2026 reliability refactor.
- `BravePlaylistMimeTypeDetector.swift`: media response validation.

AxrTube-specific coordination and tests do not imply that the complete Brave browser, Shields engine or current upstream Playlist architecture is embedded in this app.

The Brave name and trademarks are not used to claim endorsement or affiliation.
