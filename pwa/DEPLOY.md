# AxrTube PWA on Cloudflare Workers

Source of the mobile PWA (based on the v38 export), deployed as the Cloudflare
Worker `axrtube` at https://axrtube.axrbarsic.workers.dev.

## Build and test

```sh
cd pwa
npm run build && npm run validate
node scripts/test.mjs   # and the other scripts/test-*.mjs
```

## Deploy

```sh
export CLOUDFLARE_API_TOKEN=...   # token from the "Edit Cloudflare Workers" template
export CLOUDFLARE_ACCOUNT_ID=...
export GOOGLE_OAUTH_CLIENT_ID=... # public Web OAuth client ID
scripts/deploy-cloudflare.sh
```

`GOOGLE_OAUTH_CLIENT_SECRET` and `GOOGLE_OAUTH_COOKIE_KEY` are stored only as
Cloudflare secrets and are preserved by the deploy. Never commit real values.

## Changes from the v38 export

- `accountOrigin` points to the new workers.dev origin (test fixtures too).
- Stream resolver: ANDROID_VR fallback after IOS/VISIONOS, then an optional
  read-only bridge to the previous public deployment (`LEGACY_STREAM_BRIDGE`).
- Resolver logs `RESOLVE_OK` / `RESOLVE_FAIL` with client codes and the
  Cloudflare egress address (Workers observability).

## Known limits

- YouTube intermittently refuses Cloudflare egress addresses
  (`LOGIN_REQUIRED`, HTTP 403). Playback works only while the egress used is
  accepted; this is not fixed by the resolver fallbacks.
- On the new origin the Lock Screen media card returned to the correct
  installed app in the owner's test (AxrTube Check page and main app).
