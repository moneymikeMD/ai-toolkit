#!/usr/bin/env bash
#
# Selftest for notify-buzz. A local python stub server records each request;
# the assertions check the wire format, quoting, masking and the never-fail rule.

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/notify-buzz.sh"
TMP=$(mktemp -d)
SRV=""
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }

cat > "$TMP/stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
out = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode()
        ok = self.headers.get("x-webhook-secret") == "s3cret" and self.path == "/hooks/wf1"
        with open(out, "a") as f:
            f.write(json.dumps({"path": self.path, "secret": self.headers.get("x-webhook-secret"),
                                "ua": self.headers.get("User-Agent"), "ct": self.headers.get("Content-Type"),
                                "body": body}) + "\n")
        self.send_response(202 if ok else 404)
        self.end_headers()
    def log_message(self, *a): pass
srv = HTTPServer(("127.0.0.1", 0), H)
open(out + ".port", "w").write(str(srv.server_port))
srv.serve_forever()
PY

REQ="$TMP/req.jsonl"
python3 "$TMP/stub.py" "$REQ" &
SRV=$!
for _ in $(seq 50); do [ -s "$REQ.port" ] && break; sleep 0.1; done
PORT=$(cat "$REQ.port")
BASE="http://127.0.0.1:$PORT"

run() { env -i PATH="$PATH" "$@" bash "$SCRIPT" 2>&1; }
rc()  { env -i PATH="$PATH" "$@" bash "$SCRIPT" >/dev/null 2>&1; echo $?; }
field() { tail -n1 "$REQ" | jq -r "$1"; }

TRICKY='say "hi" \ back $(whoami) `x`'
out=$(run BUZZ_URL="$BASE/hooks/wf1" BUZZ_SECRET=s3cret BUZZ_TITLE="$TRICKY" BUZZ_MESSAGE=m BUZZ_LINK=https://x/y)
echo "$out" | grep -q 'delivered (HTTP 202)' && ok "good request reports 202" || no "good request reports 202: $out"
check "secret sent as header" "$(field .secret)" s3cret
check "explicit user agent" "$(field .ua)" ai-toolkit-notify-buzz/1
check "content type json" "$(field .ct)" application/json
check "title survives quoting" "$(field '.body|fromjson|.title')" "$TRICKY"
check "status defaults to firing" "$(field '.body|fromjson|.status')" firing
check "link in externalURL" "$(field '.body|fromjson|.externalURL')" https://x/y
check "body is flat" "$(field '.body|fromjson|[.[]|type]|unique|join(",")')" string
echo "$out" | grep -v '^::add-mask::' | grep -q 's3cret' && no "secret never echoed" || ok "secret never echoed"
echo "$out" | grep -q '^::add-mask::s3cret$' && ok "secret masked" || no "secret masked"
echo "$out" | grep -q "^::add-mask::$BASE/hooks/wf1\$" && ok "url masked" || no "url masked"

out=$(run BUZZ_URL="$BASE/hooks/wf1" BUZZ_SECRET=wrong BUZZ_TITLE=t)
echo "$out" | grep -q '::warning::.*HTTP 404' && ok "wrong secret warns with 404" || no "wrong secret warns with 404: $out"
check "wrong secret exits 0" "$(rc BUZZ_URL="$BASE/hooks/wf1" BUZZ_SECRET=wrong BUZZ_TITLE=t)" 0

out=$(run BUZZ_URL="http://127.0.0.1:1/hooks/wf1" BUZZ_SECRET=s3cret BUZZ_TITLE=t BUZZ_MAX_TIME=3)
echo "$out" | grep -q '::warning::.*unreachable' && ok "unreachable warns" || no "unreachable warns: $out"
check "unreachable exits 0" "$(rc BUZZ_URL=http://127.0.0.1:1/hooks/wf1 BUZZ_SECRET=s3cret BUZZ_TITLE=t BUZZ_MAX_TIME=3)" 0

check "missing title is a setup error" "$(rc BUZZ_URL="$BASE/hooks/wf1" BUZZ_SECRET=s3cret)" 2
check "missing url is a setup error" "$(rc BUZZ_SECRET=s3cret BUZZ_TITLE=t)" 2

echo "notify-buzz selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
