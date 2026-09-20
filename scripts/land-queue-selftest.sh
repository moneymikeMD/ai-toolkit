#!/usr/bin/env bash
#
# Selftest for land-queue.sh. Structurally offline: every case runs against
# a fake `gh` on PATH driven by LANDQ_STUB_*/PRLAND_STUB_* environment
# variables (the latter answer pr-land.sh's own calls, since land-queue.sh
# execs the real pr-land.sh next to it). No assertion touches a network, a
# remote or a credential.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/land-queue.sh"
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

# fake_gh — one stand-in serving both land-queue.sh's own calls
# (pr_read/pr_files/update-branch/checks, keyed on the --json field list or
# subcommand) and pr-land.sh's calls (keyed the same way pr-land-selftest.sh
# drives them), so the real pr-land.sh runs unmodified underneath it.
fake_gh() {
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
count_file="$LANDQ_STUB_COUNTFILE"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$count_file"

if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    case "$*" in
        *"--json files"*)
            echo "$LANDQ_STUB_FILES"
            exit 0
            ;;
        *"--json state --jq"*)
            echo "$PRLAND_STUB_FINAL_STATE"
            exit 0
            ;;
        *"baseRefName,headRefOid,author"*)
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$PRLAND_STUB_BASE" "$PRLAND_STUB_SHA" "$PRLAND_STUB_IS_BOT" \
                "$PRLAND_STUB_LOGIN" "$PRLAND_STUB_PR_STATE" \
                "$PRLAND_STUB_MERGE_STATE" "$PRLAND_STUB_REVIEW"
            exit 0
            ;;
        *"state,mergeStateStatus,headRefOid,baseRefName"*)
            pos_file="$LANDQ_STUB_READS_POS"
            p=$(( $(cat "$pos_file" 2>/dev/null || echo 0) + 1 ))
            echo "$p" > "$pos_file"
            total=$(wc -l < "$LANDQ_STUB_READS_FILE" | tr -d ' ')
            idx="$p"
            [ "$idx" -gt "$total" ] && idx="$total"
            sed -n "${idx}p" "$LANDQ_STUB_READS_FILE"
            exit 0
            ;;
    esac
    echo "fake gh: unhandled pr view: $*" >&2
    exit 1
fi

if [ "$1" = "pr" ] && [ "$2" = "update-branch" ]; then
    echo "$*" >> "$LANDQ_STUB_UPDATE_LOG"
    exit "${LANDQ_STUB_UPDATE_EXIT:-0}"
fi

if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
    echo "$*" >> "$LANDQ_STUB_CHECKS_LOG"
    exit "${LANDQ_STUB_CHECKS_EXIT:-0}"
fi

if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
    echo "$*" >> "$PRLAND_STUB_MERGE_LOG"
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
        rules) printf '%s\n' "$PRLAND_STUB_REQUIRED"; exit 0 ;;
        checkruns) printf '%s\n' "$PRLAND_STUB_CHECKRUNS"; exit 0 ;;
    esac
    echo "fake gh: unhandled api call: $*" >&2
    exit 1
fi

if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
    echo "test-owner/test-repo"
    exit 0
fi

echo "fake gh: unhandled invocation: $*" >&2
exit 1
STUB
    chmod +x "$WORK/bin/gh"
}

# set_reads TUPLE... — each TUPLE is
# "state<TAB>mergeStateStatus<TAB>head<TAB>base<TAB>unconcluded", consumed in
# order by successive pr_read calls; the last is repeated once exhausted.
set_reads() {
    : > "$LANDQ_STUB_READS_FILE"
    : > "$LANDQ_STUB_READS_POS"
    local t
    for t in "$@"; do printf '%s\n' "$t" >> "$LANDQ_STUB_READS_FILE"; done
}

reset_scenario() {
    LANDQ_STUB_COUNTFILE="$WORK/count"
    LANDQ_STUB_READS_FILE="$WORK/reads.txt"
    LANDQ_STUB_READS_POS="$WORK/reads.pos"
    LANDQ_STUB_UPDATE_LOG="$WORK/update.log"
    LANDQ_STUB_CHECKS_LOG="$WORK/checks.log"
    PRLAND_STUB_MERGE_LOG="$WORK/merge.log"
    : > "$LANDQ_STUB_COUNTFILE"
    : > "$LANDQ_STUB_UPDATE_LOG"
    : > "$LANDQ_STUB_CHECKS_LOG"
    : > "$PRLAND_STUB_MERGE_LOG"
    LANDQ_STUB_UPDATE_EXIT="0"
    LANDQ_STUB_CHECKS_EXIT="0"
    LANDQ_STUB_FILES="README.md, scripts/land-queue.sh"
    PRLAND_STUB_BASE="main"
    PRLAND_STUB_SHA="deadbeef"
    PRLAND_STUB_IS_BOT="false"
    PRLAND_STUB_LOGIN="octocat"
    PRLAND_STUB_PR_STATE="OPEN"
    PRLAND_STUB_MERGE_STATE="CLEAN"
    PRLAND_STUB_REVIEW=""
    PRLAND_STUB_REQUIRED=""
    PRLAND_STUB_CHECKRUNS=""
    PRLAND_STUB_MERGE_EXIT="0"
    PRLAND_STUB_FINAL_STATE="MERGED"
    set_reads $'OPEN\tCLEAN\tsha1\tmain\t0'
    export LANDQ_STUB_COUNTFILE LANDQ_STUB_READS_FILE LANDQ_STUB_READS_POS \
        LANDQ_STUB_UPDATE_LOG LANDQ_STUB_CHECKS_LOG LANDQ_STUB_UPDATE_EXIT \
        LANDQ_STUB_CHECKS_EXIT LANDQ_STUB_FILES PRLAND_STUB_MERGE_LOG \
        PRLAND_STUB_BASE PRLAND_STUB_SHA PRLAND_STUB_IS_BOT PRLAND_STUB_LOGIN \
        PRLAND_STUB_PR_STATE PRLAND_STUB_MERGE_STATE PRLAND_STUB_REVIEW \
        PRLAND_STUB_REQUIRED PRLAND_STUB_CHECKRUNS PRLAND_STUB_MERGE_EXIT \
        PRLAND_STUB_FINAL_STATE
}

run_sut() {
    PATH="$WORK/bin:$PATH" "$@" >"$WORK/stdout" 2>"$WORK/stderr"
    echo $?
}
calls() { wc -l < "$1" | tr -d ' '; }
reads_taken() { cat "$LANDQ_STUB_READS_POS" 2>/dev/null || echo 0; }
dead_pid() { ( : ) & local p=$!; wait "$p" 2>/dev/null; echo "$p"; }

# seam_violations FILE — every `gh` invocation outside the named forge
# functions, one per line. The seam is the whole point of the three-function
# split: a fourth call site elsewhere is how it quietly stopped holding.
seam_violations() {
    awk '
        /^[a-z_]+\(\)[[:space:]]*\{/ { fn = $1; sub(/\(\).*/, "", fn); next }
        /^\}/ { fn = ""; next }
        /^[[:space:]]*#/ { next }
        /(^|[^[:alnum:]_$.-])gh[[:space:]]/ {
            if (fn != "pr_read" && fn != "pr_files" && fn != "pr_update_branch" &&
                fn != "pr_wait_checks" && fn != "repo_default_slug")
                print FILENAME ":" NR ": " $0
        }
    ' "$1"
}

fake_gh

# --- G2, freshness: a behind PR is updated, then merged. ---
reset_scenario
set_reads $'OPEN\tBEHIND\tsha1\tmain\t0' $'OPEN\tCLEAN\tsha2\tmain\t0' $'MERGED\tCLEAN\tsha2\tmain\t0'
rc="$(run_sut "$SUT" 42 --repo test-owner/test-repo --state-dir "$WORK/state")"
check "a PR behind its base is updated before any merge is attempted" 0 "$rc"
check "update-branch is called exactly once for a behind PR" 1 "$(calls "$LANDQ_STUB_UPDATE_LOG")"
check "the refreshed PR still reaches the merge gate exactly once" 1 "$(calls "$PRLAND_STUB_MERGE_LOG")"

# --- G2, freshness: pending required checks after an update block the merge. ---
reset_scenario
set_reads $'OPEN\tBEHIND\tsha1\tmain\t0' $'OPEN\tCLEAN\tsha2\tmain\t0'
LANDQ_STUB_CHECKS_EXIT="1"
export LANDQ_STUB_CHECKS_EXIT
rc="$(run_sut "$SUT" 42 --repo test-owner/test-repo --state-dir "$WORK/state")"
check "a run refused on pending checks exits non-zero" 1 "$rc"
check "a merge is never attempted while required checks are pending" 0 "$(calls "$PRLAND_STUB_MERGE_LOG")"

# --- WO-045 gap 1: a lazily-computed merge state is polled, never acted on. ---
reset_scenario
set_reads $'OPEN\tUNKNOWN\tsha1\tmain\t0' $'OPEN\tUNKNOWN\tsha1\tmain\t0' \
          $'OPEN\tCLEAN\tsha1\tmain\t0' $'MERGED\tCLEAN\tsha1\tmain\t0'
rc="$(run_sut "$SUT" 42 --repo test-owner/test-repo --state-dir "$WORK/state" --merge-state-poll-s 5)"
check "UNKNOWN merge state is polled, never acted on" "0 1 4" \
    "$rc $(calls "$PRLAND_STUB_MERGE_LOG") $(reads_taken)"

# --- ...and one that never settles is refused rather than guessed at. ---
reset_scenario
set_reads $'OPEN\tUNKNOWN\tsha1\tmain\t0'
rc="$(run_sut "$SUT" 42 --repo test-owner/test-repo --state-dir "$WORK/state" --merge-state-poll-s 0)"
check "a merge state that never leaves UNKNOWN is refused" 1 "$rc"
check "  ...and never reaches the merge gate" 0 "$(calls "$PRLAND_STUB_MERGE_LOG")"
check "  ...naming the field it would not decide on" 1 "$(grep -c 'UNKNOWN' "$WORK/stderr")"

# --- WO-045 gap 2: DIRTY is a conflict, diagnosed here, not at the merge gate. ---
reset_scenario
set_reads $'OPEN\tDIRTY\tsha1\tmain\t0'
rc="$(run_sut "$SUT" 42 --repo test-owner/test-repo --state-dir "$WORK/state")"
check "a DIRTY pr is refused naming the base conflict, merge gate never called" "1 0 1" \
    "$rc $(calls "$PRLAND_STUB_MERGE_LOG") $(grep -c 'conflicts with its base main' "$WORK/stderr")"
check "  ...and names the files it changes" 1 "$(grep -c 'README.md' "$WORK/stderr")"
check "  ...and never calls update-branch on it" 0 "$(calls "$LANDQ_STUB_UPDATE_LOG")"

# --- WO-045 gap 3: an unconcluded check is waited for, head SHA or not. ---
reset_scenario
set_reads $'OPEN\tCLEAN\tsha1\tmain\t2' $'MERGED\tCLEAN\tsha1\tmain\t0'
rc="$(run_sut "$SUT" 42 --repo test-owner/test-repo --state-dir "$WORK/state")"
check "unconcluded checks are awaited even when this run did not move the head" "0 1 1" \
    "$rc $(calls "$LANDQ_STUB_CHECKS_LOG") $(calls "$PRLAND_STUB_MERGE_LOG")"

# --- ...while a PR whose checks have all concluded is not waited on at all. ---
reset_scenario
set_reads $'OPEN\tCLEAN\tsha1\tmain\t0' $'MERGED\tCLEAN\tsha1\tmain\t0'
rc="$(run_sut "$SUT" 42 --repo test-owner/test-repo --state-dir "$WORK/state")"
check "a PR with nothing unconcluded is not waited on" "0 0 1" \
    "$rc $(calls "$LANDQ_STUB_CHECKS_LOG") $(calls "$PRLAND_STUB_MERGE_LOG")"

# --- WO-045 gap 5: the forge seam holds, in the source itself. ---
check "every gh call in land-queue.sh sits inside a named seam function" "" \
    "$(seam_violations "$HERE/land-queue.sh")"

# --- G1: a live holder refuses the second run immediately, mutating nothing. ---
reset_scenario
mkdir -p "$WORK/state2"
holder="$$"
printf 'pid=%s\nstarted=%s\n' "$holder" "$(date +%s)" > "$WORK/state2/test-owner_test-repo.lock"
rc="$(run_sut "$SUT" 42 --repo test-owner/test-repo --state-dir "$WORK/state2")"
check "a second run refuses while the first holds the repo lock" 2 "$rc"
check "a refused-by-lock run makes zero gh calls" 0 "$(calls "$LANDQ_STUB_COUNTFILE")"
check "the refusal names the holder pid" 1 "$(grep -c "$holder" "$WORK/stderr")"
rm -f "$WORK/state2/test-owner_test-repo.lock"

# --- G1: a stale lock (holder pid is dead) is reclaimed, not treated as busy. ---
reset_scenario
mkdir -p "$WORK/state3"
dp="$(dead_pid)"
printf 'pid=%s\nstarted=%s\n' "$dp" "$(date +%s)" > "$WORK/state3/test-owner_test-repo.lock"
set_reads $'OPEN\tCLEAN\tsha1\tmain\t0' $'MERGED\tCLEAN\tsha1\tmain\t0'
rc="$(run_sut "$SUT" 42 --repo test-owner/test-repo --state-dir "$WORK/state3")"
check "a stale lock whose holder pid is dead is reclaimed" 0 "$rc"
check "reclaiming a stale lock still lets the PR merge" 1 "$(calls "$PRLAND_STUB_MERGE_LOG")"

# --- The final read-back overrides pr-land.sh's own reported success. ---
reset_scenario
set_reads $'OPEN\tCLEAN\tsha1\tmain\t0' $'OPEN\tCLEAN\tsha1\tmain\t0'
PRLAND_STUB_FINAL_STATE="MERGED"
PRLAND_STUB_MERGE_EXIT="0"
export PRLAND_STUB_FINAL_STATE PRLAND_STUB_MERGE_EXIT
rc="$(run_sut "$SUT" 42 --repo test-owner/test-repo --state-dir "$WORK/state")"
check "a PR that does not read back MERGED is reported refused" 1 "$rc"
check "the refusal names the mismatch" 1 "$(grep -c 'did not read back MERGED' "$WORK/stderr")"

# --- A clean multi-PR wave: both land, in one call. The read this run
# --- discards after landing the first is why there are five tuples.
reset_scenario
set_reads $'OPEN\tCLEAN\tsha1\tmain\t0' $'MERGED\tCLEAN\tsha1\tmain\t0' \
          $'OPEN\tCLEAN\tsha3\tmain\t0' $'OPEN\tCLEAN\tsha3\tmain\t0' \
          $'MERGED\tCLEAN\tsha3\tmain\t0'
rc="$(run_sut "$SUT" 10 11 --repo test-owner/test-repo --state-dir "$WORK/state")"
check "a wave of two independent PRs both land in one call" 0 "$rc"
check "  ...two merges attempted" 2 "$(calls "$PRLAND_STUB_MERGE_LOG")"
check "  ...and the stale first read after a landing is discarded" 5 "$(reads_taken)"

# --- --stop-on-refusal stops before touching the second PR. ---
reset_scenario
set_reads $'OPEN\tCLEAN\tsha1\tmain\t0' $'OPEN\tCLEAN\tsha1\tmain\t0'
PRLAND_STUB_FINAL_STATE="OPEN"
export PRLAND_STUB_FINAL_STATE
rc="$(run_sut "$SUT" 10 11 --repo test-owner/test-repo --state-dir "$WORK/state" --stop-on-refusal)"
check "--stop-on-refusal exits 1 on the first refusal" 1 "$rc"
check "--stop-on-refusal never reads the second PR" 2 "$(reads_taken)"

# --- --dry-run reads but never mutates. ---
reset_scenario
set_reads $'OPEN\tBEHIND\tsha1\tmain\t0'
rc="$(run_sut "$SUT" 42 --repo test-owner/test-repo --state-dir "$WORK/state" --dry-run)"
check "--dry-run exits 0" 0 "$rc"
check "--dry-run never calls update-branch" 0 "$(calls "$LANDQ_STUB_UPDATE_LOG")"
check "--dry-run never attempts a merge" 0 "$(calls "$PRLAND_STUB_MERGE_LOG")"

# --- Skips a PR that is not OPEN, without refusing the run. ---
reset_scenario
set_reads $'MERGED\tCLEAN\tsha1\tmain\t0'
rc="$(run_sut "$SUT" 42 --repo test-owner/test-repo --state-dir "$WORK/state")"
check "a PR that is already not OPEN is skipped, not refused" 0 "$rc"
check "  ...never attempts a merge" 0 "$(calls "$PRLAND_STUB_MERGE_LOG")"

# --- Usage errors. ---
rc="$(run_sut "$SUT" --help)"
check "--help exits 0" 0 "$rc"
check "--help prints usage" 1 "$(grep -c 'Usage:' "$WORK/stdout")"

rc="$(run_sut "$SUT")"
check "no PR number is a usage error" 2 "$rc"

rc="$(run_sut "$SUT" abc --repo test-owner/test-repo)"
check "a non-numeric PR number is refused, not a crash" 1 "$rc"

rc="$(run_sut "$SUT" 42 --repo test-owner/test-repo --update-mode bogus)"
check "an invalid --update-mode is a usage error" 2 "$rc"

rc="$(run_sut "$SUT" 42 --repo test-owner/test-repo --merge-state-poll-s bogus)"
check "an invalid --merge-state-poll-s is a usage error" 2 "$rc"

echo
echo "$((PASS + FAIL)) assertion(s), $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { echo "land-queue-selftest.sh: FAILED"; exit 1; }
echo "land-queue-selftest.sh: all assertions passed"
