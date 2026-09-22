#!/usr/bin/env bash
#
# Selftest for protections.sh. Structurally offline: every case runs against a
# fake `gh` on PATH that answers out of a fixture directory, so no assertion
# touches a network, a credential or a real repo.
#
# The two halves LAB-292 asks for are both here. The write half asserts that
# stripping the generated blocks out of the written manifest reproduces the
# input byte for byte, which is the strongest available form of "no
# hand-written key was disturbed". The gate half corrupts one recorded value
# at a time and asserts --check exits non-zero naming that repo — a --check
# that has never been seen to fail is not known to work.
#
# Usage: protections-selftest.sh [path-to-protections.sh]
# Defaults to the sibling protections.sh. Pass an older revision's path to
# reproduce the RED failures against pre-fix code.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${1:-$HERE/protections.sh}"
PASS=0
FAIL=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
nope() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/       /'; }
check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then ok "$name"; else nope "$name" "wanted [$want], got [$got]"; fi
}

STUB="$WORK/stub"
BIN="$WORK/bin"
mkdir -p "$STUB" "$BIN"

cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "api" ] || { echo "stub gh: only 'api' is stubbed: $*" >&2; exit 1; }
key=$(printf '%s' "$2" | tr '/?=' '___')
dir="$PROTECTIONS_STUB_DIR"
if [ -f "$dir/$key.fail" ]; then cat "$dir/$key.fail"; exit 1; fi
if [ -f "$dir/$key.json" ]; then cat "$dir/$key.json"; exit 0; fi
printf '%s' '{"message":"Not Found","status":"404"}'
exit 1
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"
export PROTECTIONS_STUB_DIR="$STUB"

stub() { printf '%s' "$2" > "$STUB/$(printf '%s' "$1" | tr '/?=' '___').json"; }
stub_fail() { printf '%s' "$2" > "$STUB/$(printf '%s' "$1" | tr '/?=' '___').fail"; }

repo_json() { printf '{"visibility":"%s","default_branch":"main"}' "$1"; }

stub "repos/t/alpha"   "$(repo_json public)"
stub "repos/t/bravo"   "$(repo_json public)"
stub "repos/t/charlie" "$(repo_json private)"
stub "repos/t/delta"   "$(repo_json public)"
stub "repos/t/echo"    "$(repo_json public)"
stub "repos/t/foxtrot" "$(repo_json public)"

stub "repos/t/alpha/rulesets" '[{"id":1}]'
stub "repos/t/alpha/rulesets/1" '{"target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},
 "rules":[{"type":"required_status_checks","parameters":{"required_status_checks":
   [{"context":"ci-a"},{"context":"ci-b"}]}},
  {"type":"pull_request","parameters":{"required_approving_review_count":0,
   "require_code_owner_review":false}}]}'

stub "repos/t/bravo/rulesets" '[{"id":7},{"id":2}]'
stub "repos/t/bravo/rulesets/2" '{"target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["refs/heads/main"],"exclude":[]}},
 "rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1,
   "require_code_owner_review":true}}]}'
stub "repos/t/bravo/rulesets/7" '{"target":"tag","enforcement":"active",
 "conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},
 "rules":[{"type":"required_status_checks","parameters":{"required_status_checks":
   [{"context":"must-not-appear"}]}}]}'
stub "repos/t/bravo/contents/.github/CODEOWNERS?ref=main" \
  "$(printf '{"content":"%s"}' "$(printf '# a comment\n*  @owner\n/docs/ @other\n' | base64 | tr -d '\n')")"

stub_fail "repos/t/charlie/rulesets" \
 '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":"403"}'

stub "repos/t/delta/rulesets" '[{"id":3}]'
stub "repos/t/delta/rulesets/3" '{"target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["refs/heads/does-not-exist"],"exclude":[]}},
 "rules":[{"type":"required_status_checks","parameters":{"required_status_checks":
   [{"context":"never-applies"}]}}]}'

stub "repos/t/echo/rulesets" '[{"id":4}]'
stub "repos/t/echo/rulesets/4" '{"target":"branch","enforcement":"evaluate",
 "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},
 "rules":[{"type":"required_status_checks","parameters":{"required_status_checks":
   [{"context":"report-only"}]}}]}'

stub "repos/t/foxtrot/rulesets" '[]'

WS="$WORK/ws"
mkdir -p "$WS"
cat > "$WS/repos.yaml" <<'YAML'
# A fixture manifest. Every comment and key below is hand-written and must
# survive a generated write untouched.

workspace: fixture
root: /nowhere

repos:
  alpha:
    url: git@github.com:t/alpha.git
    branch: main
    visibility: public
    agent: true
    summary: Required checks, no approving review.

  bravo:
    url: https://github.com/t/bravo
    branch: main
    visibility: public
    agent: true
    summary: One approving review plus a code owner.

  charlie:
    url: git@github.com:t/charlie.git
    branch: main
    visibility: private
    agent: false
    summary: Private on Free, so rulesets are impossible.

  delta:
    url: git@github.com:t/delta.git
    branch: main
    visibility: public
    agent: false
    summary: A ruleset aimed at a branch that does not exist.

  echo:
    url: git@github.com:t/echo.git
    branch: main
    visibility: public
    agent: false
    summary: A ruleset in evaluate mode enforces nothing.

  foxtrot:
    url: git@github.com:t/foxtrot.git
    branch: main
    visibility: public
    agent: false
    summary: No rulesets at all.

# A trailing comment, also hand-written.
extra_agent_dirs:
  - /tmp/extra
YAML
cp "$WS/repos.yaml" "$WORK/original.yaml"

strip_generated() {
    awk '
        /^[[:space:]]*# Generated by ai-toolkit\/scripts\/protections\.sh/ { skip = 1; next }
        skip && /^[[:space:]]*# end generated[[:space:]]*$/ { skip = 0; next }
        skip { next }
        { print }
    ' "$1"
}
value_of() {
    python3 -c "
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
v = (doc['repos'][sys.argv[2]] or {}).get(sys.argv[3], '<missing>')
print(','.join(v) if isinstance(v, list) else v)
" "$1" "$2" "$3"
}

echo "== usage"
"$SUT" --help >/dev/null 2>&1; check "--help exits 0" "0" "$?"
"$SUT" --root "$WS" --bogus >/dev/null 2>&1; check "unknown flag exits 2" "2" "$?"
"$SUT" --root "$WORK/stub" >/dev/null 2>&1; check "missing manifest exits 2" "2" "$?"

echo "== dry-run writes nothing"
"$SUT" --root "$WS" --dry-run > "$WORK/dry.txt" 2>&1
check "dry-run exits 0" "0" "$?"
check "dry-run left the manifest alone" "same" \
    "$(cmp -s "$WS/repos.yaml" "$WORK/original.yaml" && echo same || echo changed)"
check "dry-run printed a diff" "1" "$(grep -c '^+    landing: checks' "$WORK/dry.txt")"

echo "== write"
"$SUT" --root "$WS" > "$WORK/write.txt" 2>&1
check "write exits 0" "0" "$?"
check "landing for required checks and no review" "checks" "$(value_of "$WS/repos.yaml" alpha landing)"
check "required_checks recorded in ruleset order" "ci-a,ci-b" "$(value_of "$WS/repos.yaml" alpha required_checks)"
check "code_owner none when no code-owner rule" "none" "$(value_of "$WS/repos.yaml" alpha code_owner)"
check "landing review when an approval is required" "review" "$(value_of "$WS/repos.yaml" bravo landing)"
check "code_owner handle read from CODEOWNERS" "@owner" "$(value_of "$WS/repos.yaml" bravo code_owner)"
check "a tag-target ruleset is ignored" "none" "$(value_of "$WS/repos.yaml" bravo required_checks)"
check "a ruleset on a non-default branch is ignored" "direct" "$(value_of "$WS/repos.yaml" delta landing)"
check "an evaluate-mode ruleset enforces nothing" "direct" "$(value_of "$WS/repos.yaml" echo landing)"
check "no rulesets means direct" "direct" "$(value_of "$WS/repos.yaml" foxtrot landing)"
check "every repo got a UTC timestamp" "6" \
    "$(grep -c 'protections_fetched_at: "[0-9-]*T[0-9:]*Z"' "$WS/repos.yaml")"
check "the seam is reported on every write" "1" "$(grep -c 'state store: not written' "$WORK/write.txt")"

echo "== 403 is unavailable, never no-protections"
check "landing unavailable" "unavailable" "$(value_of "$WS/repos.yaml" charlie landing)"
check "required_checks unavailable, not none" "unavailable" "$(value_of "$WS/repos.yaml" charlie required_checks)"
check "code_owner unavailable, not none" "unavailable" "$(value_of "$WS/repos.yaml" charlie code_owner)"

echo "== hand-written content survives"
strip_generated "$WS/repos.yaml" > "$WORK/stripped.yaml"
check "stripping the generated blocks reproduces the input byte for byte" "same" \
    "$(cmp -s "$WORK/stripped.yaml" "$WORK/original.yaml" && echo same || echo differs)"

echo "== idempotence"
sed 's/protections_fetched_at: .*/protections_fetched_at: STAMP/' "$WS/repos.yaml" > "$WORK/first.yaml"
"$SUT" --root "$WS" >/dev/null 2>&1
sed 's/protections_fetched_at: .*/protections_fetched_at: STAMP/' "$WS/repos.yaml" > "$WORK/second.yaml"
check "a second run changes nothing but the timestamp" "same" \
    "$(cmp -s "$WORK/first.yaml" "$WORK/second.yaml" && echo same || echo differs)"
check "the block is replaced, never appended" "6" \
    "$(grep -c '# end generated' "$WS/repos.yaml")"

echo "== --check agrees with what it just wrote"
"$SUT" --root "$WS" --check > "$WORK/check-ok.txt" 2>&1
check "--check exits 0 with no drift" "0" "$?"
check "--check writes nothing" "1" "$(grep -c 'no drift' "$WORK/check-ok.txt")"

echo "== --check discriminates"
drift_case() {
    local label="$1" sedscript="$2" repo="$3"
    cp "$WS/repos.yaml" "$WORK/keep.yaml"
    sed -i.bak "$sedscript" "$WS/repos.yaml"
    rm -f "$WS/repos.yaml.bak"
    "$SUT" --root "$WS" --check > "$WORK/drift.txt" 2>&1
    local rc=$?
    check "$label exits 1" "1" "$rc"
    check "$label names $repo" "yes" \
        "$(grep -q "  $repo: " "$WORK/drift.txt" && echo yes || echo no)"
    cp "$WORK/keep.yaml" "$WS/repos.yaml"
}
drift_case "a corrupted landing"         's/landing: checks/landing: direct/'        alpha
drift_case "a corrupted required_checks" 's/      - ci-b/      - ci-WRONG/'           alpha
drift_case "a corrupted code_owner"      's/code_owner: "@owner"/code_owner: none/'   bravo
drift_case "a corrupted visibility"      '/^  alpha:/,/^$/s/visibility: public/visibility: private/' alpha
drift_case "a collapsed unavailable"     's/landing: unavailable/landing: direct/'    charlie

echo "== --check on a repo that was never recorded"
cp "$WS/repos.yaml" "$WORK/keep.yaml"
strip_generated "$WS/repos.yaml" > "$WORK/bare.yaml" && cp "$WORK/bare.yaml" "$WS/repos.yaml"
"$SUT" --root "$WS" --check > "$WORK/drift2.txt" 2>&1
check "an unrecorded repo is drift" "1" "$?"
check "and says so rather than comparing nothing" "yes" \
    "$(grep -q 'no generated block recorded' "$WORK/drift2.txt" && echo yes || echo no)"
cp "$WORK/keep.yaml" "$WS/repos.yaml"

echo "== a non-403 failure is an error, not a recorded state"
cp "$WS/repos.yaml" "$WORK/keep.yaml"
stub_fail "repos/t/alpha/rulesets" '{"message":"Bad credentials","status":"401"}'
"$SUT" --root "$WS" > "$WORK/err.txt" 2>&1
check "the run exits 1" "1" "$?"
check "the failure is named" "yes" \
    "$(grep -q 'alpha: gh api' "$WORK/err.txt" && echo yes || echo no)"
check "and nothing was written" "same" \
    "$(cmp -s "$WS/repos.yaml" "$WORK/keep.yaml" && echo same || echo changed)"
check "alpha was not recorded unavailable" "checks" "$(value_of "$WS/repos.yaml" alpha landing)"
rm -f "$STUB/repos_t_alpha_rulesets.fail"

echo "== --emit-json carries the LAB-291 payload"
"$SUT" --root "$WS" --check --emit-json "$WORK/facts.json" >/dev/null 2>&1
check "the payload names every repo" "6" \
    "$(python3 -c "import json;print(len(json.load(open('$WORK/facts.json'))['repos']))")"
check "the payload carries the landing decision" "checks" \
    "$(python3 -c "
import json
d = json.load(open('$WORK/facts.json'))
print([r for r in d['repos'] if r['name'] == 'alpha'][0]['landing'])")"

echo "== required_approvals reaches the payload"
check "an approving-review count is emitted, not just used to pick landing" "1" \
    "$(python3 -c "
import json
d = json.load(open('$WORK/facts.json'))
print([r for r in d['repos'] if r['name'] == 'bravo'][0]['required_approvals'])")"
check "zero approvals is emitted as 0, not omitted" "0" \
    "$(python3 -c "
import json
d = json.load(open('$WORK/facts.json'))
print([r for r in d['repos'] if r['name'] == 'alpha'][0]['required_approvals'])")"
check "a repo with no rulesets at all still reports a count" "0" \
    "$(python3 -c "
import json
d = json.load(open('$WORK/facts.json'))
print([r for r in d['repos'] if r['name'] == 'foxtrot'][0]['required_approvals'])")"
check "unavailable is carried here too, never collapsed to 0" "unavailable" \
    "$(python3 -c "
import json
d = json.load(open('$WORK/facts.json'))
print([r for r in d['repos'] if r['name'] == 'charlie'][0]['required_approvals'])")"

echo "== --emit-json - puts the payload on stdout and nothing else"
"$SUT" --root "$WS" --check --emit-json - > "$WORK/stdout.json" 2> "$WORK/stdout.err"
check "--emit-json - exits 0" "0" "$?"
check "stdout parses as JSON with every repo" "6" \
    "$(python3 -c "import json;print(len(json.load(open('$WORK/stdout.json'))['repos']))" 2>/dev/null || echo "NOT-JSON")"
check "the per-repo table moved to stderr" "yes" \
    "$(grep -q '^alpha ' "$WORK/stdout.err" && echo yes || echo no)"
check "and is not on stdout, where it would corrupt the payload" "no" \
    "$(grep -q '^alpha ' "$WORK/stdout.json" && echo yes || echo no)"

echo "== --store resolution refuses before any fetching"
cat > "$WORK/fake-ws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WS_STUB_LOG"
cat "${4:-/dev/null}" > "$WS_STUB_PAYLOAD" 2>/dev/null || true
exit "${WS_STUB_EXIT:-0}"
STUB
chmod +x "$WORK/fake-ws"
export WS_STUB_LOG="$WORK/ws-calls.log"
export WS_STUB_PAYLOAD="$WORK/ws-payload.json"

# Structural, not incidental: every path protections.sh can resolve a CLI on
# must land somewhere harmless. A resolution bug in this script wrote six
# fixture repos into the live postgres before this existed.
cat > "$BIN/workspace-state" <<'REFUSE'
#!/usr/bin/env bash
echo "selftest: the real workspace-state must never be reached from here" >&2
exit 97
REFUSE
chmod +x "$BIN/workspace-state"

WORKSPACE_STATE_BIN="$WORK/no-such-cli" "$SUT" --root "$WS" --store >/dev/null 2>&1
check "a WORKSPACE_STATE_BIN that is not executable exits 2" "2" "$?"
# The LAB-228 shape: a harness writing --store with an empty override must not
# silently fall through to whatever happens to be on PATH.
WORKSPACE_STATE_BIN="" "$SUT" --root "$WS" --store >"$WORK/emptybin.out" 2>&1
check "a set-but-empty WORKSPACE_STATE_BIN exits 2" "2" "$?"
check "and says the variable is empty" "yes" \
    "$(grep -q 'WORKSPACE_STATE_BIN is set but empty' "$WORK/emptybin.out" && echo yes || echo no)"
check "it never fell through to a resolved CLI" "no" \
    "$(grep -q 'selftest: the real workspace-state' "$WORK/emptybin.out" && echo yes || echo no)"

echo "== --store is a write, so it refuses the read-only modes"
WORKSPACE_STATE_BIN="$WORK/fake-ws" "$SUT" --root "$WS" --store --check >"$WORK/sc.out" 2>&1
check "--store --check exits 2" "2" "$?"
check "and names the mode it conflicts with" "yes" \
    "$(grep -q 'cannot be combined with --check' "$WORK/sc.out" && echo yes || echo no)"
WORKSPACE_STATE_BIN="$WORK/fake-ws" "$SUT" --root "$WS" --store --dry-run >/dev/null 2>&1
check "--store --dry-run exits 2" "2" "$?"
WORKSPACE_STATE_BIN="$WORK/fake-ws" "$SUT" --root "$WS" --store --emit-json - >/dev/null 2>&1
check "--store --emit-json - exits 2, because the CLI needs a file" "2" "$?"
check "none of those refusals called the CLI" "0" \
    "$([ -f "$WS_STUB_LOG" ] && wc -l < "$WS_STUB_LOG" | tr -d ' ' || echo 0)"

echo "== --store hands the CLI the payload"
: > "$WS_STUB_LOG"
WORKSPACE_STATE_BIN="$WORK/fake-ws" "$SUT" --root "$WS" --store >"$WORK/store.out" 2>&1
check "--store exits 0 when the CLI does" "0" "$?"
check "it called protections set --file PATH exactly once" "1" \
    "$(grep -c '^protections set --file /' "$WS_STUB_LOG")"
check "the CLI received every repo" "6" \
    "$(python3 -c "import json;print(len(json.load(open('$WS_STUB_PAYLOAD'))['repos']))" 2>/dev/null || echo "NOT-JSON")"
check "the payload it received carries required_approvals" "1" \
    "$(python3 -c "
import json
d = json.load(open('$WS_STUB_PAYLOAD'))
print([r for r in d['repos'] if r['name'] == 'bravo'][0]['required_approvals'])" 2>/dev/null || echo MISSING)"
check "and says the store was written" "yes" \
    "$(grep -q 'state store: written via' "$WORK/store.out" && echo yes || echo no)"

echo "== exit 4 is passed through, never folded into a generic failure"
: > "$WS_STUB_LOG"
WS_STUB_EXIT=4 WORKSPACE_STATE_BIN="$WORK/fake-ws" "$SUT" --root "$WS" --store >"$WORK/store4.out" 2>&1
check "the script exits 4 when the CLI does" "4" "$?"
check "it says unreachable, not empty" "yes" \
    "$(grep -q 'unreachable or unconfigured' "$WORK/store4.out" && echo yes || echo no)"
check "and says the manifest half still succeeded" "yes" \
    "$(grep -q 'repos.yaml was still written' "$WORK/store4.out" && echo yes || echo no)"
WS_STUB_EXIT=1 WORKSPACE_STATE_BIN="$WORK/fake-ws" "$SUT" --root "$WS" --store >"$WORK/store1.out" 2>&1
check "any other CLI failure exits with that code" "1" "$?"
check "and is reported as a failed write, not as unreachable" "yes" \
    "$(grep -q 'write failed' "$WORK/store1.out" && echo yes || echo no)"

echo "== without --store the CLI is never invoked"
: > "$WS_STUB_LOG"
WORKSPACE_STATE_BIN="$WORK/fake-ws" "$SUT" --root "$WS" >"$WORK/nostore.out" 2>&1
check "a plain write exits 0" "0" "$?"
check "the CLI was not called" "0" "$(wc -l < "$WS_STUB_LOG" | tr -d ' ')"
check "and the note names the flag that would have written it" "yes" \
    "$(grep -q 'state store: not written (pass --store)' "$WORK/nostore.out" && echo yes || echo no)"

echo
echo "protections-selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
