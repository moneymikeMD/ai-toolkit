#!/usr/bin/env bash
#
# Post a message to a Buzz webhook workflow. Reads BUZZ_URL, BUZZ_SECRET,
# BUZZ_STATUS, BUZZ_TITLE, BUZZ_MESSAGE, BUZZ_LINK from the environment.
# Never fails the caller on delivery problems: it warns and exits 0.
# Exit 2 only for setup errors (missing url, secret or title).

set -uo pipefail

url="${BUZZ_URL:-}"
secret="${BUZZ_SECRET:-}"
title="${BUZZ_TITLE:-}"

[ -n "$url" ] && echo "::add-mask::$url"
[ -n "$secret" ] && echo "::add-mask::$secret"

if [ -z "$url" ] || [ -z "$secret" ] || [ -z "$title" ]; then
  echo "::error::notify-buzz needs url, secret and title" >&2
  exit 2
fi

body=$(jq -n \
  --arg status "${BUZZ_STATUS:-firing}" \
  --arg title "$title" \
  --arg message "${BUZZ_MESSAGE:-}" \
  --arg externalURL "${BUZZ_LINK:-}" \
  '{status: $status, title: $title, message: $message, externalURL: $externalURL}') || {
  echo "::warning::notify-buzz could not build the JSON body; nothing sent"
  exit 0
}

# --config keeps the secret out of argv; curl reads the header from stdin.
code=$(printf 'header = "x-webhook-secret: %s"\n' "$secret" | curl -sS -o /dev/null \
  --config - \
  --max-time "${BUZZ_MAX_TIME:-10}" \
  -w '%{http_code}' \
  -X POST \
  -H 'Content-Type: application/json' \
  -H 'User-Agent: ai-toolkit-notify-buzz/1' \
  --data "$body" \
  "$url" 2>/dev/null) || code="${code:-000}"

case "$code" in
  2??) echo "notify-buzz: delivered (HTTP $code)" ;;
  000) echo "::warning::notify-buzz: Buzz unreachable (no HTTP status); message not delivered" ;;
  *) echo "::warning::notify-buzz: Buzz answered HTTP $code; message not delivered" ;;
esac
exit 0
