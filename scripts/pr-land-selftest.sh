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
# one binary serves every scenario below. Successive PR reads walk
# PRLAND_STUB_MERGE_STATES line by line, so an UNKNOWN can settle.
fake_gh() {
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
count_file="$PRLAND_STUB_COUNTFILE"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$count_file"

if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    case "$*" in
        *"--json state --jq"*)
            echo "$PRLAND_STUB_FINAL_STATE"
            exit 0
            ;;
    esac
    pos_file="$PRLAND_STUB_VIEW_POS"
    p=$(( $(cat "$pos_file" 2>/dev/null || echo 0) + 1 ))
    echo "$p" > "$pos_file"
    merge_state="$(printf '%s\n' "$PRLAND_STUB_MERGE_STATES" | sed -n "${p}p")"
    [ -z "$merge_state" ] && merge_state="$(printf '%s\n' "$PRLAND_STUB_MERGE_STATES" | tail -n1)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$PRLAND_STUB_BASE" "$PRLAND_STUB_SHA" "$PRLAND_STUB_IS_BOT" \
        "$PRLAND_STUB_LOGIN" "$PRLAND_STUB_PR_STATE" "$merge_state" \
        "$PRLAND_STUB_REVIEW"
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
            if [ -n "${PRLAND_STUB_RULES_HTTP_STATUS:-}" ]; then
                echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP ${PRLAND_STUB_RULES_HTTP_STATUS})" >&2
                exit 1
            fi
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

# reset_scenario — a green, human-authored, fully-present, review-satisfied
# baseline that each test overrides just the fields it cares about, so an
# unrelated addition above never has to touch every case below it.
reset_scenario() {
    PRLAND_STUB_COUNTFILE="$WORK/count"
    PRLAND_STUB_MERGE_LOG="$WORK/merge.log"
    PRLAND_STUB_VIEW_POS="$WORK/view.pos"
    : > "$PRLAND_STUB_COUNTFILE"
    : > "$PRLAND_STUB_MERGE_LOG"
    : > "$PRLAND_STUB_VIEW_POS"
    PRLAND_STUB_REPO_NAMEWITHOWNER="test-owner/test-repo"
    PRLAND_STUB_BASE="main"
    PRLAND_STUB_SHA="deadbeef"
    PRLAND_STUB_IS_BOT="false"
    PRLAND_STUB_LOGIN="octocat"
    PRLAND_STUB_PR_STATE="OPEN"
    PRLAND_STUB_MERGE_STATES="CLEAN"
    PRLAND_STUB_REVIEW=""
    PRLAND_STUB_REQUIRED=""
    PRLAND_STUB_CHECKRUNS=""
    PRLAND_STUB_MERGE_EXIT="0"
    PRLAND_STUB_MERGE_STDERR=""
    PRLAND_STUB_FINAL_STATE="MERGED"
    PRLAND_STUB_RULES_HTTP_STATUS=""
    export PRLAND_STUB_COUNTFILE PRLAND_STUB_MERGE_LOG PRLAND_STUB_VIEW_POS \
        PRLAND_STUB_REPO_NAMEWITHOWNER PRLAND_STUB_BASE PRLAND_STUB_SHA \
        PRLAND_STUB_IS_BOT PRLAND_STUB_LOGIN PRLAND_STUB_PR_STATE \
        PRLAND_STUB_MERGE_STATES PRLAND_STUB_REVIEW PRLAND_STUB_REQUIRED \
        PRLAND_STUB_CHECKRUNS PRLAND_STUB_MERGE_EXIT PRLAND_STUB_MERGE_STDERR \
        PRLAND_STUB_FINAL_STATE PRLAND_STUB_RULES_HTTP_STATUS
}

run_sut() {
    PATH="$WORK/bin:$PATH" "$@" >"$WORK/stdout" 2>"$WORK/stderr"
    echo $?
}
merge_calls() { wc -l < "$PRLAND_STUB_MERGE_LOG" | tr -d ' '; }
admin_calls() { grep -c -- '--admin' "$PRLAND_STUB_MERGE_LOG"; }

fake_gh

# required-green: every required context present and successful.
reset_scenario
PRLAND_STUB_REQUIRED=$'selftest\nself-lint'
PRLAND_STUB_CHECKRUNS=$'selftest\tcompleted\tsuccess\t2026-09-19T10:00:00Z\nself-lint\tcompleted\tsuccess\t2026-09-19T10:00:01Z'
export PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "required-green: exits 0" 0 "$rc"
check "required-green: merges exactly once" 1 "$(merge_calls)"
check "required-green: never uses --admin" 0 "$(admin_calls)"

# WO-047 gap 6: a private free-plan repo answers 403 on branch rules, not
# because there are none, but because the plan cannot show any. That must
# degrade to a plain merge, never a refusal.
reset_scenario
PRLAND_STUB_RULES_HTTP_STATUS="403"
export PRLAND_STUB_RULES_HTTP_STATUS
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "a 403 on branch rules means no required contexts, not a refusal" "0 1" "$rc $(merge_calls)"

# ...and it must never be conflated with the required-absent bot bypass:
# even a bot author with a BLOCKED/REVIEW_REQUIRED state gets a plain merge,
# not --admin, purely because the rules were unreadable.
reset_scenario
PRLAND_STUB_RULES_HTTP_STATUS="403"
PRLAND_STUB_IS_BOT="true"
PRLAND_STUB_LOGIN="github-actions[bot]"
export PRLAND_STUB_RULES_HTTP_STATUS PRLAND_STUB_IS_BOT PRLAND_STUB_LOGIN
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "a 403 on branch rules never derives an admin bypass" "0 1 0" \
    "$rc $(merge_calls) $(admin_calls)"

# A 404 degrades the same way as a 403.
reset_scenario
PRLAND_STUB_RULES_HTTP_STATUS="404"
export PRLAND_STUB_RULES_HTTP_STATUS
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "a 404 on branch rules also means no required contexts" "0 1" "$rc $(merge_calls)"

# A genuine transport/auth failure is not 403/404 and must still refuse.
reset_scenario
PRLAND_STUB_RULES_HTTP_STATUS="500"
export PRLAND_STUB_RULES_HTTP_STATUS
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "a non-403/404 branch-rules failure still refuses the merge" "1 0" "$rc $(merge_calls)"

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
check "required-absent (bot): merges with --admin" 1 "$(admin_calls)"

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

# WO-045 gap 4: the review-gated case the owner's 2026-09-19 grant clears —
# BLOCKED on a missing review with every required context green.
reset_scenario
PRLAND_STUB_REQUIRED=$'selftest\nself-lint'
PRLAND_STUB_CHECKRUNS=$'selftest\tcompleted\tsuccess\t2026-09-19T10:00:00Z\nself-lint\tcompleted\tsuccess\t2026-09-19T10:00:01Z'
PRLAND_STUB_MERGE_STATES="BLOCKED"
PRLAND_STUB_REVIEW="REVIEW_REQUIRED"
export PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS PRLAND_STUB_MERGE_STATES PRLAND_STUB_REVIEW
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "REVIEW_REQUIRED with every required check green derives the admin bypass" "0 1 1" \
    "$rc $(merge_calls) $(admin_calls)"
check "  ...and says the review, not the checks, is what it bypassed" 1 \
    "$(grep -c 'REVIEW_REQUIRED' "$WORK/stdout")"

# WO-045: the boundary the widening must not cross. Same review-gated shape,
# but a required check ran and failed.
reset_scenario
PRLAND_STUB_REQUIRED=$'selftest\nself-lint'
PRLAND_STUB_CHECKRUNS=$'selftest\tcompleted\tfailure\t2026-09-19T10:00:00Z\nself-lint\tcompleted\tsuccess\t2026-09-19T10:00:01Z'
PRLAND_STUB_MERGE_STATES="BLOCKED"
PRLAND_STUB_REVIEW="REVIEW_REQUIRED"
export PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS PRLAND_STUB_MERGE_STATES PRLAND_STUB_REVIEW
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "a required check that ran and FAILED is never bypassed" "1 0 0" \
    "$rc $(merge_calls) $(admin_calls)"

# A check nobody required, but which ran and failed, cancels the bypass too.
reset_scenario
PRLAND_STUB_REQUIRED="selftest"
PRLAND_STUB_CHECKRUNS=$'selftest\tcompleted\tsuccess\t2026-09-19T10:00:00Z\nadvisory\tcompleted\tfailure\t2026-09-19T10:00:01Z'
PRLAND_STUB_MERGE_STATES="BLOCKED"
PRLAND_STUB_REVIEW="REVIEW_REQUIRED"
export PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS PRLAND_STUB_MERGE_STATES PRLAND_STUB_REVIEW
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "a non-required check that failed also blocks the review bypass" "1 0" "$rc $(merge_calls)"
check "  ...and names that check" 1 "$(grep -c 'advisory' "$WORK/stderr")"

# A superseded earlier run of a required check never outvotes its latest run.
reset_scenario
PRLAND_STUB_REQUIRED="selftest"
PRLAND_STUB_CHECKRUNS=$'selftest\tcompleted\tfailure\t2026-09-19T10:00:00Z\nselftest\tcompleted\tsuccess\t2026-09-19T11:00:00Z'
export PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "the latest run of a required check decides, not an earlier one" "0 1" "$rc $(merge_calls)"

# REVIEW_REQUIRED but not BLOCKED: a plain merge needs no bypass.
reset_scenario
PRLAND_STUB_REQUIRED="selftest"
PRLAND_STUB_CHECKRUNS=$'selftest\tcompleted\tsuccess\t2026-09-19T10:00:00Z'
PRLAND_STUB_REVIEW="REVIEW_REQUIRED"
export PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS PRLAND_STUB_REVIEW
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo)"
check "REVIEW_REQUIRED that is not BLOCKED merges without --admin" "0 1 0" \
    "$rc $(merge_calls) $(admin_calls)"

# mergeStateStatus is lazily computed: UNKNOWN is re-read, never branched on.
reset_scenario
PRLAND_STUB_REQUIRED="selftest"
PRLAND_STUB_CHECKRUNS=$'selftest\tcompleted\tsuccess\t2026-09-19T10:00:00Z'
PRLAND_STUB_MERGE_STATES=$'UNKNOWN\nBLOCKED'
PRLAND_STUB_REVIEW="REVIEW_REQUIRED"
export PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS PRLAND_STUB_MERGE_STATES PRLAND_STUB_REVIEW
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo --merge-state-poll-s 2)"
check "an UNKNOWN merge state is re-read before any bypass is derived" "0 1" "$rc $(admin_calls)"
check "  ...which took more than one PR read" 2 "$(cat "$WORK/view.pos")"

# An UNKNOWN that never settles derives no bypass at all.
reset_scenario
PRLAND_STUB_REQUIRED="selftest"
PRLAND_STUB_CHECKRUNS=$'selftest\tcompleted\tsuccess\t2026-09-19T10:00:00Z'
PRLAND_STUB_MERGE_STATES="UNKNOWN"
PRLAND_STUB_REVIEW="REVIEW_REQUIRED"
PRLAND_STUB_FINAL_STATE="OPEN"
export PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS PRLAND_STUB_MERGE_STATES \
    PRLAND_STUB_REVIEW PRLAND_STUB_FINAL_STATE
rc="$(run_sut bash "$SUT" 42 --repo test-owner/test-repo --merge-state-poll-s 0)"
check "an UNKNOWN that never settles derives no --admin" 0 "$(admin_calls)"
check "  ...and the run still fails its read-back" 1 "$rc"

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

rc="$(run_sut bash "$SUT" 42 --merge-state-poll-s abc)"
check "a non-numeric --merge-state-poll-s is a usage error" 2 "$rc"

echo
echo "$((PASS + FAIL)) assertion(s), $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { echo "pr-land-selftest.sh: FAILED"; exit 1; }
echo "pr-land-selftest.sh: all assertions passed"
