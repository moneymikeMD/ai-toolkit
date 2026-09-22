#!/bin/bash
#
# Assertions for script-retire.sh.
# Builds a scratch fixture tree in $(mktemp -d) — never this repo —
# containing:
#   - a synthetic "landed" script, its selftest, and a docs/scripts.md
#     with one table row naming it plus the "## Retired" section header
#   - a hand-written events JSONL with one `author` event (landing date
#     far enough in the past) and two `invoke` events, both real callers,
#     both inside the first 15 days after landing — 2 < 5, so
#     script-analytics.py's own usage_flag() reads this as "retire?"
#     independently of anything in script-retire.sh itself (the ORACLE
#     here is script-analytics.py's real flag column, not a hand-rolled
#     guess — a self-check that shares code with the writer cannot fail).
#
# Verifies the verify block directly: a dry run against this fixture
# prints the branch diff (script + selftest + docs/scripts.md row
# removed, Retired line added) without landing anything — no branch is
# created, no file in the fixture tree is modified, no land-branch.sh
# call happens (LAND_BRANCH_SH is pointed at a stub that fails loudly if
# invoked). --yes mode is checked against a second, disposable fixture
# with a stub land-branch.sh that always succeeds. A script whose flag is
# "keep" is refused. Prose references in agents/skills/docs are LISTED,
# never edited.
#
# Never touches the real repo tree or a live host: SCRIPT_ANALYTICS_PY
# and SCRIPTS_MD env overrides point script-retire.sh entirely inside the
# scratch dir; a real `git` repo is `init`'d there with a pinned
# hooksPath/signing config, local to the fixture only.
#
# Usage: ./scripts/script-retire-selftest.sh
# Exit 0 if every real assertion passes, 1 otherwise.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/kit.sh
. "$HERE/lib/kit.sh"

case "${1:-}" in -h|--help) show_help ;; esac

RETIRE_SH="$HERE/script-retire.sh"
SCRIPT_ANALYTICS="$HERE/script-analytics.py"
[ -f "$RETIRE_SH" ] || die "cannot find script-retire.sh at $RETIRE_SH"
[ -f "$SCRIPT_ANALYTICS" ] || die "cannot find script-analytics.py at $SCRIPT_ANALYTICS"
need python3 git

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }
assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) pass "$desc" ;;
        *) fail "$desc (expected to find '$needle')"; printf '%s\n' "$haystack" | sed 's/^/    /' >&2 ;;
    esac
}
assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) fail "$desc (did not expect to find '$needle')"; printf '%s\n' "$haystack" | sed 's/^/    /' >&2 ;;
        *) pass "$desc" ;;
    esac
}


build_fixture() {
    local root="$1"
    mkdir -p "$root/repo/scripts" "$root/repo/docs" "$root/repo/agents" "$root/repo/skills"
    local repo="$root/repo"

    cat > "$repo/scripts/oneoff-widget.sh" <<'EOS'
#!/bin/bash
echo "oneoff-widget: does one thing, rarely"
EOS
    chmod +x "$repo/scripts/oneoff-widget.sh"

    cat > "$repo/scripts/oneoff-widget-selftest.sh" <<'EOS'
#!/bin/bash
echo "selftest ok"
EOS
    chmod +x "$repo/scripts/oneoff-widget-selftest.sh"

    cat > "$repo/docs/scripts.md" <<'EOS'
# scripts.md fixture

## dev/

| Script | Purpose |
| --- | --- |
| oneoff-widget.sh | prints a one-off widget message |

## Retired

Scripts deleted under the usage/adoption rules. Entries list name, date retired, one-line purpose, and reason.
EOS

    cat > "$repo/agents/nobody-cares.md" <<'EOS'
This agent never mentions oneoff-widget.sh.
EOS

    # own-tree isolation: pin hooksPath/signing so nothing inherited from
    # a real ~/.gitconfig leaks into this scratch repo.
    git init -q "$repo"
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" config commit.gpgsign false
    git -C "$repo" config user.email "fixture@example.invalid"
    git -C "$repo" config user.name "fixture"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "fixture baseline"

    printf '%s\n' "$repo"
}

write_events() {
    local path="$1"
    cat > "$path" <<'EOS'
{"ts": "2026-08-01T00:00:00Z", "script": "scripts/oneoff-widget.sh", "scripts": ["scripts/oneoff-widget.sh"], "event": "author", "cause": "-", "outcome": "-", "round": 1, "session": "auth-sess", "agent_id": "a1", "agent_type": "script-author", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "NWM-200", "source": "transcript", "key": "widget-author", "note": "-"}
{"ts": "2026-08-03T00:00:00Z", "script": "scripts/oneoff-widget.sh", "scripts": ["scripts/oneoff-widget.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "real-sess-1", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "widget-invoke-1", "note": "-"}
{"ts": "2026-08-05T00:00:00Z", "script": "scripts/oneoff-widget.sh", "scripts": ["scripts/oneoff-widget.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "real-sess-2", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "widget-invoke-2", "note": "-"}
EOS
}

ROOT=$(mktemp -d) || die "mktemp -d failed"
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

REPO="$(build_fixture "$ROOT/dry")"
EVENTS="$ROOT/events.jsonl"
write_events "$EVENTS"

# Confirm the oracle independently: script-analytics.py's own flag column
# must read "retire?" for this fixture BEFORE we trust script-retire.sh's
# dry-run output about it.
ORACLE_TSV="$(python3 "$SCRIPT_ANALYTICS" report --events "$EVENTS" --usage --until 2026-08-20 --format tsv)"
assert_contains "oracle: script-analytics.py itself flags oneoff-widget.sh as retire? (elapsed 19d >=15, 2 invokes <5)" \
    "$ORACLE_TSV" "$(printf 'scripts/oneoff-widget.sh\t2\t2\t2\t0')"
assert_contains "oracle: flag column ends in retire?" "$ORACLE_TSV" "retire?"


LAND_STUB="$ROOT/land-branch-stub-fail.sh"
cat > "$LAND_STUB" <<'EOS'
#!/bin/bash
echo "land-branch.sh should NEVER be invoked by a dry-run" >&2
exit 99
EOS
chmod +x "$LAND_STUB"

DRY_OUT="$(cd "$REPO" && SCRIPT_ANALYTICS_PY="$SCRIPT_ANALYTICS" SCRIPTS_MD="$REPO/docs/scripts.md" LAND_BRANCH_SH="$LAND_STUB" \
    "$RETIRE_SH" --events "$EVENTS" --until 2026-08-20 --dry-run)"

assert_contains "dry-run header names the candidate" "$DRY_OUT" "=== scripts/oneoff-widget.sh (flag: retire?) ==="
assert_contains "dry-run: would delete the script" "$DRY_OUT" "would delete:  scripts/oneoff-widget.sh"
assert_contains "dry-run: would delete its selftest" "$DRY_OUT" "would delete:  scripts/oneoff-widget-selftest.sh"
assert_contains "dry-run: scripts.md row identified for removal" "$DRY_OUT" "scripts.md row removed"
assert_contains "dry-run: scripts.md row content is the actual table row" "$DRY_OUT" "oneoff-widget.sh"
assert_contains "dry-run: prints the Retired line that would be added" "$DRY_OUT" "scripts.md Retired line added: - \`oneoff-widget.sh\`"
assert_contains "dry-run: names no-landing explicitly" "$DRY_OUT" "(dry-run: no branch created, nothing written)"
assert_contains "dry-run: other prose reference is listed, not edited" "$DRY_OUT" "nobody-cares.md"

assert_not_contains "dry-run: no branch was actually created" "$(git -C "$REPO" branch --list 'retire-*')" "retire-"
assert_not_contains "dry-run: current branch is unchanged (still on the initial branch)" \
    "$(git -C "$REPO" status --porcelain)" "D"
assert_contains "dry-run: script file still on disk (nothing deleted)" \
    "$( [ -f "$REPO/scripts/oneoff-widget.sh" ] && echo present || echo missing )" "present"
assert_contains "dry-run: docs/scripts.md unchanged on disk" \
    "$(cat "$REPO/docs/scripts.md")" "| oneoff-widget.sh | prints a one-off widget message |"
assert_not_contains "dry-run: docs/scripts.md has no new Retired entry yet" \
    "$(cat "$REPO/docs/scripts.md")" "retired 2026-08"
assert_contains "dry-run: nobody-cares.md content is untouched" \
    "$(cat "$REPO/agents/nobody-cares.md")" "never mentions oneoff-widget.sh"


EMPTY_EVENTS="$ROOT/empty-events.jsonl"
: > "$EMPTY_EVENTS"
NONE_OUT="$(cd "$REPO" && SCRIPT_ANALYTICS_PY="$SCRIPT_ANALYTICS" SCRIPTS_MD="$REPO/docs/scripts.md" LAND_BRANCH_SH="$LAND_STUB" \
    "$RETIRE_SH" --events "$EMPTY_EVENTS" --dry-run)"
assert_contains "no events -> no candidates, reported plainly" "$NONE_OUT" "no retire? candidates"


KEEP_ROOT="$ROOT/keep"
KEEP_REPO="$(build_fixture "$KEEP_ROOT")"
KEEP_EVENTS="$ROOT/keep-events.jsonl"
{
    printf '{"ts": "2026-08-01T00:00:00Z", "script": "scripts/oneoff-widget.sh", "scripts": ["scripts/oneoff-widget.sh"], "event": "author", "cause": "-", "outcome": "-", "round": 1, "session": "auth-sess", "agent_id": "a1", "agent_type": "script-author", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "NWM-200", "source": "transcript", "key": "widget-author", "note": "-"}\n'
    for i in $(seq 1 10); do
        printf '{"ts": "2026-08-0%dT00:00:00Z", "script": "scripts/oneoff-widget.sh", "scripts": ["scripts/oneoff-widget.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "real-sess-%d", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "widget-invoke-%d", "note": "-"}\n' \
            "$(( (i % 9) + 1 ))" "$i" "$i"
    done
} > "$KEEP_EVENTS"
KEEP_TSV="$(python3 "$SCRIPT_ANALYTICS" report --events "$KEEP_EVENTS" --usage --until 2026-08-20 --format tsv)"
assert_contains "oracle: 10+ lifetime invocations flags keep" "$KEEP_TSV" $'\tkeep'
KEEP_OUT="$(cd "$KEEP_REPO" && SCRIPT_ANALYTICS_PY="$SCRIPT_ANALYTICS" SCRIPTS_MD="$KEEP_REPO/docs/scripts.md" LAND_BRANCH_SH="$LAND_STUB" \
    "$RETIRE_SH" --events "$KEEP_EVENTS" --until 2026-08-20 --dry-run)"
assert_contains "a 'keep'-flagged script is never listed as a candidate" "$KEEP_OUT" "no retire? candidates"
assert_not_contains "a 'keep'-flagged script's file is never named as a candidate header" "$KEEP_OUT" "oneoff-widget.sh (flag: retire?)"


YES_ROOT="$ROOT/yes"
YES_REPO="$(build_fixture "$YES_ROOT")"
YES_EVENTS="$ROOT/yes-events.jsonl"
write_events "$YES_EVENTS"

LAND_OK_STUB="$ROOT/land-branch-stub-ok.sh"
LAND_OK_LOG="$ROOT/land-branch-ok.log"
cat > "$LAND_OK_STUB" <<EOS
#!/bin/bash
echo "\$1 \$2" >> "$LAND_OK_LOG"
exit 0
EOS
chmod +x "$LAND_OK_STUB"

YES_OUT="$(cd "$YES_REPO" && SCRIPT_ANALYTICS_PY="$SCRIPT_ANALYTICS" SCRIPTS_MD="$YES_REPO/docs/scripts.md" LAND_BRANCH_SH="$LAND_OK_STUB" \
    "$RETIRE_SH" --events "$YES_EVENTS" --until 2026-08-20 --yes --ticket NWM-65)"

assert_contains "--yes: reports the branch was created and landed" "$YES_OUT" "retired on branch retire-oneoff-widget; landing..."
assert_contains "--yes: hands off to land-branch.sh with branch and ticket" "$(cat "$LAND_OK_LOG")" "retire-oneoff-widget NWM-65"
assert_not_contains "--yes: script file deleted from the working tree" \
    "$( [ -f "$YES_REPO/scripts/oneoff-widget.sh" ] && echo present || echo missing )" "present"
assert_not_contains "--yes: selftest deleted from the working tree" \
    "$( [ -f "$YES_REPO/scripts/oneoff-widget-selftest.sh" ] && echo present || echo missing )" "present"
assert_not_contains "--yes: docs/scripts.md table row removed" \
    "$(cat "$YES_REPO/docs/scripts.md")" "| oneoff-widget.sh | prints a one-off widget message |"
assert_contains "--yes: docs/scripts.md gained a Retired entry" \
    "$(cat "$YES_REPO/docs/scripts.md")" "retired $(date -u +%Y-%m-%d)"
assert_contains "--yes: commit landed on the retire-<name> branch" \
    "$(git -C "$YES_REPO" log -1 --format=%s "retire-oneoff-widget")" "retire oneoff-widget.sh"


YES_NOTICKET_ROOT="$ROOT/yes-noticket"
YES_NOTICKET_REPO="$(build_fixture "$YES_NOTICKET_ROOT")"
NOTICKET_RC=0
(cd "$YES_NOTICKET_REPO" && SCRIPT_ANALYTICS_PY="$SCRIPT_ANALYTICS" SCRIPTS_MD="$YES_NOTICKET_REPO/docs/scripts.md" LAND_BRANCH_SH="$LAND_STUB" \
    "$RETIRE_SH" --events "$EVENTS" --until 2026-08-20 --yes) >/dev/null 2>&1 || NOTICKET_RC=$?
if [ "$NOTICKET_RC" -ne 0 ]; then
    pass "--yes without --ticket refuses"
else
    fail "--yes without --ticket should have refused"
fi


echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
