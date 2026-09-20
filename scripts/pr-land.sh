#!/usr/bin/env bash
#
# pr-land.sh — merge a PR behind a required-check gate.
#
# Reads the base branch's required status-check contexts from its ruleset, the
# actual check-runs for the PR's head SHA, and the PR's review decision and
# merge state, and only then decides how to merge:
#
#   - every required context present and successful -> plain squash merge
#   - any required context present and failed/cancelled/timed_out -> refuse
#   - required contexts absent AND the PR author is a bot -> squash merge
#     with --admin, because a GITHUB_TOKEN-authored run never creates a
#     check-run at all (permanently absent, not failed)
#   - BLOCKED with reviewDecision REVIEW_REQUIRED, every required context
#     green and no check failing anywhere on the head SHA -> squash merge
#     with --admin
#   - anything else (pending, or partially absent on a human PR) -> refuse
#
# The two --admin paths are the two cases the owner's grant of 2026-09-19
# clears: a missing review with checks passing, and required contexts never
# produced. A required check that RAN AND FAILED is never bypassed by either,
# and any other check that ran and failed on the same head SHA cancels both.
#
# --admin is never a parameter: it is derived from the state above, so a
# caller cannot ask this script to launder a bypass it has no basis for.
#
# mergeStateStatus is computed lazily and answers UNKNOWN until GitHub has
# computed it, so it is re-read on a bounded budget. An UNKNOWN that never
# settles derives no bypass rather than guessing one.
#
# The PR's state is always read back after a merge attempt, and the script
# exits non-zero unless it reads MERGED — a classifier denial is not proof
# the merge did not happen, and the merge command's own exit code is not
# trusted either.
#
# Usage:
#   pr-land.sh <pr-number> [--repo OWNER/REPO] [--dry-run]
#                          [--merge-state-poll-s N]
#
# --repo defaults to the current directory's repository. --dry-run reads and
# prints the decision without merging. --merge-state-poll-s bounds the UNKNOWN
# re-read in seconds (default 30; 0 reads once and does not poll).
#
# Requires: gh, authenticated with permission to read rules and check-runs for
# the target repo, and to merge with --admin when the derivation above reaches
# one of its two bypass cases.

set -uo pipefail

PR=""
REPO=""
DRY_RUN=0
MERGE_STATE_POLL_S=30

usage() {
    sed -n '3,46p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --repo)
            [ $# -ge 2 ] || { echo "pr-land.sh: --repo needs a value" >&2; exit 2; }
            REPO="$2"
            shift 2
            ;;
        --repo=*)
            REPO="${1#--repo=}"
            shift
            ;;
        --merge-state-poll-s)
            [ $# -ge 2 ] || { echo "pr-land.sh: --merge-state-poll-s needs a value" >&2; exit 2; }
            MERGE_STATE_POLL_S="$2"
            shift 2
            ;;
        --merge-state-poll-s=*)
            MERGE_STATE_POLL_S="${1#--merge-state-poll-s=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "pr-land.sh: unknown option: $1 (try --help)" >&2
            exit 2
            ;;
        *)
            if [ -n "$PR" ]; then
                echo "pr-land.sh: unexpected argument: $1" >&2
                exit 2
            fi
            PR="$1"
            shift
            ;;
    esac
done

if [ -z "$PR" ]; then
    echo "pr-land.sh: PR number required (try --help)" >&2
    exit 2
fi

case "$PR" in
    ''|*[!0-9]*)
        echo "pr-land.sh: PR number must be numeric, got: $PR" >&2
        exit 2
        ;;
esac

case "$MERGE_STATE_POLL_S" in
    ''|*[!0-9]*)
        echo "pr-land.sh: --merge-state-poll-s must be a number, got: $MERGE_STATE_POLL_S" >&2
        exit 2
        ;;
esac

if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || {
        echo "pr-land.sh: could not resolve repo; pass --repo OWNER/REPO" >&2
        exit 1
    }
fi

read_pr_line() {
    gh pr view "$PR" --repo "$REPO" \
        --json baseRefName,headRefOid,author,state,mergeStateStatus,reviewDecision \
        --jq '[.baseRefName, .headRefOid, (.author.is_bot|tostring), .author.login,
               .state, .mergeStateStatus, (.reviewDecision // "")] | @tsv'
}

pr_line="$(read_pr_line)" || {
    echo "pr-land.sh: could not read PR $PR in $REPO" >&2
    exit 1
}

base_branch="$(printf '%s' "$pr_line" | cut -f1)"
head_sha="$(printf '%s' "$pr_line" | cut -f2)"
is_bot="$(printf '%s' "$pr_line" | cut -f3)"
author_login="$(printf '%s' "$pr_line" | cut -f4)"
pr_state="$(printf '%s' "$pr_line" | cut -f5)"
merge_state="$(printf '%s' "$pr_line" | cut -f6)"
review_decision="$(printf '%s' "$pr_line" | cut -f7)"

# mergeStateStatus is lazily computed: the first read can be UNKNOWN. Re-read
# it on a bounded budget instead of branching on a value GitHub has not
# computed yet.
poll_waited=0
while [ "$merge_state" = "UNKNOWN" ] && [ "$poll_waited" -lt "$MERGE_STATE_POLL_S" ]; do
    sleep 2
    poll_waited=$((poll_waited + 2))
    pr_line="$(read_pr_line)" || break
    pr_state="$(printf '%s' "$pr_line" | cut -f5)"
    merge_state="$(printf '%s' "$pr_line" | cut -f6)"
    review_decision="$(printf '%s' "$pr_line" | cut -f7)"
done

if [ "$merge_state" = "UNKNOWN" ]; then
    echo "pr-land.sh: mergeStateStatus is still UNKNOWN after ${poll_waited}s — deriving no bypass from it" >&2
fi

if [ "$pr_state" != "OPEN" ]; then
    echo "pr-land.sh: PR $PR is not open (state: $pr_state)" >&2
    exit 1
fi

required_raw="$(gh api "repos/$REPO/rules/branches/$base_branch" \
    --jq '.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context' \
    | sort -u)" || {
    echo "pr-land.sh: could not read branch rules for $REPO@$base_branch" >&2
    exit 1
}

check_runs_raw="$(gh api --paginate "repos/$REPO/commits/$head_sha/check-runs" \
    --jq '.check_runs[] | [.name, .status, (.conclusion // "null"), (.started_at // "")] | @tsv')" || {
    echo "pr-land.sh: could not read check-runs for $REPO@$head_sha" >&2
    exit 1
}

# One row per check name, its latest run by started_at, so a superseded
# earlier run of the same check never decides anything.
latest_runs="$(printf '%s\n' "$check_runs_raw" | awk -F'\t' '
    NF >= 3 { if (!($1 in row) || $4 >= when[$1]) { row[$1] = $0; when[$1] = $4 } }
    END { for (k in row) print row[k] }')"

required_count=0
present_count=0
success_count=0
fail_context=""
fail_conclusion=""

while IFS= read -r ctx; do
    [ -z "$ctx" ] && continue
    required_count=$((required_count + 1))
    matched="$(printf '%s\n' "$latest_runs" | awk -F'\t' -v n="$ctx" '$1==n')"
    [ -z "$matched" ] && continue
    present_count=$((present_count + 1))
    status="$(printf '%s' "$matched" | cut -f2)"
    conclusion="$(printf '%s' "$matched" | cut -f3)"
    if [ "$status" = "completed" ] && [ "$conclusion" = "success" ]; then
        success_count=$((success_count + 1))
        continue
    fi
    if [ "$status" = "completed" ] && [ -z "$fail_context" ]; then
        case "$conclusion" in
            failure|cancelled|timed_out)
                fail_context="$ctx"
                fail_conclusion="$conclusion"
                ;;
        esac
    fi
done <<<"$required_raw"

# A check nobody required still cancels both bypass paths: the grant clears a
# missing review only while every reported check is passing.
other_fail_context=""
other_fail_conclusion=""
while IFS= read -r row; do
    [ -z "$row" ] && continue
    row_name="$(printf '%s' "$row" | cut -f1)"
    if printf '%s\n' "$required_raw" | grep -Fxq -- "$row_name"; then
        continue
    fi
    row_conclusion="$(printf '%s' "$row" | cut -f3)"
    case "$row_conclusion" in
        failure|cancelled|timed_out)
            other_fail_context="$row_name"
            other_fail_conclusion="$row_conclusion"
            break
            ;;
    esac
done <<<"$latest_runs"

review_blocked=0
if [ "$review_decision" = "REVIEW_REQUIRED" ] && [ "$merge_state" = "BLOCKED" ]; then
    review_blocked=1
fi

decision=""
if [ -n "$fail_context" ]; then
    decision=refuse_failed
elif [ "$required_count" -gt 0 ] && [ "$present_count" -eq 0 ]; then
    if [ "$is_bot" != "true" ]; then
        decision=refuse_absent
    elif [ -n "$other_fail_context" ]; then
        decision=refuse_other_failed
    else
        decision=admin_absent
    fi
elif [ "$success_count" -ne "$required_count" ]; then
    decision=refuse_other
elif [ "$review_blocked" -eq 1 ]; then
    if [ -n "$other_fail_context" ]; then
        decision=refuse_other_failed
    else
        decision=admin_review
    fi
else
    decision=merge
fi

case "$decision" in
    refuse_failed)
        echo "pr-land.sh: refusing PR $PR — required check '$fail_context' is $fail_conclusion; a check that ran and failed is never bypassed" >&2
        exit 1
        ;;
    refuse_other_failed)
        echo "pr-land.sh: refusing PR $PR — check '$other_fail_context' is $other_fail_conclusion; a check that ran and failed is never bypassed" >&2
        exit 1
        ;;
    refuse_absent)
        echo "pr-land.sh: refusing PR $PR — required checks are absent and author '$author_login' is not a bot" >&2
        exit 1
        ;;
    refuse_other)
        echo "pr-land.sh: refusing PR $PR — $success_count/$required_count required checks succeeded, $present_count/$required_count present" >&2
        exit 1
        ;;
esac

merge_args=(pr merge "$PR" --repo "$REPO" --squash --delete-branch)
case "$decision" in
    admin_absent)
        merge_args+=(--admin)
        echo "pr-land.sh: bypassing with --admin — required checks are absent and author '$author_login' is a bot (a GITHUB_TOKEN-authored run creates zero check-runs, not a failure)"
        ;;
    admin_review)
        merge_args+=(--admin)
        echo "pr-land.sh: bypassing with --admin — reviewDecision REVIEW_REQUIRED and mergeStateStatus BLOCKED with $success_count/$required_count required checks green and nothing failed (a missing review is bypassable, a failed check never is)"
        ;;
    *)
        echo "pr-land.sh: all required checks green — merging PR $PR"
        ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then
    echo "pr-land.sh: --dry-run, not merging"
    exit 0
fi

gh "${merge_args[@]}"
merge_rc=$?
[ "$merge_rc" -eq 0 ] || echo "pr-land.sh: merge command exited $merge_rc; reading PR state back before deciding anything" >&2

final_state="$(gh pr view "$PR" --repo "$REPO" --json state --jq .state)" || final_state=""

if [ "$final_state" != "MERGED" ]; then
    echo "pr-land.sh: PR $PR is not MERGED (state: ${final_state:-unknown}) — treating this as a failure regardless of the merge command's own exit status" >&2
    exit 1
fi

echo "pr-land.sh: PR $PR merged"
