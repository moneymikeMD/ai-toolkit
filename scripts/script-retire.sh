#!/bin/bash
#
# Turn a "retire?" flag from
# `script-analytics.py report --usage` into an actual retirement.
#
# Default mode is DRY-RUN: read the usage table, find every script whose
# flag is exactly "retire?", and print the plan — script path, its
# selftest, its docs/scripts.md row (if any), and the "Retired" line that
# would be added — without touching the working tree. Nothing is deleted,
# no branch is created, until --yes is passed.
#
# Scope: this script auto-handles the script file, its selftest, and its
# docs/scripts.md table row. Prose references in agents/, skills/, CLAUDE.md
# or other docs/ files are LISTED for manual follow-up, never auto-edited.
#
# Usage:
#   script-retire.sh --events FILE [--since ISO] [--until ISO] [--dry-run]
#   script-retire.sh --events FILE --yes --ticket NWM-nnn
#
# --dry-run (default): print the retirement plan for every "retire?" row,
#   exit 0 whether or not any candidates were found.
# --yes: actually retire every current "retire?" candidate. For each:
#   create branch retire-<slug> off the current branch, `git rm` the
#   script and its selftest, remove its docs/scripts.md row (if any),
#   append a line under docs/scripts.md's "## Retired" section, commit,
#   then hand off to land-branch.sh <branch> <ticket> to merge/lint/
#   complete/push. Requires --ticket. Refuses on a dirty working tree
#   (this only ever branches from a clean tree).
#
# A script whose report --usage flag is anything other than "retire?" never
# appears as a candidate; this script never acts on a name passed by hand.
#
# Exit codes: 0 = ran (dry-run always; --yes only if every candidate
# retired cleanly), 1 = bad usage or a candidate failed to retire.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/kit.sh
. "$HERE/lib/kit.sh"

case "${1:-}" in -h|--help) show_help ;; esac

# The repo to retire FROM is the caller's cwd, not where this script lives —
# a selftest fixture repo invokes it by path from outside itself.
REPO_ROOT="$(pwd)"

PYTHON="${PYTHON:-python3}"
SCRIPT_ANALYTICS="${SCRIPT_ANALYTICS_PY:-$HERE/script-analytics.py}"
SCRIPTS_MD="${SCRIPTS_MD:-$REPO_ROOT/docs/scripts.md}"
LAND_BRANCH="${LAND_BRANCH_SH:-$HERE/land-branch.sh}"

EVENTS=""
SINCE=""
UNTIL=""
DRY_RUN=1
TICKET=""

while [ $# -gt 0 ]; do
    case "$1" in
        --events) [ $# -ge 2 ] || die "--events needs a path"; EVENTS="$2"; shift 2 ;;
        --since) [ $# -ge 2 ] || die "--since needs a date"; SINCE="$2"; shift 2 ;;
        --until) [ $# -ge 2 ] || die "--until needs a date"; UNTIL="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes) DRY_RUN=0; shift ;;
        --ticket) [ $# -ge 2 ] || die "--ticket needs an id"; TICKET="$2"; shift 2 ;;
        -h|--help) show_help ;;
        *) die "unknown argument: $1 (--help for usage)" ;;
    esac
done

[ -n "$EVENTS" ] || die "--events FILE is required"
[ -f "$EVENTS" ] || die "events file not found: $EVENTS"
[ -f "$SCRIPT_ANALYTICS" ] || die "cannot find script-analytics.py at $SCRIPT_ANALYTICS"
need "$PYTHON" git

if [ "$DRY_RUN" -eq 0 ]; then
    [ -n "$TICKET" ] || die "--yes requires --ticket NWM-nnn (land-branch.sh needs it)"
    [ -f "$LAND_BRANCH" ] || die "cannot find land-branch.sh at $LAND_BRANCH"
    cd "$REPO_ROOT"
    [ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or set aside before --yes (this script only ever branches from a clean tree)"
fi

usage_args=(report --events "$EVENTS" --usage --format tsv)
[ -n "$SINCE" ] && usage_args+=(--since "$SINCE")
[ -n "$UNTIL" ] && usage_args+=(--until "$UNTIL")

USAGE_TSV="$("$PYTHON" "$SCRIPT_ANALYTICS" "${usage_args[@]}")"

# Column 1 = script, last column = flag. Only the per-script table's rows
# have >=14 columns, so the footer/owner_wait sections never match.
CANDIDATES="$(printf '%s\n' "$USAGE_TSV" | awk -F'\t' 'NR>1 && NF>=14 && $NF=="retire?" {print $1}')"

if [ -z "$CANDIDATES" ]; then
    echo "script-retire: no retire? candidates in the queried window."
    exit 0
fi

RETIRE_FAILED=0

while IFS= read -r script; do
    [ -n "$script" ] || continue
    slug="$(basename "$script" | sed 's/\.[a-zA-Z0-9]*$//')"
    branch="retire-$slug"

    echo "=== $script (flag: retire?) ==="

    if [ ! -f "$REPO_ROOT/$script" ]; then
        echo "  SKIP: $script no longer exists in the working tree (already retired, or a fixture-only entry)."
        continue
    fi

    selftest=""
    dir="$(dirname "$script")"
    base="$(basename "$script")"
    case "$base" in
        *-selftest.sh) : ;; # a selftest can't itself be a retirement candidate's "own" selftest
        *.sh) cand="$dir/${base%.sh}-selftest.sh"; [ -f "$REPO_ROOT/$cand" ] && selftest="$cand" ;;
        *.py) cand="$dir/${base%.py}-selftest.sh"; [ -f "$REPO_ROOT/$cand" ] && selftest="$cand" ;;
    esac

    doc_rows=""
    if [ -f "$SCRIPTS_MD" ]; then
        doc_rows="$(grep -n -F "$base" "$SCRIPTS_MD" 2>/dev/null | grep -v '^[0-9]*:## Retired' || true)"
    fi

    other_refs="$(grep -rl -F "$base" \
        "$REPO_ROOT/agents" "$REPO_ROOT/skills" "$REPO_ROOT/CLAUDE.md" "$REPO_ROOT/docs" \
        2>/dev/null | grep -v -F "$SCRIPTS_MD" || true)"

    today="$(date -u +%Y-%m-%d)"
    # Pull the purpose column (field 3 of a "|"-split row) when the row is
    # table-shaped; some entries are prose, so fall back to the raw line.
    purpose_raw="$(printf '%s\n' "$doc_rows" | head -1 | sed 's/^[0-9]*://')"
    if printf '%s' "$purpose_raw" | grep -q '|.*|.*|'; then
        purpose="$(printf '%s' "$purpose_raw" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')"
    else
        purpose="$purpose_raw"
    fi

    echo "  would delete:  $script"
    [ -n "$selftest" ] && echo "  would delete:  $selftest"
    if [ -n "$doc_rows" ]; then
        printf '%s\n' "$doc_rows" | sed 's/^/  scripts.md row removed (line /; s/$/)/'
    else
        echo "  scripts.md row: none found (or docs/scripts.md keeps no table here — nothing to remove)"
    fi
    echo "  scripts.md Retired line added: - \`$base\` — retired $today. ${purpose:-<purpose unknown, fill in manually>}. Reason: usage/adoption rule, report --usage flagged retire?."
    if [ -n "$other_refs" ]; then
        echo "  other references needing manual review (not auto-edited):"
        printf '%s\n' "$other_refs" | sed 's/^/    /'
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  (dry-run: no branch created, nothing written)"
        continue
    fi

    if ! git checkout -b "$branch" >/dev/null 2>&1; then
        echo "  FAILED: could not create branch $branch (may already exist)" >&2
        RETIRE_FAILED=1
        continue
    fi

    git rm -q "$script"
    [ -n "$selftest" ] && git rm -q "$selftest"

    if [ -n "$doc_rows" ]; then
        line_nums="$(printf '%s\n' "$doc_rows" | cut -d: -f1 | sort -rn)"
        for ln in $line_nums; do
            sed -i.bak "${ln}d" "$SCRIPTS_MD" && rm -f "$SCRIPTS_MD.bak"
        done
    fi
    # "## Retired" is always docs/scripts.md's last section, so appending at
    # EOF lands inside it.
    mkdir -p "$(dirname "$SCRIPTS_MD")"
    if [ ! -f "$SCRIPTS_MD" ]; then
        printf '# scripts.md\n\nScripts retired under the usage/adoption rule. Not a\nreference — see the generated Scripts page for scripts still in use.\nEntries list name, date retired, one-line purpose, and reason.\n\n## Retired\n\n' > "$SCRIPTS_MD"
    fi
    # shellcheck disable=SC2016  # literal backticks around the script name, not command substitution
    printf -- '- `%s` — retired %s. %s. Reason: usage/adoption rule, report --usage flagged retire?.\n' \
        "$base" "$today" "${purpose:-<purpose unknown, fill in manually>}" >> "$SCRIPTS_MD"

    git add "$SCRIPTS_MD"
    git commit -q -m "$(printf 'chore(%s): retire %s\n\nfewer than 5 non-test invocations within 15 days of landing (report --usage flag: retire?).\n' "$TICKET" "$base")"

    echo "  retired on branch $branch; landing..."
    if ! "$LAND_BRANCH" "$branch" "$TICKET"; then
        echo "  FAILED: land-branch.sh did not complete for $branch" >&2
        RETIRE_FAILED=1
    fi
done <<EOF
$CANDIDATES
EOF

exit "$RETIRE_FAILED"
