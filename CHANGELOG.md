# История изменений AxrTube

Здесь перечислены подтверждённые изменения AxrTube.

---

## Не выпущено

### Длительность локального видео и живой таймлайн, 8 сентября 2026

- По физическому интерфейсу выявлено: транспорт воспроизводит локальный файл, но карточка остаётся на `0:00`, длительность неизвестна и визуализация не появляется. Локальный fast path не публиковал длительность, а UI обнулял позицию при неизвестной длительности.
- Наблюдение длительности перенесено к текущему `AVPlayerItem`. Четыре дублированных обработчика источников удалены; результат старого item не может изменить новый. При остановленном и скрытом плеере поздняя длительность не возвращает карточку Now Playing.
- Таймлайн больше не вычисляет ход времени самостоятельно на каждом кадре. Он показывает фактическую позицию AVPlayer; PCM-визуализация работает и до получения длительности.
- 8 адресных тестов в 3 группах прошли, независимая проверка и simulator-сборка прошли. На одном iPhone 17 Pro Max Simulator локальный MP4 с нулевой длительностью в записи получил `1:00`, позиция продвигалась, живой сигнал появился без полноэкранного плеера. Новые проверки добавлены в CI.
- По просьбе пользователя эта дополнительная правка проверена без подключения к физическому iPhone и пока на него не установлена. Слышимость звука и реальные аудиопрерывания не объявляются подтверждёнными по таймлайну или сигналу.

### Владельцы загрузок и воспроизведения, 8 сентября 2026

- Финальный адресный набор и GitHub CI: 118 тестов, 18 групп, PASS. Подписанная iOS-сборка прошла и установлена поверх приложения без удаления данных. После снятия блокировки приложение запущено, живой процесс подтверждён. Через удалённый интерфейс проверены переключение между двумя сохранёнными роликами без исчезновения записей и открытие полной стенограммы с двумя кнопками. Физическая приёмка звука, прерываний и фонового режима ещё ожидается.
- Координатор офлайн-очереди отделён от нативного сетевого транспорта. Заявка записывается до проверки свободного места; экран и уведомления не продвигают очередь.
- Пауза адресуется конкретной карточке. Запоздалый resolver защищён токеном заявки, события URLSession защищены поколением задачи. Ожидание повтора одного ролика не блокирует обработку других.
- Удержание загрузок ради подготовки буфера ограничено тремя секундами одного непрерывного ожидания. Низкий приоритет фоновых передач сохранён.
- Готовность источника, смена качества, восстановление буфера и регуляторы скорости используют общую проверку намерения воспроизведения. Смена ролика больше не очищает активное аудиопрерывание.
- Скрытые веб-компоненты разрешения ссылок не могут воспроизводить медиа. HLS из веб-компонента принимается только при совпадении ID основного ролика; неподтверждённые адреса DOM-плеера не используются. SponsorBlock и фильтрация рекламных карточек сохранены.
- Это первый проверяемый этап архитектурного рефакторинга, не заявление о завершении миграции всего приложения. План и ограничения: `docs/RELIABILITY_ARCHITECTURE.md`.
- README и GitHub-описание приведены к video-first и Markdown-only сценарию. Из CI убраны фильтры удалённой audio-first системы и неактуальной AI-выжимки, добавлены проверки текущей очереди, путей, звукового владельца, субтитров и карточек. Постоянный порядок публикации и отката зафиксирован в `docs/DEVELOPMENT_WORKFLOW.md`.

### Безопасная самопроверка путей офлайн-медиатеки

- После смены контейнера приложения путь восстанавливается по сохранённому имени файла, а не только по старому шаблону ID.mp4.
- Для записей с ложной ошибкой отсутствующего файла предусмотрен однозначный поиск финализированного MP4 по ID ролика, UUID и сигнатуре контейнера. Несколько кандидатов не выбираются автоматически.
- Проверка запускается при загрузке медиатеки, возвращении приложения на экран и раз в минуту активной работы. Она меняет только подтверждённые записи, не удаляет файлы, не запускает сеть и не меняет активные, отменённые или вручную приостановленные загрузки.
- 25 адресных тестов прошли, включая перенос контейнера, повторяемость ремонта и отказ от неоднозначного восстановления. Это защита целостности ссылок, не универсальное исправление любых ошибок или проверка декодирования всего видео.

### Фоновое встроенное воспроизведение и приоритет буфера

- Общему AVPlayer задана политика `continuesIfPossible`. Встроенный и мини-плеер получают события перехода в фон через владельца PlayerStateStore, независимо от отсутствующего полноэкранного PlayerView.
- Офлайн-передачи получают низкий приоритет URLSession. Подготовка буфера даёт плееру короткий приоритет, с 8 сентября он ограничен тремя секундами непрерывного ожидания. Процент скачивания не является условием начала воспроизведения.
- Правила настоящих аудиопрерываний и ручной паузы сохранены. 8 адресных тестов и подписанная iOS-сборка прошли. Физическая проверка ранней блокировки и голосового объявления в наушниках ожидается.

### Устойчивость офлайн-загрузок, первый этап

- Прямой файл с поддержкой Range и сильным ETag сохраняется подтверждёнными диапазонами с атомарным журналом. Проверяются границы, длина ответа и идентичность представления; после перезапуска неподтверждённый хвост отбрасывается. Без валидатора используется системная загрузка целого файла.
- Добавлены ограниченные повторы временных сетевых ошибок, ожидание связи и восстановление очереди при возвращении в приложение. Продвижение очереди больше не зависит только от наблюдения экраном за уведомлением.
- Отмена инвалидирует запоздалые события. Неполный HTTP-ответ не отмечается готовым файлом; проверка лимита предшествует переносу результата.
- 10 адресных тестов прошли, подписанная iOS-сборка установлена поверх приложения. Проверка реального обрыва сети на iPhone ожидается. Автоматическое улучшение качества ещё не реализовано; возобновление HLS остаётся в пределах возможностей системной сессии Apple.

### Актуальные настройки и визуализация звука

- Добавлен переключатель осциллографа: кривая использует знаковые PCM-отсчёты текущего аудиопотока, а не случайную анимацию. Эквалайзер остаётся альтернативой.
- Фильтр «Только русский» доступен в панели фильтров рядом с поиском и применяется также к главной и рекомендациям на iPhone. Неизвестный язык не допускается; проверка основана на метаданных YouTube, не на языке заголовка.
- Из настроек удалены AI-выжимка, провайдеры, модели и ввод ключей. Удалён runtime-владелец выжимки из PlayerRouter. Сохранённые ключи не удаляются.
- В настройки возвращён действующий лимит офлайн-хранилища. Кнопка диагностики честно сообщает о локальной отметке, а не об отправке отчёта.

### Закреплённые каналы

- В списке каналов добавлена кнопка-булавка. Закреплённые каналы показываются сверху и сохраняются локально вместе с названием и аватаром, независимо от полноты очередного ответа YouTube. Повторное нажатие открепляет канал, не меняя подписку YouTube.

### Остановка при удалении офлайн-медиа

- Исправлен неработающий Play другого скачанного ролика: Downloads теперь обрабатывает inline playback intent. Превью и заголовок готового ролика также переключают воспроизведение.
- Результат загрузки показывается неблокирующим сообщением на четыре секунды, без кнопки OK. Подробная ошибка остаётся в карточке загрузки.
- Очистка загрузок и удаление текущего ролика сначала останавливают его воспроизведение и освобождают AVPlayerItem, затем отменяют соответствующие загрузки и удаляют файлы. Удаление другого ролика не прерывает текущий.
- Адресные проверки жизненного цикла коллекции: 22 теста зелёные, включая порядок остановки и удаления. Физическая проверка ожидается.

### Упрощение стенограммы и исправления офлайн-состояний, 5 сентября 2026

- Один вход «Показать стенограмму»: весь текст без промежуточного preview, сверху «Копировать всё» и «Сохранить Markdown». PDF/HTML больше не создаются в рабочем сценарии, старые пользовательские файлы не удаляются.
- Чтение стенограммы из загрузок не запускает другой ролик. Готовый документ можно восстановить из кэша без сети; повреждённый Markdown не принимается за исправный кэш.
- HTTP-ошибка caption track не считается отсутствием субтитров. Ошибки скачивания предлагают ручной повтор, а повтор получает новый бюджет fallback вместо сохранённого отказа предыдущей попытки.
- Завершение сторонней восстановленной фоновой задачи не перезаписывает состояние текущей загрузки.
- Адресные проверки: 46 тестов зелёные. Установка и физическая проверка этой версии ожидаются.

### Video-first медиатека Brave Playlist

- Production routing больше не создаёт отдельный audio-first coordinator. Сетевое, локальное, полноэкранное и компактное видео принадлежат одному `AVPlayer`.
- Офлайн-сохранение теперь выбирает HLS, затем muxed MP4, использует системные фоновые download sessions и восстанавливает задачи по стабильной identity после relaunch.
- Новые загрузки всегда содержат видео. Старые M4A и manifest записи сохранены на диске для безопасного install-over, но скрыты из нового flow и автоматически не возобновляются.
- Из production tree удалены audio-first coordinator, progressive resource loader, direct-audio factory и их специализированные tests. Добавлены policy tests выбора источника и восстановления фоновой task identity.
- Дизайн фонового downloader адаптирован из Brave iOS Playlist под MPL-2.0; браузерный DOM detector заменён существующим native InnerTube resolver AxrTube.
- Перенесены Brave MIME detector, `Range` и playback-session headers, проверка HTTP status и сохранение HLS package в постоянный контейнер; добавлена точная attribution на upstream revision `398f8b7`.

### Архив прежнего audio-first конвейера

Пункты ниже сохраняют историю уже заменённой реализации и не описывают текущий production flow.

1. **Главная лента:** refresh и pagination больше не очищают видимые карточки; страницы добавляются по порядку без дублей, устаревшие ответы и повторный sentinel игнорируются, а Shorts не расходуют continuation основной ленты.
2. **Progressive audio и устойчивость:** первый тап атомарно забирает незавершённую загрузку у supervisor, подтверждённые HTTP-диапазоны переживают отмену и перезапуск, а пересекающиеся interruption/spoken prompt не дают преждевременный либо двойной resume.
- **Актуальный offline audio resolver:** первым используется JS-less VisionOS-клиент, затем Android VR и Android с обновлённой identity. Cold-start `visitorData` принимается и повторяется ровно один раз, а истёкший подписанный URL после HTTP 401/403/410 обновляет тот же client owner без потери уже подтверждённых байтов.
- **Ранний старт на слабой сети:** custom resource loader больше не обслуживает production playback, потому что запрос AVFoundation до конца ресурса заставлял его последовательно отдавать почти весь файл. AVPlayer теперь получает прямой HTTPS media URL, запускается немедленно и сам планирует byte ranges. Первый звук подтверждается свежим PCM либо естественным движением таймлайна, после чего возвращается системное осторожное buffering. Ручной режим выбирает минимальный совместимый AAC/M4A bitrate и сохраняется между запусками. Переключатель «Минимум / Обычное» вынесен в баннер текущего трека и на активную карточку загрузки. При смене качества тот же ролик перезапускается с сохранённой позицией.
- **Надёжный handoff после сетевой ошибки:** direct playback и durable offline download имеют разные обязанности, но один coordinator связывает их lifecycle. Истёкшая YouTube-ссылка обновляется ограниченное число раз. Если direct item не стал слышимым, завершился ошибкой либо завис после готовности офлайн-файла, плеер атомарно переключается на проверенный локальный M4A с сохранением позиции и Play/Pause. Состояние нового item больше не наследует ложное доказательство звука от старого, поэтому 100% файл не остаётся рядом с нерабочим player item.
- **Параллельное офлайн-сохранение без конкуренции с первым звуком:** sparse downloader стартует после первого аудио либо по 15-секундному fallback. До стабильного playback buffer используется одно соединение. Затем обычный режим может использовать до четырёх непересекающихся HTTP Range-сегментов, минимальный режим остаётся на одном, отсутствие Range support также оставляет один безопасный поток. Запись остаётся сериализованной, истёкший подписанный URL обновляется одним single-flight resolver-вызовом.
3. **Тактильность:** действия получили единый семантический haptic-контракт; рендер, прокрутка, пассивный прогресс и непрерывное движение ползунка намеренно исключены.
4. **Оформление:** прежний выбор «Системная / Тёмная / Светлая» полностью заменён девятью цельными темами: «Матрица», «Монохром», «Хронология», «Сияние, ночь», «Сияние, день», «Орбита», «Живой постер», «Сигнал» и «Призма». Старые сохранённые значения мигрируют без сброса остальных настроек, Share Extension получает согласованную светлую или тёмную схему.
5. **Русскоязычный поиск:** включённый по умолчанию строгий режим проверяет доступные metadata аудиодорожек и автоматической транскрипции, исключает недоказанные результаты и ограниченно добирает страницы без дублей.
6. **Граница авторизации:** Sign Out, refresh, cookie exchange, Keychain и downstream API используют версионированный снимок; запоздавшая операция старой сессии не может восстановить завершённую авторизацию.
7. **Публичное описание:** README, ограничения, история изменений и GitHub metadata синхронизированы с фактически проверенным состоянием AxrTube без готовых IPA и неподтверждённых обещаний.
8. **Liquid Glass и лента без рамок:** на iOS 26 системное стекло применяется к tab bar, поиску, mini-player и основным действиям. Обычные video cards больше не окружены контуром. «Матрица» и «Монохром» дают превью мягкий зелёный оттенок, «Хронология» добавляет временную ось, «Сияние» использует цветовой ambient-фон ролика, а «Орбита», «Живой постер», «Сигнал» и «Призма» предлагают четыре заметно отличающиеся композиции ленты.
9. **Now Playing chrome:** mini-player стал единым системным bottom accessory с предсказуемой высотой и safe area. На экране «Загрузки» глобальный mini-player скрывается, если текущий трек уже показан расширенной карточкой.
10. **Форма аудио и продолжение:** активная карточка «Загрузок» показывает форму волны, рассчитанную из реальных аудиоданных, и поддерживает точную перемотку. Позиции роликов сохраняются отдельно и восстанавливаются перед воспроизведением после перезапуска. Жест перемотки не открывает удаление, а полное swipe-удаление отключено.
11. **Живой аудиосигнал:** вместо анализа всей длинной записи карточка приоритетно декодирует короткое окно возле текущей позиции. Реальные RMS/peak значения получают динамическое усиление и attack/release smoothing, а перемотка остаётся отдельным ползунком и не конкурирует с прокруткой списка.
12. **Восстановление после внешнего аудио:** намерение пользователя отделено от системного состояния AVAudioSession. Код ждёт фактический interruption ended либо восстановление потерянного route и только затем повторно активирует сессию. Ручная пауза отменяет resume, а позиция AVPlayer, ползунок и Now Playing синхронизируются из одного playback clock без ложного сброса в ноль после lock или background.
13. **Диагностика медиа-источника:** отсутствие совместимого формата больше не маскируется системной ошибкой `NSURLError -1016`. Range loader проверяет HTTP status, MIME type, Content-Encoding и класс тела без сохранения содержимого. Непроигрываемый item снимается с Now Playing, а повтор сохраняет подтверждённые локальные диапазоны и запрашивает свежий источник.
14. **Бренд AxrTube:** отображаемое имя приложения, пользовательские тексты, extensions, публичная документация и красная фирменная иконка снова согласованы с брендом AxrTube. Внутренние target, module, bundle, URL scheme и storage identifiers сохранены для совместимости.
15. **Dynamic Island без дублирования:** после физической оценки отдельная playback Live Activity отключена для всех старых сохранённых режимов. Воспроизведение использует только системный Now Playing и системное оформление Dynamic Island, а lifecycle cleanup завершает старые и дублирующиеся playback activities.
16. **Книга стенограммы:** полная YouTube caption track автоматически превращается в кэшируемый русский документ. Русская дорожка имеет приоритет и используется напрямую, английская остаётся скрытым источником и переводится встроенным Apple Translation на iPhone. Автономный responsive HTML, Markdown UTF-8 и многостраничный searchable PDF строятся из одного русского канонического содержимого. Системная языковая пара подготавливается штатным интерфейсом iOS, а готовый перевод и документы повторно используются из локального кэша.
17. **Публичный GitHub AxrTube:** имя репозитория, корневые каталоги `AxrTube` и `AxrTubeApp`, workspace `AxrTube.xcworkspace`, README, privacy и support links, шаблоны, topics и галерея актуального интерфейса iOS 26 синхронизированы с текущим продуктом. Исторические технические identifiers оставлены только там, где они нужны для совместимости подписи, targets, modules, extensions, deep links, кэша и данных приложения.
18. **Галерея иконок AxrTube:** в настройках появился системный выбор из девяти цветов фона и девяти вариантов цвета букв AXR с крупным предпросмотром. Красный фон остаётся вариантом по умолчанию, каждый вариант является подписанной alternate app icon.
19. **Одна карточка на Lock Screen:** отдельная playback Live Activity полностью выключена, чтобы не дублировать системный Now Playing. Download-only Live Activity не затронута. Готовая стенограмма может дать одну короткую русскую выжимку в стандартном поле metadata. В настройках вручную выбираются Gemini, DeepSeek или Groq, конкретная модель и отдельный ключ в Keychain. Автоматического fallback между провайдерами нет. Кэш учитывает провайдер и модель, а `retry-after` показывает спокойный cooldown вместо красной ошибки и повторных запросов.
20. **AxrTube AI Lens:** готовая книга стенограммы получила режимы «Кратко», «Спросить» и «Связать». Разбор имеет три глубины и кэшируется, ответ по ролику обязан ссылаться на реальные абзацы с таймкодами, а локальный поиск связывает мысли между сохранёнными книгами без сети. Выбранные вручную провайдер и модель используют один captions owner без второго caption fetch; при недоступности сервиса сохраняется локальная выжимка.
21. **Согласованная тема стенограммы:** full-screen экран книги теперь получает выбранную тему AxrTube напрямую. Первый вход из mini-player или «Загрузок» больше не открывается в случайной тёмной системной среде при включённой светлой теме.
22. **Полный текст AI Lens:** верхний режим «Кратко» переименован в «Обзор», объём результата теперь обозначается как «Суть», «Кратко» или «Подробно» и сопровождается смысловым пояснением. Главная мысль и разбор больше не обрезаются ради Lock Screen, остаются выделяемыми и доступны вместе с действиями книги через общую вертикальную прокрутку.

### Другие подтверждённые изменения

- В «Медиатеке» технический раздел RSS заменён на «Каналы»: авторизованный пользователь видит алфавитный список подписок YouTube и может открыть ленту выбранного канала. Существующие RSS-модели и локальные данные сохранены для совместимости.
- Поиск после очистки запроса возвращается к discovery-ленте; pull-to-refresh повторяет только текущий контекст, а пустые и дублирующиеся идентификаторы карточек удаляются до layout.
- Общий publication pipeline сохраняет точную или достоверную относительную дату при enrichment и duplicate merge. Ленты Главной, рекомендаций, подписок, каналов и поиска сортируются от новых роликов к старым; неизвестные даты остаются внизу. История сохраняет порядок просмотра, а пользовательские плейлисты — заданный владельцем порядок.
- Лента канала применяет общие правила дат, скрытия Shorts и компактных карточек; добавлены русские состояния загрузки, пустого результата, ошибки и выхода из аккаунта.
- **Аудит-цикл устойчивости:** первый тап больше не отменяет подтверждённую офлайн-загрузку (`close` не помечает её как cancelled), legacy-кэш восстанавливается с корректным приоритетом операторов и 4-КБ зондовой проверкой, скраббинг мини-плеера защищён от гонки с commit, BotGuard ожидает ответ максимум 15 с и ретраит 408/429/5xx с backoff, watchtime-трекер не врёт после перемотки назад, sparse-fill таймаутится за 60 с, а attestation-токен логируется по длине, а не по содержимому. Long-form карточки с SHORTS-оверлеем больше не попадают в Shorts: бейдж учитывается только при длительности ≤ 180 с. Обновлены устаревшие тесты (нативные контролы embed намеренно скрыты, Shorts-лента идёт через поиск с WEB-клиентом, suspend-пауза уважает настройку фонового воспроизведения), поведенческие инварианты sparse-кэша и интеграционного таймлайна переписаны без тавтологий.
- **Параллельное скачивание аудио:** фоновая докачка переведена на 8 параллельных range-соединений (2 в слабой сети) и крупные чанки по 2 МБ. YouTube троттлит один большой GET до скорости воспроизведения, но обслуживает ограниченные диапазоны на полной скорости (потолок ~10 МБ на диапазон), поэтому параллельные диапазоны дают кратный выигрыш без риска бана. Чанки воспроизведения (128 КБ) и инварианты слабой сети не изменены.
- **Перемотка на полностью скачанном аудио:** после завершения офлайн-докачки во время прослушивания AxrTube сразу переключает воспроизведение с сетевого item на готовый локальный файл (с сохранением позиции и намерения Play). Раньше AVPlayer оставался на сетевом источнике, чей планировщик не знает про sparse-кэш, и после перемотки заново качал диапазоны из интернета — на слабой связи звук застревал и не возобновлялся даже по нажатию Play. Теперь скраб на завершённом файле мгновенный и не зависит от сети.

---

## [4.5] – 2026-06-11

### Added
- **TOS-compliant player is now the default on iOS** — playback uses an embedded YouTube IFrame player (WKWebView) with native SwiftUI controls, replacing the AVPlayer-based stream-extraction pipeline on iOS. Removes the entire class of playback failures caused by CDN/geo blocks, BotGuard/PO-token issues, and HLS/DASH manifest-parsing errors
- **Comments** added to the player's "..." overflow menu on iOS

### Changed
- Existing iOS installs are migrated automatically to the new default player; the experimental `useTOSPlayerOnIOS` toggle has been removed
- Video quality/ABR on iOS is now controlled entirely by YouTube's own player — manual quality and "max resolution" selection no longer apply on iOS
- Speed and "..." menu controls repositioned next to the back button on iOS

### Fixed
- **Mini-player** — video now keeps playing when minimized instead of stopping
- Playback speed pill stuck showing "Normal (1x)" after a speed change
- Audio occasionally cutting to silent shortly after auto-unmute
- Full-screen player no longer lingers after minimize/stop
- Safe-area inset double-counted on the back button

---

## [4.1] – 2026-05-27

### Added
- **BotGuard PO token pipeline** — complete WKWebView-based `pot=` token extraction with websafe base64 fallback; token injected into adaptive streaming requests to satisfy YouTube's enhanced bot-detection
- **AVC-only codec pinning** — "Prefer H.264" toggle in player settings pins DASH and HLS streams to AVC variants for maximum compatibility (#206)
- **Serbian & Croatian localizations** — two new languages added; 19 missing translation keys filled across all existing languages
- **HLS audio rendition proxying** — `#EXT-X-MEDIA` audio playlist URLs rewritten to `ytwebhls://` so the local proxy correctly forwards cookies to rendition segments

### Fixed
- **60 s `loadTracks` stall on SABR streams** — SABR stream detection added; `c=TVHTML5` URLs bypass the stall-prone audio-track load path (#204)
- **Dubbed audio broken via WKWebView** — HLS proxy now fetches the per-quality master URL rather than the generic master, restoring dubbed tracks (#205, #205b)
- **WKWebView cookies not forwarded to HLS proxy** — all `WKWebView` cookies, including the `googlevideo.com` domain, are now included in local proxy requests (#207)
- **8 s `loadTracks` stall** — `rqh=1` adaptive composition skipped when no `googlevideo.com` cookies are present, eliminating the hang (#208)
- **WKWebView HLS proxy silently skipped** — early `rqh=1` guard removed; proxy is now attempted regardless of cookie state at startup (#209)
- **Quality switch failed after muxed fallback** — fresh WKWebView extraction is now triggered whenever a quality change follows a muxed-only fallback (#210)
- **Stale WKWebView HLS URL used** — cached URL validity probed before constructing `AVPlayerItem`; expired URLs trigger immediate re-extraction (#211)
- **Quality button always visible** — changed from hidden-when-empty to disabled-when-empty; button remains visible but non-interactive when no quality options are available (#186)
- **Audio tracks not loaded after WKWebView HLS** — `loadAudioTracks(from:)` now called inside the `tryWebViewHLS` `readyToPlay` handler

---

## [3.0] – 2026-05-22

### Added
- **DASH adaptive quality switching** — selecting a quality tier for DASH streams rebuilds `AVMutableComposition` with the matching video track; a pending quality label is shown during the switch; the initial load is capped to the display's native resolution; VP9 variants excluded for device compatibility
- **macOS (Mac Catalyst) support** — `NSViewRepresentable` AVPlayerLayer renders in the macOS window; App Sandbox, Hardened Runtime, and `PrivacyInfo.xcprivacy` (network/API usage declarations) added; `SUPPORTED_PLATFORMS` updated; macOS build succeeds
- **TV client attestation token** — `fetchAttestationToken` injected into the TVHTML5 client authentication payload to satisfy YouTube's enhanced bot-detection for signed-in sessions
- **"Remove from Watch Later" action** — video cards inside the Watch Later playlist show a destructive remove option in the context menu; cards outside the playlist continue to show "Save to Watch Later"
- **Stats for Nerds** added to the player overflow menu on all platforms

### Fixed
- **tvOS settings tab required double-click to open** — `MainTVTabView` `TabView` now uses a selection binding; a single remote press selects the tab
- **tvOS video description and comments panels could not be closed** — `isAnyOverlayVisible` now includes both panel states so the player no longer intercepts the Menu button; each panel has its own `.focusScope` + `.onExitCommand`
- **tvOS quality preference reset to Auto on every launch** — `SettingsStore.init()` was unconditionally overwriting `preferredQuality` at startup
- **tvOS overflow menu text low contrast** — focused row highlight changed from `white.opacity(0.15)` to `gray.opacity(0.35)`
- **Playlist auto-advance not working from Search results** — `SearchView` now populates `CurrentQueueStore` before starting playback; macOS compact-grid path also fixed
- **HLS manifest cache** TTL raised from 5 min to 30 min; cache entry correctly invalidated on a 403 recovery path to prevent stale variant URLs

---

## [2.8] – 2026-05-19

### Added
- **Audio language selector in iOS fullscreen player** — speed, quality, and audio-track pill buttons in the quick-access row below the scrub bar for one-tap access without opening the overflow menu
- **tvOS player overflow menu expanded** — Captions and Audio Track rows added; Audio Only toggle available on tvOS; picker overlays no longer restricted to iOS
- **tvOS UI test coverage** — six new test suites: Settings (7 tests), Home Feed (5 tests), Library Navigation (8 tests), Player Controls (9 tests), Playback Regression (5 tests), Audio & Caption Pickers (6 tests)
- Library Subscriptions chip shortened to **"Subs"**

### Fixed
- **No audio after quality change in fullscreen** — quality-reload paths now call `loadAudioTracks(from:)` on every new `AVPlayerItem`
- **No audio when quality is not set to Auto** — audio track configuration was bypassed in manual quality selection paths
- **All audio tracks showing as "Original"** — `isOriginal` detection uses `hasMediaCharacteristic(.isMainProgramContent)` with `DEFAULT=YES` as fallback; per-track logging added
- **Caption track not remembered between videos** — last selected caption language persisted in `AppSettings` and re-applied on load
- **Captions obscuring the scrub bar** — caption overlay repositioned above the progress bar
- **Player controls hiding too quickly in fullscreen** — auto-hide timeout increased by 50%
- **Play/pause and navigation button tap targets too small** — enlarged from 44 pt to 68 pt
- **1440p quality not applied on initial load** — HLS variant fetch and `applyQualityPreference` added to all fallback entry points
- **tvOS settings missing seek-interval picker and preferred audio language selector** — `#if !os(tvOS)` guard removed from both pickers
- **tvOS long-press triggering both context menu and playback** — `onSelect` closure added to `VideoCardView`; `.onTapGesture` co-located with `.contextMenu` so the gesture arbiter suppresses playback on long-press
- **tvOS settings navigation bar hidden after scroll-down-then-up** — `.toolbar(.hidden)` guard changed from `#if os(iOS)` to `#if !os(macOS)`
- **tvOS SponsorBlock skip button not focusable** — `isSkipToastActive` gate routes focus to the skip button when a segment is detected and restores player focus on dismiss
- **Audio track selector missing from iOS overflow menu** — `moreMenuAudioTrackRow` restored (accidentally removed in a prior refactor)
- **Watch Later playlist playing videos in wrong order** — `CurrentQueueStore.replaceAll(with:)` now called before starting playback in all playlist entry points
- **Hide Shorts not filtering Subscriptions feed** — three detection gaps fixed: `parseVideoRenderer` Shorts signals, RSS feed detection via playlist enrichment, History view was incorrectly filtering non-Shorts
- **Intermittent "first video cannot be played" on launch** — stale iOS-client preload cache now invalidated before a fresh client fetch in the muxed-only fallback path
- **"Original Track" missing from tvOS preferred audio language picker**
- **Firebase network hardening**: VPN/IP-block banner suppresses "Try Again" button; Android muxed-only fallthrough no longer records a non-fatal; `NSURLError -999` (cancelled) added to transient-suppression list; request timeout raised from 20 s to 30 s

---

## [2.7] – 2026-05-16

### Added
- **Quick-access player controls** (iOS) — speed, quality, audio-track, and sleep-timer pill buttons below the scrub bar for one-tap access without opening the overflow menu
- **iCloud sync for local data** — subscriptions, watch state, current queue, and RSS feeds sync via `NSUbiquitousKeyValueStore`; opt-in toggle in Settings → General
- **Video publish date in search results** — upload age label shown in grid and compact card layouts for search results and playlist views
- **Shorts auto-pagination** — the home feed Shorts section automatically loads a second page when the initial batch is below 6 (iPhone) or 8 (tvOS)
- **Downloads screen** — Library → Downloads lists locally downloaded videos; tap to play offline, swipe to delete

### Fixed
- **OrientationManager crash on iOS 26** (EXC_BREAKPOINT, Crashlytics 1bce7ef1) — `requestGeometryUpdate` error handler was inheriting `@MainActor` isolation and invoked on a background GCD queue on iOS 26+; extracted as an explicit `nonisolated` file-scope function
- **Watch history not updating for signed-in users** — `PlaybackViewModel`'s own `InnerTubeAPI` instance was not receiving token refreshes; `WatchtimeTracker` was sending anonymous pings
- **Streaming spinner not dismissing after video loads** — `isLoading = false` moved into the `.readyToPlay` observer; audio-only path also fixed
- **App launch interrupting background audio** — premature `AVAudioSession.setActive(true)` removed from `PlaybackViewModel.init()`
- **Shorts not loading on cold launch** — `fetchShorts` and `fetchShortsMore` now use `postTV()` (TVHTML5 client) to match the TV OAuth token scope; WEB client was returning HTTP 400
- **Mini-player overlapping bottom tab bar** (iPhone portrait) — mini-player now rendered as `overlay(alignment: .bottom)` above the `TabView` safe area; `TabBarBottomInsetKey` preference captures the actual tab bar height
- **16 QPB-identified bugs**: `extractNumber` undercounting K/M/B view-count suffixes; `viewCount` always `nil` in all renderers; fallback paths (`retryWithFallbackPlayer`, `retryWith403Recovery`, `retryWithAdaptiveComposition`) dropping `playerInfo` / `availableFormats` / `availableCaptions`; `loadAsync` race on superseded tasks; `pingTrackingURL` silently discarding errors; `evictAuthSensitiveData` skipping `VideoDiskCache`; auth token captured at prefetch-task creation time (stale after refresh); `WatchtimeTracker` using stale URLs post-eviction; `phase2Task` skipped in all fallback paths; `tryLoadAudioURL` unconditionally resetting audio-only mode on any error; `itemObserverTask` race on item replacement; `endObserverTask` not restarted in audio-only mode; `parsePlaylistVideoRenderer` not implemented

---

## [2.6] – 2026-05-14

### Added
- **Safari Web Extension** — new `iPocketTubeSafariExtension` target (`manifest.json` + `content.js`) intercepts YouTube watch, Shorts, youtu.be, and Music URLs in Safari and redirects them to `ipockettube://video/<id>` without any user tap; `YouTubeLinkHandler` extended to recognise `music.youtube.com/watch?v=` URLs so the extension and the app URL handler stay in sync; `iPocketTubeSafariExtensionURLCoverageTests` (7 tests) verify every manifest match pattern
- **Auto quality caps at display native resolution** — when `preferredQuality == .auto`, `PlaybackViewModel+Fallback.qualityCapVideoURL` now calls `displayMaxVideoHeight()` (returns `min(nativeBounds.width, nativeBounds.height)` on UIKit, 1080 on tvOS) and passes the result as `preferredMaxHeight` to `selectBestVideoFormat`; initial DASH composition and HLS `preferredMaximumResolution` hints use the same value; previously Auto unconditionally picked the highest available format regardless of screen pixel density

### Fixed
- **DASH manual quality switching broken for many videos** — `PlaybackQualityManager.reloadDASHItem` was resolving the video URL from `availableFormats` (populated by the TV auth / TVHTML5 client), whose adaptive entries use SABR-protocol URLs that `AVURLAsset.loadTracks` cannot open (AVFoundation error −11828); quality switches now resolve the video URL from `playerInfo.formats` (populated by the AndroidVR client, which returns standard CDN MPEG-4 URLs); a `selectBestVideoFormat(from:preferredMaxHeight:)` helper matches the requested quality tier to the closest available itag; the TVAuth `availableFormats` set is retained for the picker display only
- **DASH quality switch silently rebuilding at wrong resolution** — `reloadDASHItem` used `selectBestVideoFormat` without verifying the resolved height satisfied the request; when the requested tier (e.g. 480p) was absent from `playerInfo.formats`, `selectBestVideoFormat` fell back to the highest available format (e.g. 720p) and `AVMutableComposition` succeeded at that height while `selectedFormat` still reflected 480p; a `matchedFmt.height <= fmt.height` guard now rejects the fallback result and falls through to the `availableFormats` URL for proper error-recovery when the tier is absent from `playerInfo.formats`
- **Quality picker showing 144p/240p only for DASH videos** — TVAuth adaptive format entries had `height = 0` because TVHTML5 SABR responses omit the `height` field; `parseFormats` now extracts the height from the `qualityLabel` string (e.g. `"720p"` → 720) when `height == 0`, so all adaptive tiers appear correctly in the picker
- **AndroidVR client returning `LOGIN_REQUIRED` bot-detection error** — `postAndroidVR` now includes the `X-Goog-Visitor-Id` header populated from the `visitorData` field of the preceding TVAuth `/player` response; the shared `URLSession` (carrying YouTube authentication cookies from TV sign-in) is used instead of an ephemeral session; together these signals satisfy YouTube's bot-detection check for the AndroidVR client
- **Crash on age-restricted / region-locked videos** (1,048 iOS + 130 tvOS events, issue NW-3) — TV authenticated client sometimes returns a `PlayerInfo` with `hlsURL = nil` and no usable adaptive streams (muxed-only TVHTML5 URL); `PlaybackViewModel+Loading` now checks `tvInfo.hlsURL == nil && bestAdaptiveVideoURL == nil` immediately after the TV fetch and falls straight to `fetchPlayerInfoAndroid` before creating an `AVPlayerItem`, eliminating the `AVFoundationErrorDomain -11828` crash; `TVClientHLSNilFallbackTests` (8 tests) added
- **Audio-only mode silently stalling on playback start** — `tryLoadAudioURL(_:userAgent:)` now calls `setupAudioItemObserver(_:)` before `player.replaceCurrentItem(with:)`, wiring up `itemObserverTask` to catch `.failed` status (resets `isAudioOnlyMode = false` and propagates the error) and `.readyToPlay` (calls `loadAudioTracks(from:)`); previously a failed audio item had no observer and the player hung silently; `AudioOnlyModeUITests` (`testAudioOnlyModeOpensVideoWithoutError`) added
- **Mini player X button sometimes restoring fullscreen** — `fullScreenBinding` setter in `RootView` was calling `playerState.minimize()` whenever `currentVideo` cleared to `nil`; because `stop()` sets `presentation = .hidden` asynchronously, the setter raced and re-promoted state to `.miniPlayer`; setter is now a no-op (the `LandscapeFullScreenCover` UIKit coordinator already manages dismissal)
- **Audio track selection not working after fallback recovery** — `audioSelectionGroup` and `audioOptionsByID` were never refreshed when the Android fallback player, adaptive composition fallback, or 403-recovery path created a new `AVPlayerItem`; `retryWithFallbackPlayer`, `retryWithAdaptiveComposition`, and `retryWith403Recovery` in `PlaybackViewModel+Fallback` now call `loadAudioTracks(from:)` in their `.readyToPlay` observers, matching the existing pattern in the normal load and quality-change paths
- **More menu overflowing and unusable in landscape mode** (GitHub issue #45, contributor say4n) — `.frame(maxHeight: 520)` was too tall for compact vertical size class; `moreMenuOverlay` now uses 320 pt max-height in `verticalSizeClass == .compact`, adds `.safeAreaPadding(.horizontal)` plus 36 pt extra horizontal padding when landscape, keeping the menu within the live area and scrollable to the Cancel row; `player.moreMenu.scrollView` accessibility identifier added
- **"Hide Shorts" setting not filtering Shorts in Search, Library, and Channel views** (GitHub issue #41) — `AppSettings.hideShorts` was applied only in `HomeView` and `BrowseView`; `SearchView` and `LibraryView` now inject `SettingsStore` via `@Environment` and filter results before passing to `VideoGridSection`; `ChannelView.filteredVideos` extended to apply the same predicate; `RSSFeedsView.videoList` also updated for consistency; `HideShortsFilterTests` (6 tests) added
- **Audio-only mode silently stalling on playback start** — `tryLoadAudioURL(_:userAgent:)` now calls `setupAudioItemObserver(_:)` before `player.replaceCurrentItem(with:)`, wiring up `itemObserverTask` to catch `.failed` status (resets `isAudioOnlyMode = false` and propagates the error) and `.readyToPlay` (calls `loadAudioTracks(from:)`); previously a failed audio item had no observer and the player hung silently; `AudioOnlyModeUITests` (`testAudioOnlyModeOpensVideoWithoutError`) added
- **Mini player X button sometimes restoring fullscreen** — `fullScreenBinding` setter in `RootView` was calling `playerState.minimize()` whenever `currentVideo` cleared to `nil`; because `stop()` sets `presentation = .hidden` asynchronously, the setter raced and re-promoted state to `.miniPlayer`; setter is now a no-op (the `LandscapeFullScreenCover` UIKit coordinator already manages dismissal)
- **Audio track selection not working after fallback recovery** — `audioSelectionGroup` and `audioOptionsByID` were never refreshed when the Android fallback player, adaptive composition fallback, or 403-recovery path created a new `AVPlayerItem`; `retryWithFallbackPlayer`, `retryWithAdaptiveComposition`, and `retryWith403Recovery` in `PlaybackViewModel+Fallback` now call `loadAudioTracks(from:)` in their `.readyToPlay` observers, matching the existing pattern in the normal load and quality-change paths
- **More menu overflowing and unusable in landscape mode** (GitHub issue #45, contributor say4n) — `.frame(maxHeight: 520)` was too tall for compact vertical size class; `moreMenuOverlay` now uses 320 pt max-height in `verticalSizeClass == .compact`, adds `.safeAreaPadding(.horizontal)` plus 36 pt extra horizontal padding when landscape, keeping the menu within the live area and scrollable to the Cancel row; `player.moreMenu.scrollView` accessibility identifier added
- **"Hide Shorts" setting not filtering Shorts in Search, Library, and Channel views** (GitHub issue #41) — `AppSettings.hideShorts` was applied only in `HomeView` and `BrowseView`; `SearchView` and `LibraryView` now inject `SettingsStore` via `@Environment` and filter results before passing to `VideoGridSection`; `ChannelView.filteredVideos` extended to apply the same predicate; `RSSFeedsView.videoList` also updated for consistency; `HideShortsFilterTests` (6 tests) added

---

## [2.5] – 2026-05-12

### Added
- **Landscape lock button** (iOS) — rotation icon in the player top bar locks orientation in landscape; the "Landscape Always Play" toggle was removed from Settings
- **Audio-only button in player controls** (iOS) — waveform icon in the bottom player bar toggles audio-only mode; the Settings toggle was removed; tvOS retains the overflow menu row
- **Toast on mode switches** — "Audio-Only Mode" / "Video Mode" notification shown when toggling playback mode
- **DeArrow titles and thumbnails** — cached branding applied in `VideoCardView` grid and compact layouts and to `currentVideo` on load; respects the `deArrowEnabled` setting

### Fixed
- **Mini player "X" button not stopping audio** — `AVAudioSession.setActive(false)` called in `PlaybackViewModel.stop()` on dismiss
- **Overflow menu too wide and large in portrait** — `.font(.subheadline)` applied to all rows; max width constrained to 80% of screen width
- **Portrait player next/back buttons had small tap targets** — enlarged to 68 pt with circular background matching other control buttons
- **Shorts incorrectly included in playlists** — `displayVideos` filter added to `PlaylistView`
- **Video not reloading after stop and replay** — `itemObserverTask` and `endObserverTask` now cancelled in `stop()`
- **Preferred audio language ignored on AI-dubbed videos** — `DEFAULT=YES` HLS track priority corrected; device language preference evaluated before YouTube's marked default
- **Shorts visible despite "Hide Shorts" being enabled** — `parseLockupViewModel` guard relaxed to correctly detect `reelWatchEndpoint` as `isShort = true`
- **Pagination failing on transient network errors** — all 5 pagination entry points wrapped with `retryWithBackoff` (up to 3 attempts, 1–2 s exponential delay)

---

## [2.4] – 2026-05-10

### Fixed
- **Audio cutting out when manually changing video resolution** — `reloadHLSItem` and `reloadHLSItemH264Capped` in `PlaybackViewModel+Quality` created a new `AVPlayerItem` on quality switch but never called `loadAudioTracks(from:)`; `audioSelectionGroup` and `audioOptionsByID` stayed stale from the old item so `selectAudioTrack()` silently no-opped and AVPlayer fell back to muted defaults; one-line fix adds `loadAudioTracks(from: item)` in both `.readyToPlay` handlers
- **Audio quality improved to match official YouTube app** — `AVPlayerItem.audioTimePitchAlgorithm` defaulted to `.timeDomain` which introduces subtle artefacts at normal playback speeds; changed to `.spectral` in `PlaybackViewModel+Loading` when the `AVPlayerItem` is created (both HLS and adaptive paths)
- **tvOS video quality stuck at perceived ~420p despite 2160p setting** — `fetchHLSVariantURLs()` unconditionally replaced HEVC variants with H.264 for all platforms (added originally for Simulator compatibility); on tvOS HEVC is fully supported and YouTube lists it first in the manifest, so H.264 selection forced lower perceived quality; codec preference is now guarded `#if !os(tvOS)` so tvOS keeps the first (HEVC) variant while iOS/macOS still prefer H.264; `preferredPeakBitRate` hints added alongside `preferredMaximumResolution` in `reloadHLSItem` and initial load; `PlaybackQualityTests` (10 tests) added
- **Duplicate video cards causing blank cells in Home and Subscriptions feeds** — four separate deduplication gaps allowed duplicate `Video.id` values into `ForEach` arrays: (1) `fetchMoreVideos(.home)` returned `flatMap(\.videos)` with no dedup; (2) `HomeViewModel.loadMore` captured `existingIds` once before the append loop so intra-`newVideos` duplicates slipped through; (3) `BrowseViewModel.mergeIntoFirstGroup` had the same static-set gap; (4) `fetchNextPage(.home)` appended new groups without cross-group ID filtering; all four fixed with a growing-set pattern (`var seen = Set<String>(); filter { seen.insert($0.id).inserted }`); `mergedVideos` computed property gains a safety-net pass; `HomeFeedNoDuplicatesUITests` (3 tests) added
- **tvOS centre-zone double-tap and d-pad focus failures in player UI tests** — five UI tests were failing: `ToastModifier` had no accessibility identifier so toast queries raced against 2 s expiry; `ProgressView` spinner absorbed tap gestures; `SettingsStore` leaked persisted UserDefaults state between tests; SponsorBlock auto-seek disrupted player gesture tests; `testLandscapeAlwaysPlayBackButtonReturnsHome` used `guard` inside `defer` (compile-valid but never ran on error path); fixes: `.accessibilityIdentifier("player.toast")` on toast text; `.allowsHitTesting(false)` on spinner overlay; `--uitesting-reset-settings` launch-arg handler in `SettingsStore.init`; accessibility identifiers on SponsorBlock picker/NavigationLink; `testDoubleTapCentreZoneTogglesFitFill` converted from live Home feed to `--uitesting-deeplink-video=` fixed video ID to eliminate feed-timing flakiness; `guard`→`if` in defer block

---

## [2.3] – 2026-05-10

### Added
- **Shorts section on home screen** — `ShortsCardView` (portrait 9:16 thumbnail with dark gradient title overlay and duration badge) and `ShortsRowView` (horizontal `LazyHStack`, ~120 pt wide on iPhone) render above the main grid; `HomeViewModel` partitions `mergedVideos` into `homeVideos` (non-Shorts) and `homeShortsVideos` at the computed-property level with no extra network call; Shorts are identified by `Video.isShort` set at parse time from `reelWatchEndpoint`, `TILE_STYLE_YTLR_SHORTS`, or `parseReelItemRenderer`
- **Per-device YouTube recommendations setting** — `InnerTubeAPI.visitorData` (previously declared but never populated) is now extracted from `responseContext` on each browse/search response and injected into subsequent requests via `makeBody(includeVisitorData: true)`; different `visitorData` per device produces different recommendation graphs per device; toggle in Settings → Interface; disabled resets `visitorData = nil` on the next browse call

---

## [2.2] – 2026-05-06/07

### Added
- **Local Subscription Management** — follow/unfollow channels without a Google account; feeds backed by `LocalSubscriptionStore` (actor, UserDefaults persistence) and `LocalSubscriptionFeedService` (RSS fetch with InnerTube fallback); channels sorted alphabetically, feed videos sorted newest-first
- `YouTubeRSSParser` — XML-based RSS parser for YouTube channel feeds (`https://www.youtube.com/feeds/videos.xml?channel_id=CHANNEL_ID`) using Foundation `XMLParser`; background refresh via `LocalSubscriptionFeedCache`
- **RSS Feeds feature** — users can add arbitrary YouTube channel RSS feed URLs; `RSSFeedInfo` model + `RSSFeedStore` actor (JSON in UserDefaults); `RSSFeedsViewModel` fetches all active feeds concurrently with `withTaskGroup`, deduplicates by video ID, sorts newest-first; `RSSFeedsView` (list with toolbar add button), `AddRSSFeedView` (sheet), `ManageRSSFeedsView` (delete/toggle); Share Extension detects RSS URLs and writes `pendingRSSFeedURLs` to shared UserDefaults app group for `AppEntry` to drain on launch; `RSSFeedStoreTests` unit tests
- **Audio-only playback mode** — `PlaybackViewModel+AudioOnly` provides `loadAudioOnlyItemIfEnabled()` with a three-step chain: (1) iOS-client `bestAdaptiveAudioURL` (zero extra network cost), (2) `fetchPlayerInfoAndroidVR()` using `ANDROID_VR` client (nameID 28, version 1.65.10, Oculus UA, no PO Token required), (3) silent HLS fallback with `isAudioOnlyMode = false` reset; live streams excluded; thumbnail overlay shown via `audioOnlyThumbnailOverlay` in `PlayerView+Lifecycle`; quality picker hidden in audio-only mode; "Audio Only" toggle in Settings (iOS)
- **Preferred Audio Language setting** — `Picker` in Settings → Player (iOS only) with options: System Default, English, Spanish, French, German, Japanese, Korean, Portuguese, Chinese (Simplified), Original Track; `autoSelectAudioTrack()` priority updated: saved explicit language → `"original"` sentinel selects HLS `DEFAULT=YES` track → exact language code match → prefix match (e.g. `"en"` matches `"en-US"`) → English fallback → tracks.first; `AudioTrackSelectionTests` extended (6 new tests)
- **Picture-in-Picture** (iOS) — PiP session management in `PlaybackViewModel`; toggle in Settings
- "Landscape Always Play" setting — auto-rotate to landscape when a video starts on iPhone
- **poToken groundwork** — `PoTokenProvider` protocol; `PlayerInfo.applyingPoToken(_:)` appends `&pot=<token>` to all format/HLS/DASH URLs; `InnerTubeAPI` stores `poToken`/`poTokenVideoId`/`poTokenExpiry`; `makeBody(includePoToken:)` injects `serviceIntegrityDimensions.poToken`; `ServerPoTokenProvider` (developer tool, hidden behind `poTokenServiceURL` setting) POSTs `{"videoId":"..."}` and expects `{"token":"..."}`; `PoTokenInjectionTests` (6 tests)
- **VPN "cannot play video" hardening** — `APIError.ipBlocked(String)` added; `InnerTubeAPI+Player.parsePlayerInfo` detects VPN/proxy/bot keywords in `playabilityStatus.reason` and throws `.ipBlocked` instead of `.unavailable`; `PlaybackViewModel+Loading` short-circuits the retry storm on `.ipBlocked` (one TV-auth attempt for signed-in users; Android fallback skipped); `NWPathMonitor` in `InnerTubeAPI` resets `visitorData = nil` on VPN connect/disconnect; inert "Force IPv4 (VPN users)" toggle in Settings; `CrashlyticsLogger` records `vpn_ip_block = true` non-fatal; `IPBlockDetectionTests` (12 tests)
- **VideoPreloadCache — advanced caching (Phases E–K)**:
  - *Phase E — Progressive `loadAsync`*: `loadAsync` split into Phase 1 (critical path: cache consume → `fetchPlayerInfo` retry chain → AVPlayer setup → `isLoading = false`) and Phase 2 (`.utility` Task running concurrently: SponsorBlock cache-miss fetch, `nextInfo`, `endCards`, `trackingURLs`, neighbour prefetch); `phase2Task` cancelled in `load()` and `stop()`; `ProgressiveLoadPhase2Tests` (7 tests)
  - *Phase F — Stale-while-revalidate (SWR)*: `CachedVideoData.DataType` enum (`.nextInfo`, `.endCards`, `.sponsorSegments`, `.deArrowBranding`); `staleFields: Set<DataType>` returned by `consume()`; stale values returned immediately (non-nil) while Phase 2 revalidates in background; `VideoPreloadCacheTTLTests` (16 tests)
  - *Phase G — Priority prefetch queue*: `PrefetchPriority` enum (`.speculative`, `.visible`, `.immediate`, `.userFocused`); `[PrefetchRequest]` queue bounded at 20 items; overflow evicts lowest-priority item; worker pool of 5 slots (WiFi) / 2 (cellular); `VideoCardView` passes `.visible`; neighbour prefetch passes `.speculative`; `PrefetchQueueTests` (5 tests)
  - *Phase H — In-flight coalescing*: `inFlightPlayerFetches: [String: Task<PlayerInfo?, Never>]` on `VideoPreloadCache`; `getOrFetchPlayerInfo(videoId:)` returns existing in-flight task or creates a new one; `loadAsync` coalesces against in-flight prefetch before falling to its own fetch; `InFlightCoalescingTests` (4 tests)
  - *Phase I — TTL tuning*: `nextInfoTTL` 5 min → 20 min; `sponsorTTL` 1 h → 2 h; `deArrowTTL` 1 h → 4 h; `endCardsTTL` 1 h → 4 h
  - *Phase J — Disk persistence*: `VideoDiskCache` writes `nextInfo`, `endCards`, `sponsorSegments`, `deArrowBranding` as JSON under `Caches/st-video-cache/<videoId>-<dataType>.json`; LRU eviction at 20 MB; `playerInfo` and `trackingURLs` never written (CDN/auth-sensitive); `Codable` added to `NextInfo`, `EndCard`, `EndCard.Style`, `Chapter`, `DeArrowService.BrandingInfo`; `VideoDiskCacheTests` (7 tests)
  - *Phase K — Network-aware throttling*: `NWPathMonitor` in `VideoPreloadCache`; offline → 0 workers (pauses all prefetches); cellular/constrained → 2 workers, `playerInfo`+`nextInfo`+`sponsorSegments` only; WiFi → 5 workers, all data types; `networkCap` and `allowedPrefetchDataTypes` computed properties
- `YouTubeRSSParserTests`, `LocalSubscriptionStoreTests`, `LocalSubscriptionFeedServiceTests` unit tests

### Fixed
- Shorts player section feed sometimes not visible when test starts — added explicit wait for section feed before asserting

---

## [2.1] – 2026-05-04/05

### Added
- **Landscape playback for iOS** — `OrientationManager` + `LandscapeAwareHostingController` replace SwiftUI's portrait-locked hosting controller so UIKit accepts `requestGeometryUpdate(.landscape)` while the player is on screen
- **tvOS PlayerView** (`PlayerView+tvOS`) — full d-pad navigation with `TVPlayerControl` focus model; Siri Remote play/pause, seek, menu/back handling
- **Now Playing** — lock screen and Dynamic Island metadata, artwork, and transport controls via `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`
- **Playback quality selection** — manual format override with `PlaybackViewModel+Quality`; HLS variant URL fetching; toast confirmation via `ToastModifier`
- **Previous/next video navigation** — history stack in `PlaybackViewModel+Navigation`; `playNext()` / `playPrevious()`
- **Caption track selection** — VTT fetch and live cue overlay in `PlaybackViewModel+Captions`
- **Sleep timer** — countdown task in `PlaybackViewModel+SleepTimer`
- **Like/Dislike actions** — `PlaybackViewModel+LikeDislike`
- **Stats for Nerds** overlay — `PlaybackViewModel+StatsForNerds`
- `PlayerView+Overlays` and `PlayerView+PickerOverlays` — player UI extracted into focused extension files
- `ToastModifier` — self-dismissing pill message (auto-clears binding after 2 s)
- `ScrollOffsetPreserver` — saves and restores LibraryView scroll position across tab switches
- `VideoDownloadUITests` — UI test for both download methods: (A) player more menu → "Download to Gallery" using `--uitesting-deeplink-video=JhCjw57u8mQ` launch arg; (B) video card long-press context menu → "Download to Gallery"; `player.moreMenu.downloadButton` accessibility identifier added to download button in `PlayerView+Overlays`
- Updated app icon (dark variant added)

### Changed
- `PlaybackViewModel` split into 14 focused extensions (Auth, AudioTracks, Captions, Controls, ControlsVisibility, Fallback, LikeDislike, Loading, Navigation, NowPlaying, Observers, Quality, SleepTimer, SponsorBlock, StatsForNerds)
- `InnerTubeAPI+VideoRenderers.swift` (~1,100 lines) split into `InnerTubeAPI+VideoGroupRows.swift` (multi-shelf home row parsing), `InnerTubeAPI+VideoRendererParsers.swift` (individual renderer parsers: `parseTileRenderer`, `parseLockupViewModel`, `parseReelItemRenderer`, `parseVideoRenderer`), and `InnerTubeAPI+VideoGroupFlat.swift` (flat video group fallback parsing); all other files kept under 1,000 lines
- Enhanced error handling and retry logic for failed stream requests
- BrowseViewModel recommended-video fetch deduplicates results
- Improved focus management for picker overlays on tvOS

### Fixed
- **Subscriptions feed not strictly sorted in chronological order** — YouTube returns each page sorted newest-first, but `BrowseViewModel.mergeIntoFirstGroup` and `HomeViewModel.loadMore` appended pages without global re-sort, so videos from page 2 appeared out of position relative to page 1; `videoGroups[0].videos` is now re-sorted by `publishedAt` descending after each `mergeIntoFirstGroup` call (subscriptions case) and after each `loadMore` append in `HomeViewModel`; `SubscriptionsSortTests` (pagination merge test) added

---

## [2.0] – 2026-05-03/04

### Added
- **Localisation** — `Localizable.xcstrings` string catalog covering the full app
- `InnerTubeAPIProtocol` — protocol abstraction over `InnerTubeAPI` enabling mock injection in tests
- `ViewModelLogger` — structured per-category logging routed to Crashlytics
- Sign-in UI: one-tap "Open Activation Page" button (opens pre-filled URL); "Or scan from another device" QR divider section
- Sign-in progress guard in `AuthService` — prevents concurrent device-code flows
- Comprehensive unit tests: `WebVTTParserTests`, `VideoStateStoreTests`, `ViewModelTests`, `VideoPreloadCacheTTLTests`, `SearchFilterUITests`, `YouTubeLinkHandlerTests`
- UI test suites: Channel, Library (History / Playlists / Subscriptions), Player controls, Recommended chip pagination, Search, Settings, Shorts, Audio track selection
- GitHub issue templates (bug report, feature request)

### Changed
- Updated Privacy Policy
- Various internal refactors for readability and maintainability

### Fixed
- **Login failures requiring multiple retries on iPhone** — `AuthService` gained `retryWithBackoff<T>()`: up to 3 attempts with 1–10 s exponential delay on transient `URLError` codes (timeout, connection lost, offline, SSL); `requestDeviceCode`, `fetchUserInfo`, `validAccessToken`, `refreshAccessToken` all wrapped; permanent OAuth errors (`invalid_grant`, `invalid_client`, `unauthorized_client`) are still propagated immediately without retry; `YouTubeClientCredentialsFetcher.fetchFromYouTube` retries twice before falling back to hardcoded credentials; `URLSession` in `InnerTubeAPI.init` now uses `waitsForConnectivity = true`, 20 s request timeout, 60 s resource timeout
- **SponsorBlock causing video playback to stall** — race condition between time observer ticks and async seek callback; debounce guard (`sponsorSkipDebounceTask`) prevents redundant seeks when multiple ticks fire on the same segment; seek-in-flight guard skips sponsor check while a seek is pending; exact seek (tolerance = zero) used for segment endpoints instead of fuzzy tolerance; segment-near-end threshold widened from 0.5 s to 2.0 s of video duration to prevent clamping to last frame; buffer-status verification logs warning when player is `.waiting` for >2 s after seek
- **Subscriptions feed showing videos out of chronological order** — `InnerTubeAPI+Browse.fetchSubscriptions()` now sorts each page's videos by `publishedAt` descending on arrival; `parseGuideChannels()` and `parseSubscribedChannels()` now sort channels alphabetically, matching `LocalSubscriptionStore`'s existing order
- **Apple TV fast-forward and rewind buttons showing white squares and not responding** — SF Symbol images in `seekButton` and `playPauseButton` rendered as white-on-white on tvOS focus engine due to `scaleEffect` + `shadow` + `buttonStyle(.plain)` interaction; fixed with `.renderingMode(.original)` + `.foregroundStyle(.white)`; reduced shadow intensity; Siri Remote gen 1 edge-tap left/right swipe gestures wired to `seekRelative` when controls are visible
- **Audio track language defaulting to wrong language for AI-dubbed videos** — when no `DEFAULT=YES` track is present in the HLS manifest, `index == 0` was incorrectly marked `isOriginal = true`; for AI-dubbed videos YouTube often lists the dubbed track first, causing the wrong track to be auto-selected; `isOriginal` is now only set when `group.defaultOption == option` (explicit HLS `DEFAULT=YES`); auto-selection waterfall reordered: (1) user's saved language preference, (2) HLS `DEFAULT=YES` original, (3) English track, (4) device locale, (5) first track
- **Videos unable to play / "reload page" error on iOS 18.7.2 and iOS 26** — hardcoded `"iOS 18_3_2"` User-Agent and client version string caused YouTube to detect a version mismatch on newer OS versions and return `UNPLAYABLE` or cipher-protected streams; User-Agent now uses `UIDevice.systemVersion` dynamically; SponsorBlock segment fetch moved to a detached background `Task` after `AVPlayerItem` is `.readyToPlay` so it no longer blocks stream setup on slow connections

---

## [1.9] – 2026-05-02

### Added
- Home feed staleness check — `HomeViewModel.refreshIfStale(threshold:)` reloads shelves when content is older than 15 minutes
- `InnerTubeAPI`: authenticated playback tracking URLs (`fetchAuthenticatedTrackingURLs`), TV-client endpoint (`postTV`), section-date and relative-date parsing
- Home feed fallback to popular videos when watch history is empty

### Changed
- HomeView replaced shelf rows with `VideoGridSection` grid layout
- `VideoCardView` layout and thumbnail improvements

---

## [1.8] – 2026-05-01

### Added
- Android-client HLS fallback in `PlaybackViewModel` — retries with Android credentials when the iOS HLS manifest returns a 404 due to IP-binding; last attempted URL stamped into Crashlytics non-fatal reports
- `VideoPlaybackRegressionUITests` — UI test coverage for core playback flows

### Changed
- `VideoPreloadCache` keeps its `InnerTubeAPI` access-token in sync with the signed-in session

---

## [1.7] – 2026-04-30

### Added
- `VideoPreloadCache` — background prefetch and cache of video stream data keyed by video ID
- `WatchtimeTracker` — reports playback position metrics to YouTube's watchtime endpoint
- `InnerTubeAPIKey` SwiftUI environment key — all views receive `InnerTubeAPI` via `@Environment(\.innerTubeAPI)` instead of constructor injection

### Changed
- Updated InnerTube client version strings

---

## [1.6] – 2026-04-28/29 — Initial Open Source Release

### Added
- Initial open source release of AxrTube for iPhone, iPad, macOS, and Apple TV
- **Audio track selection** — loads alternate HLS renditions (dubbed/translated tracks) from the manifest; auto-selects by device locale; persisted in `AppSettings`
- tvOS d-pad navigation in the player — custom `TVPlayerControl` enum; directional seek, play/pause, and back without SwiftUI focus engine
- tvOS Settings: Ko-fi and GitHub QR code sheets
- Firebase dSYM copy script for crash symbolication
- `CrashlyticsLogger` integration

### Changed
- `AuthService`: concurrent sign-in guard; automatic sign-out on permanent OAuth failures (`invalid_grant`, `invalid_client`, `unauthorized_client`); device code expiration clamped at server-reported `expiresIn`
- `VideoDownloadService` download-session and background-task code restricted to iOS with `#if os(iOS)` guards
- `PlaybackViewModel`: foreground/background audio session handling (`handleForeground()` / `handleBackground()`)
