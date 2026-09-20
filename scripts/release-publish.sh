#!/usr/bin/env bash
#
# release-publish.sh — publish a release-please release: assert the open
# PR computes to the requested level, merge it via pr-land.sh, wait for
# the resulting release and main CI, then move the floating major tag via
# tag-major.sh. A major release is refused unless --i-am-the-owner is
# passed; majors remain the owner's call, enforced in code rather than
# left to a sentence in a handoff document.
#
# The merge is delegated to pr-land.sh (next to this script) rather than
# reimplemented, so the required-check gate has one implementation. A
# release-please PR is bot-authored and its own workflow run produces zero
# check-runs (a GITHUB_TOKEN-authored event never creates one); that is
# pr-land.sh's concern, not this script's.
#
# If more than one open PR looks like a release-please PR — a sibling
# package's release PR can be open at the same time, and merging one
# leaves the other DIRTY against the shared manifest file until
# release-please's own bot catches up — this refuses rather than guess,
# and asks for --pr NUMBER.
#
# Usage:
#   release-publish.sh <major|minor|patch> [--repo OWNER/REPO] [--pr NUMBER]
#                       [--i-am-the-owner] [--wait-timeout-s N] [--dry-run]
#
#   --repo OWNER/REPO   default: resolved via `gh repo view` in the cwd.
#   --pr NUMBER         use this PR instead of auto-discovering the one
#                        open release-please PR.
#   --i-am-the-owner    required to publish a major release.
#   --wait-timeout-s N  seconds to wait for CI and the release (default 1800).
#   --dry-run           decide and print; merge, wait and tag nothing.
#
# Reads the current version from ./.release-please-manifest.json in the
# cwd, so this runs from inside the target repo's own checkout.
#
# Requires: gh, authenticated for the target repo; pr-land.sh and
# tag-major.sh next to this script.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PR_LAND="$SCRIPT_DIR/pr-land.sh"
TAG_MAJOR="$SCRIPT_DIR/tag-major.sh"

LEVEL=""
REPO=""
PR=""
OWNER_OK=0
WAIT_TIMEOUT_S=1800
DRY_RUN=0

usage() { sed -n '3,31p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --repo)
            [ $# -ge 2 ] || { echo "release-publish.sh: --repo needs a value" >&2; exit 2; }
            REPO="$2"
            shift 2
            ;;
        --repo=*)
            REPO="${1#--repo=}"
            shift
            ;;
        --pr)
            [ $# -ge 2 ] || { echo "release-publish.sh: --pr needs a value" >&2; exit 2; }
            PR="$2"
            shift 2
            ;;
        --pr=*)
            PR="${1#--pr=}"
            shift
            ;;
        --i-am-the-owner)
            OWNER_OK=1
            shift
            ;;
        --wait-timeout-s)
            [ $# -ge 2 ] || { echo "release-publish.sh: --wait-timeout-s needs a value" >&2; exit 2; }
            WAIT_TIMEOUT_S="$2"
            shift 2
            ;;
        --wait-timeout-s=*)
            WAIT_TIMEOUT_S="${1#--wait-timeout-s=}"
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
            echo "release-publish.sh: unknown option: $1 (try --help)" >&2
            exit 2
            ;;
        *)
            [ -z "$LEVEL" ] || { echo "release-publish.sh: unexpected argument: $1" >&2; exit 2; }
            LEVEL="$1"
            shift
            ;;
    esac
done

case "$LEVEL" in
    major|minor|patch) ;;
    "")
        echo "release-publish.sh: a level (major|minor|patch) is required (try --help)" >&2
        exit 2
        ;;
    *)
        echo "release-publish.sh: level must be major, minor or patch, got: $LEVEL" >&2
        exit 2
        ;;
esac

case "$WAIT_TIMEOUT_S" in
    ''|*[!0-9]*)
        echo "release-publish.sh: --wait-timeout-s must be a number, got: $WAIT_TIMEOUT_S" >&2
        exit 2
        ;;
esac

if [ -n "$PR" ]; then
    case "$PR" in
        ''|*[!0-9]*)
            echo "release-publish.sh: --pr must be numeric, got: $PR" >&2
            exit 2
            ;;
    esac
fi

if [ "$LEVEL" = major ] && [ "$OWNER_OK" -ne 1 ]; then
    echo "release-publish.sh: refusing a MAJOR release without --i-am-the-owner — majors remain the owner's call" >&2
    exit 1
fi

if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || {
        echo "release-publish.sh: could not resolve repo; pass --repo OWNER/REPO" >&2
        exit 1
    }
fi

MANIFEST=".release-please-manifest.json"
[ -f "$MANIFEST" ] || {
    echo "release-publish.sh: $MANIFEST not found in the current directory — run this from the repo's checkout" >&2
    exit 1
}
old_version="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$MANIFEST" | head -n1)"
[ -n "$old_version" ] || {
    echo "release-publish.sh: could not find a version in $MANIFEST" >&2
    exit 1
}

if [ -z "$PR" ]; then
    candidates="$(gh pr list --repo "$REPO" --state open --json number,headRefName,title \
        --jq '[.[] | select(.headRefName | startswith("release-please--"))] | .[] | [.number, .headRefName, .title] | @tsv')" || {
        echo "release-publish.sh: could not list open PRs for $REPO" >&2
        exit 1
    }
    count="$(printf '%s\n' "$candidates" | grep -c .)"
    if [ "$count" -eq 0 ]; then
        echo "release-publish.sh: no open release-please PR found in $REPO" >&2
        exit 1
    fi
    if [ "$count" -gt 1 ]; then
        echo "release-publish.sh: refusing — $count open release-please PRs found in $REPO (a sibling package's release PR can be open at once); pass --pr NUMBER:" >&2
        printf '%s\n' "$candidates" | sed 's/^/  /' >&2
        exit 1
    fi
    PR="$(printf '%s' "$candidates" | cut -f1)"
    pr_title="$(printf '%s' "$candidates" | cut -f3)"
else
    pr_line="$(gh pr view "$PR" --repo "$REPO" --json state,headRefName,title,author \
        --jq '[.state, .headRefName, .title, (.author.is_bot|tostring)] | @tsv')" || {
        echo "release-publish.sh: could not read PR $PR in $REPO" >&2
        exit 1
    }
    pr_state="$(printf '%s' "$pr_line" | cut -f1)"
    pr_head="$(printf '%s' "$pr_line" | cut -f2)"
    pr_title="$(printf '%s' "$pr_line" | cut -f3)"
    pr_is_bot="$(printf '%s' "$pr_line" | cut -f4)"
    if [ "$pr_state" != OPEN ] || [ "$pr_is_bot" != true ] || [ "${pr_head#release-please--}" = "$pr_head" ]; then
        echo "release-publish.sh: PR $PR in $REPO does not look like an open release-please PR (state=$pr_state, bot=$pr_is_bot, head=$pr_head)" >&2
        exit 1
    fi
fi

new_version="$(printf '%s' "$pr_title" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
[ -n "$new_version" ] || {
    echo "release-publish.sh: could not find a version in PR #$PR's title: $pr_title" >&2
    exit 1
}

IFS=. read -r old_maj old_min old_pat <<<"$old_version"
IFS=. read -r new_maj new_min new_pat <<<"$new_version"

computed=""
if [ "$new_maj" -gt "$old_maj" ]; then
    computed="major"
elif [ "$new_maj" -eq "$old_maj" ] && [ "$new_min" -gt "$old_min" ]; then
    computed="minor"
elif [ "$new_maj" -eq "$old_maj" ] && [ "$new_min" -eq "$old_min" ] && [ "$new_pat" -gt "$old_pat" ]; then
    computed="patch"
else
    echo "release-publish.sh: PR #$PR's version ($new_version) is not newer than the manifest's ($old_version)" >&2
    exit 1
fi

if [ "$computed" != "$LEVEL" ]; then
    echo "release-publish.sh: refusing — PR #$PR computes to a $computed release ($old_version -> $new_version), not $LEVEL as requested" >&2
    exit 1
fi

echo "release-publish.sh: PR #$PR computes to $computed ($old_version -> $new_version) in $REPO — matches requested $LEVEL"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "release-publish.sh: --dry-run — not merging, not waiting, not tagging"
    exit 0
fi

if ! "$PR_LAND" "$PR" --repo "$REPO"; then
    echo "release-publish.sh: pr-land.sh refused PR #$PR — not proceeding" >&2
    exit 1
fi

merge_line="$(gh pr view "$PR" --repo "$REPO" --json state,mergeCommit --jq '[.state, (.mergeCommit.oid // "")] | @tsv')" || {
    echo "release-publish.sh: could not read PR $PR back after merge" >&2
    exit 1
}
merge_state="$(printf '%s' "$merge_line" | cut -f1)"
merge_sha="$(printf '%s' "$merge_line" | cut -f2)"
if [ "$merge_state" != MERGED ] || [ -z "$merge_sha" ]; then
    echo "release-publish.sh: PR #$PR is not confirmed merged (state=$merge_state) — not proceeding" >&2
    exit 1
fi

echo "release-publish.sh: PR #$PR merged as $merge_sha — waiting for CI"

deadline=$(( $(date +%s) + WAIT_TIMEOUT_S ))
ci_ok=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    runs="$(gh api --paginate "repos/$REPO/commits/$merge_sha/check-runs" \
        --jq '.check_runs[] | [.status, (.conclusion // "null")] | @tsv')" || runs=""
    if [ -n "$runs" ] && ! printf '%s\n' "$runs" | grep -qv $'^completed\t'; then
        if printf '%s\n' "$runs" | cut -f2 | grep -Eq '^(failure|cancelled|timed_out)$'; then
            echo "release-publish.sh: main CI failed on $merge_sha:" >&2
            printf '%s\n' "$runs" | sed 's/^/  /' >&2
            exit 1
        fi
        ci_ok=1
        break
    fi
    sleep 3
done
if [ "$ci_ok" -ne 1 ]; then
    echo "release-publish.sh: timed out waiting for CI on $merge_sha" >&2
    exit 1
fi
echo "release-publish.sh: main CI green on $merge_sha"

echo "release-publish.sh: waiting for release v$new_version"
deadline=$(( $(date +%s) + WAIT_TIMEOUT_S ))
release_ok=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    if gh release view "v$new_version" --repo "$REPO" --json tagName >/dev/null 2>&1; then
        release_ok=1
        break
    fi
    sleep 3
done
if [ "$release_ok" -ne 1 ]; then
    echo "release-publish.sh: timed out waiting for release v$new_version to appear" >&2
    exit 1
fi
echo "release-publish.sh: release v$new_version confirmed"

if ! "$TAG_MAJOR" --repo "$REPO"; then
    echo "release-publish.sh: tag-major.sh failed to move the floating major tag" >&2
    exit 1
fi

echo "release-publish.sh: published $LEVEL release v$new_version in $REPO and moved the floating major tag"
