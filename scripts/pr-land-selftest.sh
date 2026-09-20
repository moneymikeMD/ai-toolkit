#!/usr/bin/env bash
#
# Selftest for pr-land.sh. Structurally offline: every case runs against a
# fake `gh` on PATH driven entirely by PRLAND_STUB_* environment variables,
# so no assertion depends on a network, a remote or a credential.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/pr-land.sh"
PASS=0
FAIL=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()   { PASS=$((PASS + 1)); echo "ok - $1"; }
nope() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/      /'; }

check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then ok "$name"; else nope "$name" "wanted [$want], got [$got]"; fi
}

# fake_gh — writes a gh stand-in once. It answers every call this script's
# decision path makes by reading the PRLAND_STUB_* variables a test sets, so
# one binary serves every scenario below.
fake_gh() {
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
count_file="$PRLAND_STUB_COUNTFILE"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$count_file"

if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    case "$*" in
        *"--json state"*)
            echo "$PRLAND_STUB_FINAL_STATE"
            exit 0
            ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$PRLAND_STUB_BASE" "$PRLAND_STUB_SHA" "$PRLAND_STUB_IS_BOT" \
        "$PRLAND_STUB_LOGIN" "$PRLAND_STUB_PR_STATE"
    exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
    echo "$*" >> "$PRLAND_STUB_MERGE_LOG"
    if [ -n "${PRLAND_STUB_MERGE_STDERR:-}" ]; then
        echo "$PRLAND_STUB_MERGE_STDERR" >&2
    fi
    exit "${PRLAND_STUB_MERGE_EXIT:-0}"
fi

if [ "$1" = "api" ]; then
    shift
    endpoint=""
    for a in "$@"; do
        case "$a" in
            repos/*/rules/branches/*) endpoint="rules" ;;
            repos/*/commits/*/check-runs) endpoint="checkruns" ;;
        esac
    done
    case "$endpoint" in
        rules)
            printf '%s\n' "$PRLAND_STUB_REQUIRED"
            exit 0
            ;;
        checkruns)
            printf '%s\n' "$PRLAND_STUB_CHECKRUNS"
            exit 0
            ;;
    esac
    echo "fake gh: unhandled api call: $*" >&2
    exit 1
fi

if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
    echo "$PRLAND_STUB_REPO_NAMEWITHOWNER"
    exit 0
fi

echo "fake gh: unhandled invocation: $*" >&2
exit 1
STUB
    chmod +x "$WORK/bin/gh"
}

# reset_scenario — a green, human-authored, fully-present baseline that each
# test overrides just the fields it cares about, so an unrelated addition
# above never has to touch every case below it.
reset_scenario() {
    PRLAND_STUB_COUNTFILE="$WORK/count"
    PRLAND_STUB_MERGE_LOG="$WORK/merge.log"
    : > "$PRLAND_STUB_COUNTFILE"
    : > "$PRLAND_STUB_MERGE_LOG"
    PRLAND_STUB_REPO_NAMEWITHOWNER="test-owner/test-repo"
    PRLAND_STUB_BASE="main"
    PRLAND_STUB_SHA="deadbeef"
    PRLAND_STUB_IS_BOT="false"
    PRLAND_STUB_LOGIN="octocat"
    PRLAND_STUB_PR_STATE="OPEN"
    PRLAND_STUB_REQUIRED=""
    PRLAND_STUB_CHECKRUNS=""
    PRLAND_STUB_MERGE_EXIT="0"
    PRLAND_STUB_MERGE_STDERR=""
    PRLAND_STUB_FINAL_STATE="MERGED"
    export PRLAND_STUB_COUNTFILE PRLAND_STUB_MERGE_LOG PRLAND_STUB_REPO_NAMEWITHOWNER \
        PRLAND_STUB_BASE PRLAND_STUB_SHA PRLAND_STUB_IS_BOT PRLAND_STUB_LOGIN \
        PRLAND_STUB_PR_STATE PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS \
        PRLAND_STUB_MERGE_EXIT PRLAND_STUB_MERGE_STDERR PRLAND_STUB_FINAL_STATE
}

run_sut() {
    PATH="$WORK/bin:$PATH" "$@" >"$WORK/stdout" 2>"$WORK/stderr"
    echo $?
}
merge_calls() { wc -l < "$PRLAND_STUB_MERGE_LOG" | tr -d ' '; }

fake_gh

# required-green: every required context present and successful.
reset_scenario
PRLAND_STUB_REQUIRED=$'selftest\nself-lint'
PRLAND_STUB_CHECKRUNS=$'selftest\tcompleted\tsuccess\t2026-09-19T10:00:00Z\nself-lint\tcompleted\tsuccess\t2026-09-19T10:00:01Z'
export PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "required-green: exits 0" 0 "$rc"
check "required-green: merges exactly once" 1 "$(merge_calls)"
check "required-green: never uses --admin" 0 "$(grep -c -- '--admin' "$PRLAND_STUB_MERGE_LOG")"

# required-failed: a required context genuinely failed, must never bypass it.
reset_scenario
PRLAND_STUB_REQUIRED=$'selftest\nself-lint'
PRLAND_STUB_CHECKRUNS=$'selftest\tcompleted\tfailure\t2026-09-19T10:00:00Z\nself-lint\tcompleted\tsuccess\t2026-09-19T10:00:01Z'
export PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "required-failed: exits non-zero" 1 "$rc"
check "required-failed: never attempts a merge" 0 "$(merge_calls)"
check "required-failed: names the failing context" 1 "$(grep -c 'selftest' "$WORK/stderr")"

# required-absent, bot author: the release-please GITHUB_TOKEN case.
reset_scenario
PRLAND_STUB_REQUIRED=$'selftest\nself-lint'
PRLAND_STUB_IS_BOT="true"
PRLAND_STUB_LOGIN="github-actions[bot]"
export PRLAND_STUB_REQUIRED PRLAND_STUB_IS_BOT PRLAND_STUB_LOGIN
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "required-absent (bot): exits 0" 0 "$rc"
check "required-absent (bot): merges with --admin" 1 "$(grep -c -- '--admin' "$PRLAND_STUB_MERGE_LOG")"

# required-absent, human author: nothing derives --admin for a human PR.
reset_scenario
PRLAND_STUB_REQUIRED=$'selftest\nself-lint'
export PRLAND_STUB_REQUIRED
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "required-absent (human): exits non-zero" 1 "$rc"
check "required-absent (human): never attempts a merge" 0 "$(merge_calls)"

# Partially absent on a human PR: one context present, one never ran.
reset_scenario
PRLAND_STUB_REQUIRED=$'selftest\nself-lint'
PRLAND_STUB_CHECKRUNS=$'selftest\tcompleted\tsuccess\t2026-09-19T10:00:00Z'
export PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "partial absence on a human PR is refused" 1 "$rc"
check "partial absence never attempts a merge" 0 "$(merge_calls)"

# A required check still running counts as "anything else", not success.
reset_scenario
PRLAND_STUB_REQUIRED=$'selftest\nself-lint'
PRLAND_STUB_CHECKRUNS=$'selftest\tin_progress\tnull\t2026-09-19T10:00:00Z\nself-lint\tcompleted\tsuccess\t2026-09-19T10:00:01Z'
export PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "a pending required check is refused" 1 "$rc"
check "a pending required check never attempts a merge" 0 "$(merge_calls)"

# The read-back must override a classifier denial that arrived after a real merge.
reset_scenario
PRLAND_STUB_REQUIRED="selftest"
PRLAND_STUB_CHECKRUNS=$'selftest\tcompleted\tsuccess\t2026-09-19T10:00:00Z'
PRLAND_STUB_MERGE_EXIT="1"
PRLAND_STUB_MERGE_STDERR="Permission for this action was denied by the Claude Code auto mode classifier. Reason: [Merge Without Review]"
PRLAND_STUB_FINAL_STATE="MERGED"
export PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS PRLAND_STUB_MERGE_EXIT \
    PRLAND_STUB_MERGE_STDERR PRLAND_STUB_FINAL_STATE
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "a denied merge command that actually merged still reports success" 0 "$rc"

# The read-back must also catch the opposite lie: exit 0 but nothing merged.
reset_scenario
PRLAND_STUB_REQUIRED="selftest"
PRLAND_STUB_CHECKRUNS=$'selftest\tcompleted\tsuccess\t2026-09-19T10:00:00Z'
PRLAND_STUB_FINAL_STATE="OPEN"
export PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS PRLAND_STUB_FINAL_STATE
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "a merge command exiting 0 with no real merge is still a failure" 1 "$rc"

# --dry-run reads and decides but never merges.
reset_scenario
PRLAND_STUB_REQUIRED="selftest"
PRLAND_STUB_CHECKRUNS=$'selftest\tcompleted\tsuccess\t2026-09-19T10:00:00Z'
export PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo --dry-run)"
check "--dry-run exits 0" 0 "$rc"
check "--dry-run never attempts a merge" 0 "$(merge_calls)"

rc="$(run_sut bash "$SUT" --help)"
check "--help exits 0" 0 "$rc"
check "--help prints usage" 1 "$(grep -c 'Usage:' "$WORK/stdout")"

rc="$(run_sut bash "$SUT")"
check "no PR number is a usage error" 2 "$rc"

rc="$(run_sut bash "$SUT" abc)"
check "a non-numeric PR number is a usage error" 2 "$rc"

echo
echo "$((PASS + FAIL)) assertion(s), $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { echo "pr-land-selftest.sh: FAILED"; exit 1; }
echo "pr-land-selftest.sh: all assertions passed"
