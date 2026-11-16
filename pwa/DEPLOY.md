# AxrTube PWA: стенограммы и обсуждения

Мобильное веб-приложение для двух задач: получить полную стенограмму ролика
YouTube и скопировать её одной кнопкой, а также читать и писать комментарии
в ленте, похожей на Twitter. Видео приложение не воспроизводит.

Работает как Cloudflare Worker `axrtube`: https://axrtube.axrbarsic.workers.dev

## Сборка и тесты

```sh
cd pwa
npm run build && npm run validate
for t in scripts/test*.mjs; do node "$t"; done
```

## Заливка

```sh
export CLOUDFLARE_API_TOKEN=...   # токен по шаблону "Edit Cloudflare Workers"
export CLOUDFLARE_ACCOUNT_ID=...
export GOOGLE_OAUTH_CLIENT_ID=... # публичный ID Web OAuth клиента
scripts/deploy-cloudflare.sh
```

`GOOGLE_OAUTH_CLIENT_SECRET` и `GOOGLE_OAUTH_COOKIE_KEY` хранятся только в
секретах Cloudflare и сохраняются при заливке. Реальные значения не коммитить.

## Как устроено

- Стенограмма: дорожки субтитров YouTube, в первую очередь через клиенты
  iOS/Android (их ссылки на субтитры не требуют проверки браузера). Если
  YouTube отклоняет этот запрос, используется панель «Показать расшифровку»
  (`next` → `get_transcript`). Диагностика источников: `/api/transcript-lab?ids=...`.
- Обсуждение: официальный YouTube Data API v3 от имени вошедшего пользователя
  (`commentThreads`, `comments`). Для публикации нужен scope
  `youtube.force-ssl`; вход запрашивает его вместе с `youtube.readonly`.
  Лимит API: 10 000 единиц в день, чтение страницы стоит 1, публикация 50.
- Название и канал ролика: публичный oEmbed, без запроса плеера.
- Android: `share_target` в манифесте, «Поделиться» из YouTube открывает ролик.

## Ограничения

- YouTube периодически отклоняет запросы плеера с адресов Cloudflare. Для
  субтитров это пока встречалось редко, но гарантии нет.
- Комментарии доступны только после входа через Google.
- Ставить лайки комментариям официальный API не позволяет.
