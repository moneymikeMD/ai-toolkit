#!/usr/bin/env bash
#
# pr-land.sh — merge a PR behind a required-check gate.
#
# Reads the base branch's required status-check contexts from its ruleset,
# reads the actual check-runs for the PR's head SHA, and only then decides
# how to merge:
#
#   - every required context present and successful -> plain squash merge
#   - any required context present and failed/cancelled/timed_out -> refuse
#   - required contexts absent AND the PR author is a bot -> squash merge
#     with --admin, because a GITHUB_TOKEN-authored run never creates a
#     check-run at all (permanently absent, not failed)
#   - anything else (pending, or partially absent on a human PR) -> refuse
#
# --admin is never a parameter: it is derived from the state above, so a
# caller cannot ask this script to launder a bypass it has no basis for.
#
# The PR's state is always read back after a merge attempt, and the script
# exits non-zero unless it reads MERGED — a classifier denial is not proof
# the merge did not happen, and the merge command's own exit code is not
# trusted either.
#
# Usage:
#   pr-land.sh <pr-number> [--repo OWNER/REPO] [--dry-run]
#
# --repo defaults to the current directory's repository. --dry-run reads
# and prints the decision without merging.
#
# Requires: gh, authenticated with permission to read rules and check-runs
# for the target repo, and to merge with --admin when a bot PR needs it.

set -uo pipefail

PR=""
REPO=""
DRY_RUN=0

usage() {
    sed -n '3,31p' "$0" | sed 's/^# \{0,1\}//'
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

if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || {
        echo "pr-land.sh: could not resolve repo; pass --repo OWNER/REPO" >&2
        exit 1
    }
fi

pr_line="$(gh pr view "$PR" --repo "$REPO" \
    --json baseRefName,headRefOid,author,state \
    --jq '[.baseRefName, .headRefOid, (.author.is_bot|tostring), .author.login, .state] | @tsv')" || {
    echo "pr-land.sh: could not read PR $PR in $REPO" >&2
    exit 1
}

base_branch="$(printf '%s' "$pr_line" | cut -f1)"
head_sha="$(printf '%s' "$pr_line" | cut -f2)"
is_bot="$(printf '%s' "$pr_line" | cut -f3)"
author_login="$(printf '%s' "$pr_line" | cut -f4)"
pr_state="$(printf '%s' "$pr_line" | cut -f5)"

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

required_count=0
present_count=0
success_count=0
fail_context=""
fail_conclusion=""

while IFS= read -r ctx; do
    [ -z "$ctx" ] && continue
    required_count=$((required_count + 1))
    matched="$(printf '%s\n' "$check_runs_raw" \
        | awk -F'\t' -v n="$ctx" '$1==n' \
        | sort -t "$(printf '\t')" -k4,4 \
        | tail -n1)"
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

decision=""
if [ "$required_count" -eq 0 ]; then
    decision=merge
elif [ -n "$fail_context" ]; then
    decision=refuse_failed
elif [ "$present_count" -eq 0 ]; then
    if [ "$is_bot" = "true" ]; then
        decision=admin_merge
    else
        decision=refuse_absent
    fi
elif [ "$success_count" -eq "$required_count" ]; then
    decision=merge
else
    decision=refuse_other
fi

case "$decision" in
    refuse_failed)
        echo "pr-land.sh: refusing PR $PR — required check '$fail_context' is $fail_conclusion" >&2
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
if [ "$decision" = "admin_merge" ]; then
    merge_args+=(--admin)
    echo "pr-land.sh: bypassing with --admin — required checks are absent and author '$author_login' is a bot (a GITHUB_TOKEN-authored run creates zero check-runs, not a failure)"
else
    echo "pr-land.sh: all required checks green — merging PR $PR"
fi

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
