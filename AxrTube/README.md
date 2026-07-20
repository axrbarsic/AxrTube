# AxrTube Core

Swift Package с моделями, YouTube/InnerTube-клиентом, playback/download state machines и SwiftUI-экранами AxrTube. Пользовательское описание проекта и инструкции по установке находятся в [корневом README](../README.md).

## Основные узлы

| Область | Реализация |
|---|---|
| Поиск, рекомендации, подписки, история и каналы | `HomeViewModel`, `BrowseViewModel`, `SearchViewModel`, InnerTube renderers |
| Дата публикации и стабильная сортировка | `VideoPublicationPolicy`, `VideoPublicationFormatter` |
| Audio-first и системное Now Playing | `AudioFirstPlaybackCoordinator`, `PlaybackViewModel` |
| Playback Live Activity и Dynamic Island modes | `PlaybackLiveActivityController`, `PlaybackLiveActivityPolicy` |
| Progressive playback и HTTP Range cache | `ProgressiveAudioResourceLoader`, `SparseByteRangeCache` |
| Офлайн-коллекция и durable resume | `DownloadStore`, `VideoDownloadService` |
| Прерывания и диагностика | `AudioInterruptionStateMachine`, `AudioDiagnosticRingBuffer` |
| Matrix UI, карточки и навигация | `RootView`, `iPocketTubeDarkTheme`, общие card policies |
| SponsorBlock и DeArrow | соответствующие сервисы iPocketTubeCore |

## Проверка пакета

```bash
swift test --package-path AxrTube
```

YouTube/InnerTube API не является стабильным публичным контрактом: renderer-форматы и доступность медиапотоков могут изменяться. Код не должен логировать подписанные media URL, cookies, query, токены или account IDs.

Происхождение проекта и attribution описаны в [корневом README](../README.md). Код распространяется по [GPL-3.0](../LICENSE).
