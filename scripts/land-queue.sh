#!/usr/bin/env bash
#
# land-queue.sh — land a list of pull requests against one repo, serialized
# and refreshed. The merge decision itself is never made here: each PR, once
# fresh and green, is handed to pr-land.sh (alongside this script), and
# --admin is never passed to it — pr-land.sh derives that bypass itself from
# observed state, and passing it here would launder a bypass this script has
# no basis for.
#
# Two guarantees the merge decision alone does not provide:
#
#   G1  mutual exclusion — one land-queue.sh run per repo at a time, via a
#       lock keyed on the repo slug, never the checkout path.
#   G2  freshness — a PR behind its base is updated before it can be merged,
#       a PR conflicting with its base is refused before the merge gate is
#       ever called, a required check that has not concluded is waited for no
#       matter who moved the head SHA, and nothing is ever decided from a
#       mergeStateStatus GitHub has not computed yet.
#
# Per PR, in order: read state until mergeStateStatus is a real value rather
# than UNKNOWN; skip unless OPEN; refuse a DIRTY PR, naming its base and the
# files it changes; if behind its base, update the branch and refuse this PR
# on conflict; if any check has not concluded, or the head SHA moved, wait for
# required checks and refuse this PR if they do not all pass; call pr-land.sh;
# then read the PR's state back and require MERGED, regardless of pr-land.sh's
# own exit code — a classifier denial or a flaky exit status is not proof
# either way.
#
# Every forge call goes through one of five named functions:
# repo_default_slug, pr_read, pr_files, pr_update_branch, pr_wait_checks.
#
# Usage:
#   land-queue.sh <pr-number>... [--repo OWNER/REPO]
#                 [--update-mode merge|rebase] [--wait-checks-s N]
#                 [--merge-state-poll-s N] [--stop-on-refusal]
#                 [--lock-timeout-s N] [--state-dir PATH] [--dry-run]
#
# Exit codes:
#   0   every PR merged (or nothing OPEN was left to do)
#   1   work began and at least one PR did not land
#   2   refused before mutating anything — bad input, or the repo lock is
#       held by another run
#
# Env:
#   LAND_QUEUE_STATE   lock directory (default: $XDG_STATE_HOME, else
#                      ~/.local/state, under ai-toolkit/land-queue).
#                      --state-dir wins over this.
#
# Requires: gh, authenticated for the target repo; pr-land.sh in this same
# directory.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PR_LAND="$SCRIPT_DIR/pr-land.sh"

usage() {
    sed -n '3,50p' "$0" | sed 's/^# \{0,1\}//'
}

REPO=""
UPDATE_MODE="merge"
WAIT_CHECKS_S=1800
MERGE_STATE_POLL_S=60
STOP_ON_REFUSAL=0
LOCK_TIMEOUT_S=0
STATE_DIR=""
DRY_RUN=0
PR_LIST=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --repo)
            [ $# -ge 2 ] || { echo "land-queue.sh: --repo needs a value" >&2; exit 2; }
            REPO="$2"; shift 2 ;;
        --repo=*) REPO="${1#--repo=}"; shift ;;
        --update-mode)
            [ $# -ge 2 ] || { echo "land-queue.sh: --update-mode needs a value" >&2; exit 2; }
            UPDATE_MODE="$2"; shift 2 ;;
        --update-mode=*) UPDATE_MODE="${1#--update-mode=}"; shift ;;
        --wait-checks-s)
            [ $# -ge 2 ] || { echo "land-queue.sh: --wait-checks-s needs a value" >&2; exit 2; }
            WAIT_CHECKS_S="$2"; shift 2 ;;
        --wait-checks-s=*) WAIT_CHECKS_S="${1#--wait-checks-s=}"; shift ;;
        --merge-state-poll-s)
            [ $# -ge 2 ] || { echo "land-queue.sh: --merge-state-poll-s needs a value" >&2; exit 2; }
            MERGE_STATE_POLL_S="$2"; shift 2 ;;
        --merge-state-poll-s=*) MERGE_STATE_POLL_S="${1#--merge-state-poll-s=}"; shift ;;
        --stop-on-refusal) STOP_ON_REFUSAL=1; shift ;;
        --lock-timeout-s)
            [ $# -ge 2 ] || { echo "land-queue.sh: --lock-timeout-s needs a value" >&2; exit 2; }
            LOCK_TIMEOUT_S="$2"; shift 2 ;;
        --lock-timeout-s=*) LOCK_TIMEOUT_S="${1#--lock-timeout-s=}"; shift ;;
        --state-dir)
            [ $# -ge 2 ] || { echo "land-queue.sh: --state-dir needs a path" >&2; exit 2; }
            STATE_DIR="$2"; shift 2 ;;
        --state-dir=*) STATE_DIR="${1#--state-dir=}"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --) shift; break ;;
        -*)
            echo "land-queue.sh: unknown option: $1 (try --help)" >&2
            exit 2
            ;;
        *)
            PR_LIST+=("$1"); shift ;;
    esac
done

if [ "${#PR_LIST[@]}" -eq 0 ]; then
    echo "land-queue.sh: at least one PR number is required (try --help)" >&2
    exit 2
fi

case "$UPDATE_MODE" in
    merge|rebase) ;;
    *)
        echo "land-queue.sh: --update-mode must be merge or rebase, got: $UPDATE_MODE" >&2
        exit 2
        ;;
esac

case "$WAIT_CHECKS_S" in ''|*[!0-9]*)
    echo "land-queue.sh: --wait-checks-s must be a number, got: $WAIT_CHECKS_S" >&2
    exit 2
    ;;
esac

case "$MERGE_STATE_POLL_S" in ''|*[!0-9]*)
    echo "land-queue.sh: --merge-state-poll-s must be a number, got: $MERGE_STATE_POLL_S" >&2
    exit 2
    ;;
esac

case "$LOCK_TIMEOUT_S" in ''|*[!0-9]*)
    echo "land-queue.sh: --lock-timeout-s must be a number, got: $LOCK_TIMEOUT_S" >&2
    exit 2
    ;;
esac

repo_default_slug() {
    gh repo view --json nameWithOwner --jq .nameWithOwner
}

if [ -z "$REPO" ]; then
    REPO="$(repo_default_slug)" || {
        echo "land-queue.sh: could not resolve repo; pass --repo OWNER/REPO" >&2
        exit 2
    }
fi

# pr_read — one line of state, mergeStateStatus, headRefOid, baseRefName and
# the number of checks with no conclusion, so every caller decides from a
# single consistent snapshot.
pr_read() {
    gh pr view "$1" --repo "$2" \
        --json state,mergeStateStatus,headRefOid,baseRefName,statusCheckRollup \
        --jq '[.state, .mergeStateStatus, .headRefOid, .baseRefName,
               ([.statusCheckRollup[]?
                 | select((.__typename == "CheckRun" and .status != "COMPLETED")
                          or (.__typename == "StatusContext"
                              and (.state == "PENDING" or .state == "EXPECTED")))]
                | length | tostring)] | @tsv'
}

pr_files() {
    gh pr view "$1" --repo "$2" --json files --jq '[.files[]?.path] | join(", ")'
}

pr_update_branch() {
    local args=(pr update-branch "$1" --repo "$2")
    [ "$3" = "rebase" ] && args+=(--rebase)
    gh "${args[@]}"
}

# run_with_timeout SECS CMD... — SECS<=0 runs CMD unbounded. Portable bash
# 3.2 substitute for GNU `timeout`, which macOS does not ship.
run_with_timeout() {
    local secs="$1"; shift
    if [ "$secs" -le 0 ]; then
        "$@"
        return $?
    fi
    "$@" &
    local cmd_pid=$!
    ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) &
    local timer_pid=$!
    wait "$cmd_pid" 2>/dev/null
    local rc=$?
    kill "$timer_pid" 2>/dev/null
    wait "$timer_pid" 2>/dev/null
    return "$rc"
}

pr_wait_checks() {
    run_with_timeout "$3" gh pr checks "$1" --repo "$2" --required --watch --fail-fast
}

# pr_read_settled PR REPO — a pr_read whose mergeStateStatus is a value.
# GitHub computes that field lazily and answers UNKNOWN until it has, so this
# polls rather than hand a null to a decision. 1 = unreadable, 2 = still
# UNKNOWN when the budget ran out, which the caller must refuse on.
pr_read_settled() {
    local waited=0 line status
    while :; do
        line="$(pr_read "$1" "$2")" || return 1
        status="$(printf '%s' "$line" | cut -f2)"
        case "$status" in
            UNKNOWN|"") ;;
            *) printf '%s\n' "$line"; return 0 ;;
        esac
        [ "$waited" -ge "$MERGE_STATE_POLL_S" ] && return 2
        sleep 1
        waited=$((waited + 1))
    done
}

LOCK_ACQUIRED=0

release_repo_lock() {
    [ "$LOCK_ACQUIRED" = 1 ] || return 0
    LOCK_ACQUIRED=0
    rm -f "$1" 2>/dev/null
}

# acquire_repo_lock DIR — never waits on its own: wins the lock (0), finds it
# held by a live pid (1), or fails to write it at all (2). A holder with no
# live pid is reclaimed and retried, capped, so this never hangs on garbage.
acquire_repo_lock() {
    local dir="$1" attempt=0 tmp holder_pid
    while [ "$attempt" -lt 20 ]; do
        attempt=$((attempt + 1))
        tmp="$dir.holder.$$"
        printf 'pid=%s\nstarted=%s\n' "$$" "$(date +%s)" > "$tmp" || return 2
        if ln "$tmp" "$dir" 2>/dev/null; then
            rm -f "$tmp"
            LOCK_ACQUIRED=1
            return 0
        fi
        rm -f "$tmp"
        holder_pid=""
        [ -f "$dir" ] && holder_pid=$(awk -F= '/^pid=/{print $2}' "$dir" 2>/dev/null)
        case "$holder_pid" in ''|*[!0-9]*) holder_pid="" ;; esac
        if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2>/dev/null; then
            echo "land-queue.sh: the repo lock '$dir' is held by pid $holder_pid — another land-queue.sh run holds it" >&2
            return 1
        fi
        rm -f "$dir" 2>/dev/null
    done
    echo "land-queue.sh: could not acquire the repo lock '$dir' after $attempt attempts" >&2
    return 1
}

slug_key() { printf '%s' "$1" | tr '/' '_'; }

default_state_dir() {
    printf '%s/ai-toolkit/land-queue' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

state_dir="${STATE_DIR:-${LAND_QUEUE_STATE:-$(default_state_dir)}}"
mkdir -p "$state_dir" || { echo "land-queue.sh: could not create state dir '$state_dir'" >&2; exit 2; }
lock_file="$state_dir/$(slug_key "$REPO").lock"

any_refused=0

if [ "$DRY_RUN" -eq 1 ]; then
    for pr in "${PR_LIST[@]}"; do
        case "$pr" in
            ''|*[!0-9]*)
                echo "land-queue.sh: PR number must be numeric, got: $pr" >&2
                any_refused=1
                continue
                ;;
        esac
        line="$(pr_read "$pr" "$REPO")" || { echo "land-queue.sh: could not read PR $pr" >&2; any_refused=1; continue; }
        state="$(printf '%s' "$line" | cut -f1)"
        mergestatus="$(printf '%s' "$line" | cut -f2)"
        base="$(printf '%s' "$line" | cut -f4)"
        unconcluded="$(printf '%s' "$line" | cut -f5)"
        echo "land-queue.sh: --dry-run — PR $pr against $base is $state (mergeStateStatus: $mergestatus, unconcluded checks: $unconcluded), not touching it"
    done
    [ "$any_refused" -eq 1 ] && exit 1
    exit 0
fi

lock_waited=0
while :; do
    acquire_repo_lock "$lock_file"
    lock_rc=$?
    [ "$lock_rc" -eq 0 ] && break
    [ "$lock_rc" -eq 2 ] && exit 2
    [ "$lock_waited" -ge "$LOCK_TIMEOUT_S" ] && exit 2
    sleep 1
    lock_waited=$((lock_waited + 1))
done
trap 'release_repo_lock "$lock_file"' EXIT

base_moved=0

for pr in "${PR_LIST[@]}"; do
    case "$pr" in
        ''|*[!0-9]*)
            echo "land-queue.sh: PR number must be numeric, got: $pr" >&2
            any_refused=1
            [ "$STOP_ON_REFUSAL" -eq 1 ] && break
            continue
            ;;
    esac

    # This run has already moved the base, so the first read of the next PR can
    # still answer from the computation GitHub did before that merge. Discard
    # it: the read after it is the one taken against the new base.
    if [ "$base_moved" -eq 1 ]; then
        pr_read "$pr" "$REPO" >/dev/null 2>&1
    fi

    line="$(pr_read_settled "$pr" "$REPO")"
    read_rc=$?
    if [ "$read_rc" -eq 2 ]; then
        echo "land-queue.sh: refusing PR $pr — mergeStateStatus never left UNKNOWN within ${MERGE_STATE_POLL_S}s, and a lazily-computed field is never acted on" >&2
        any_refused=1
        [ "$STOP_ON_REFUSAL" -eq 1 ] && break
        continue
    fi
    if [ "$read_rc" -ne 0 ]; then
        echo "land-queue.sh: could not read PR $pr in $REPO" >&2
        any_refused=1
        [ "$STOP_ON_REFUSAL" -eq 1 ] && break
        continue
    fi
    state="$(printf '%s' "$line" | cut -f1)"
    mergestatus="$(printf '%s' "$line" | cut -f2)"
    head_sha="$(printf '%s' "$line" | cut -f3)"
    base="$(printf '%s' "$line" | cut -f4)"
    unconcluded="$(printf '%s' "$line" | cut -f5)"
    case "$unconcluded" in ''|*[!0-9]*) unconcluded=0 ;; esac

    if [ "$state" != "OPEN" ]; then
        echo "land-queue.sh: skipping PR $pr — not open (state: $state)"
        continue
    fi

    if [ "$mergestatus" = "DIRTY" ]; then
        changed="$(pr_files "$pr" "$REPO")" || changed=""
        echo "land-queue.sh: refusing PR $pr — it conflicts with its base $base (mergeStateStatus: DIRTY), so the merge gate is never called; resolve the conflict first${changed:+ (it changes: $changed)}" >&2
        any_refused=1
        [ "$STOP_ON_REFUSAL" -eq 1 ] && break
        continue
    fi

    new_head="$head_sha"
    if [ "$mergestatus" = "BEHIND" ]; then
        echo "land-queue.sh: PR $pr is behind $base — updating ($UPDATE_MODE)"
        if ! pr_update_branch "$pr" "$REPO" "$UPDATE_MODE"; then
            echo "land-queue.sh: refusing PR $pr — could not update its branch (conflict?)" >&2
            any_refused=1
            [ "$STOP_ON_REFUSAL" -eq 1 ] && break
            continue
        fi
        line2="$(pr_read_settled "$pr" "$REPO")"
        read2_rc=$?
        if [ "$read2_rc" -ne 0 ]; then
            echo "land-queue.sh: refusing PR $pr — could not re-read it after updating its branch" >&2
            any_refused=1
            [ "$STOP_ON_REFUSAL" -eq 1 ] && break
            continue
        fi
        new_head="$(printf '%s' "$line2" | cut -f3)"
        unconcluded="$(printf '%s' "$line2" | cut -f5)"
        case "$unconcluded" in ''|*[!0-9]*) unconcluded=0 ;; esac
    fi

    if [ "$new_head" != "$head_sha" ] || [ "$unconcluded" -gt 0 ]; then
        if [ "$new_head" != "$head_sha" ]; then
            echo "land-queue.sh: PR $pr head moved to $new_head — waiting for required checks"
        else
            echo "land-queue.sh: PR $pr has $unconcluded check(s) with no conclusion — waiting for required checks"
        fi
        if ! pr_wait_checks "$pr" "$REPO" "$WAIT_CHECKS_S"; then
            echo "land-queue.sh: refusing PR $pr — required checks did not all pass" >&2
            any_refused=1
            [ "$STOP_ON_REFUSAL" -eq 1 ] && break
            continue
        fi
    fi

    "$PR_LAND" "$pr" --repo "$REPO"
    land_rc=$?
    [ "$land_rc" -eq 0 ] || echo "land-queue.sh: pr-land.sh exited $land_rc for PR $pr — reading state back before deciding anything" >&2

    final_line="$(pr_read "$pr" "$REPO")" || final_line=""
    final_state="$(printf '%s' "$final_line" | cut -f1)"
    if [ "$final_state" != "MERGED" ]; then
        echo "land-queue.sh: refusing PR $pr — did not read back MERGED (state: ${final_state:-unknown})" >&2
        any_refused=1
        [ "$STOP_ON_REFUSAL" -eq 1 ] && break
        continue
    fi
    base_moved=1
    echo "land-queue.sh: PR $pr landed"
done

[ "$any_refused" -eq 1 ] && exit 1
exit 0
