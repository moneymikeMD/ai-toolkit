#!/usr/bin/env bash
#
# tag-major.sh — re-point a floating major tag (vN) onto the newest real
# version tag (vN.Y.Z), the step release-please itself never takes.
#
# Finds the highest vN.Y.Z tag in the repo and derives vN from it. A real
# version tag is never re-pointed — only the floating major is — so
# whatever tag name is about to be force-moved (derived, or given via
# --major-tag) is checked against the vN.Y.Z pattern and refused if it
# matches; that guard is the reason this script exists.
#
# The move is via the GitHub Git Data API rather than a local git push, so
# it runs from any directory once --repo is known: PATCH the ref if it
# exists, POST a new one if it does not, then GET it back and refuse
# unless the read-back SHA equals the intended commit — a push's own exit
# code has reported success for a move that did not land before.
#
# Usage:
#   tag-major.sh [--repo OWNER/REPO] [--major-tag NAME] [--dry-run]
#
#   --repo OWNER/REPO   default: resolved via `gh repo view` in the cwd.
#   --major-tag NAME    force-move NAME instead of the derived vN. Refused
#                        if NAME matches vN.Y.Z.
#   --dry-run           print the intended move without pushing.
#
# Requires: gh, authenticated with push access to the target repo.

set -uo pipefail

REPO=""
MAJOR_OVERRIDE=""
DRY_RUN=0

usage() { sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --repo)
            [ $# -ge 2 ] || { echo "tag-major.sh: --repo needs a value" >&2; exit 2; }
            REPO="$2"
            shift 2
            ;;
        --repo=*)
            REPO="${1#--repo=}"
            shift
            ;;
        --major-tag)
            [ $# -ge 2 ] || { echo "tag-major.sh: --major-tag needs a value" >&2; exit 2; }
            MAJOR_OVERRIDE="$2"
            shift 2
            ;;
        --major-tag=*)
            MAJOR_OVERRIDE="${1#--major-tag=}"
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
            echo "tag-major.sh: unknown option: $1 (try --help)" >&2
            exit 2
            ;;
        *)
            echo "tag-major.sh: unexpected argument: $1 (try --help)" >&2
            exit 2
            ;;
    esac
done

if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || {
        echo "tag-major.sh: could not resolve repo; pass --repo OWNER/REPO" >&2
        exit 1
    }
fi

is_version_tag() {
    printf '%s' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'
}

tags_raw="$(gh api --paginate "repos/$REPO/tags" --jq '.[] | [.name, .commit.sha] | @tsv')" || {
    echo "tag-major.sh: could not list tags for $REPO" >&2
    exit 1
}

newest_tag=""
newest_sha=""
while IFS=$'\t' read -r name sha; do
    [ -z "$name" ] && continue
    is_version_tag "$name" || continue
    if [ -z "$newest_tag" ]; then
        newest_tag="$name"
        newest_sha="$sha"
        continue
    fi
    higher="$(printf '%s\n%s\n' "$newest_tag" "$name" | sort -V | tail -n1)"
    if [ "$higher" = "$name" ] && [ "$name" != "$newest_tag" ]; then
        newest_tag="$name"
        newest_sha="$sha"
    fi
done <<<"$tags_raw"

if [ -z "$newest_tag" ]; then
    echo "tag-major.sh: no vX.Y.Z tags found in $REPO" >&2
    exit 1
fi

derived_major="$(printf '%s' "$newest_tag" | sed -E 's/^(v[0-9]+)\.[0-9]+\.[0-9]+$/\1/')"
MAJOR="${MAJOR_OVERRIDE:-$derived_major}"

if is_version_tag "$MAJOR"; then
    echo "tag-major.sh: refusing to move '$MAJOR' — it matches a real vX.Y.Z tag, and a real version tag is never re-pointed" >&2
    exit 1
fi

echo "tag-major.sh: moving $MAJOR -> $newest_sha (from $newest_tag) in $REPO"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "tag-major.sh: --dry-run — not pushing"
    exit 0
fi

if gh api "repos/$REPO/git/ref/tags/$MAJOR" >/dev/null 2>&1; then
    gh api -X PATCH "repos/$REPO/git/refs/tags/$MAJOR" -f sha="$newest_sha" -F force=true >/dev/null || {
        echo "tag-major.sh: could not update ref tags/$MAJOR" >&2
        exit 1
    }
else
    gh api -X POST "repos/$REPO/git/refs" -f ref="refs/tags/$MAJOR" -f sha="$newest_sha" >/dev/null || {
        echo "tag-major.sh: could not create ref tags/$MAJOR" >&2
        exit 1
    }
fi

readback_sha="$(gh api "repos/$REPO/git/ref/tags/$MAJOR" --jq '.object.sha')" || {
    echo "tag-major.sh: could not read back tags/$MAJOR after the move" >&2
    exit 1
}

if [ "$readback_sha" != "$newest_sha" ]; then
    echo "tag-major.sh: FAILED — read-back of tags/$MAJOR is $readback_sha, expected $newest_sha" >&2
    exit 1
fi

echo "tag-major.sh: confirmed — $MAJOR -> $readback_sha"
