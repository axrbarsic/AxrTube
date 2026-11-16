#!/usr/bin/env bash
# Upload dist/server/index.js to the Cloudflare Worker "axrtube".
# Needs CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID and GOOGLE_OAUTH_CLIENT_ID in the environment.
# Secrets (GOOGLE_OAUTH_CLIENT_SECRET, GOOGLE_OAUTH_COOKIE_KEY) stay in Cloudflare and are kept.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${CLOUDFLARE_API_TOKEN:?}" "${CLOUDFLARE_ACCOUNT_ID:?}" "${GOOGLE_OAUTH_CLIENT_ID:?}"
script=${WORKER_NAME:-axrtube}
meta=$(mktemp)
trap 'rm -f "$meta"' EXIT
cat > "$meta" <<JSON
{"main_module":"index.js","compatibility_date":"2025-09-01","keep_bindings":["secret_text"],"observability":{"enabled":true},
 "bindings":[
  {"type":"plain_text","name":"GOOGLE_OAUTH_ENABLED","text":"true"},
  {"type":"plain_text","name":"GOOGLE_OAUTH_PERSONAL_HOME_ENABLED","text":"true"},
  {"type":"plain_text","name":"GOOGLE_OAUTH_CLIENT_ID","text":"${GOOGLE_OAUTH_CLIENT_ID}"}]}
JSON
curl -fsS -X PUT -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${script}" \
  -F "metadata=@${meta};type=application/json" \
  -F "index.js=@${root}/dist/server/index.js;type=application/javascript+module" >/dev/null
echo "Deployed ${script}"
