#!/bin/bash
#
# Selftest for known-issue.sh. Builds a scratch git repo per test case, with
# config LOCAL to that repo only, never the operator's global ~/.gitconfig.
#
# Usage: scripts/known-issue-selftest.sh [path-to-known-issue.sh]
# Defaults to the sibling scripts/known-issue.sh. Pass an older revision's
# path to reproduce the RED failures below against pre-fix code.
#
# `migrate` is NOT covered here, and this is a gap rather than a decision.
# known-issue.sh ships the subcommand; its heading-detection was tested only
# by homelab's separate 337-line selftest, retired under LAB-228. Nothing in
# this file exercises it.
#
# Whoever rebuilds that coverage: assert the exact `entries written: N` count,
# not a zero exit. Per LAB-123 the failure printed "Migration OK" alongside a
# plausible, silently-wrong count, because the two scanners cross-checking
# each other shared one blind spot. Agreement between them was not
# independence, and an exit code could not see the difference. Only the
# number could.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KNOWN_ISSUE="${1:-$HERE/known-issue.sh}"
KIT="$HERE/lib/kit.sh"
[ -r "$KNOWN_ISSUE" ] || { echo "cannot read $KNOWN_ISSUE" >&2; exit 2; }
[ -r "$KIT" ] || { echo "cannot read $KIT" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# fresh_repo NAME — a throwaway git repo under $WORK/NAME with local-only
# config, this script installed at scripts/known-issue.sh. Prints the path.
fresh_repo() {
    local d="$WORK/$1"
    rm -rf "$d"
    mkdir -p "$d/scripts/lib"
    (
        cd "$d"
        git init -q -b main
        git config commit.gpgsign false
        git config gpg.format openpgp
        git config core.hooksPath /dev/null
        git config user.email "test@example.invalid"
        git config user.name "known-issue selftest"
        git config user.signingkey ""
        cp "$KNOWN_ISSUE" scripts/known-issue.sh
        cp "$KIT" scripts/lib/kit.sh
        chmod +x scripts/known-issue.sh
        git add -A
        git commit -q -m "init" --allow-empty
    ) >/dev/null
    printf '%s\n' "$d"
}

# ---- test 1: a newline in --title must not corrupt the corpus for later
# calls. The SECOND add is the assertion: it re-parses every entry from disk.

REPO=$(fresh_repo t1)
set +e
(cd "$REPO" && printf 'first line of body\n' | ./scripts/known-issue.sh add \
    --title "$(printf 'Line one\nLine two')" --severity LOW) >"$WORK/t1a.out" 2>&1
RC1=$?
(cd "$REPO" && printf 'second entry body\n' | ./scripts/known-issue.sh add \
    --title "Second entry, unrelated" --severity MEDIUM) >"$WORK/t1b.out" 2>&1
RC2=$?
set -e
if [ "$RC1" -ne 0 ]; then
    bad "test1a (newline in title): first add exited $RC1:
$(cat "$WORK/t1a.out")"
elif [ "$RC2" -ne 0 ]; then
    bad "test1b (newline in title corrupts the corpus): a SECOND, unrelated add failed ($RC2) because the first entry's frontmatter was split across two lines:
$(cat "$WORK/t1b.out")"
else
    set +e
    (cd "$REPO" && ./scripts/known-issue.sh lint) >"$WORK/t1c.out" 2>&1
    RC3=$?
    set -e
    if [ "$RC3" -ne 0 ]; then
        bad "test1c: lint failed after two adds, one with a newline in --title:
$(cat "$WORK/t1c.out")"
    else
        ok "test1: a newline in --title does not corrupt the corpus for later add/lint calls"
    fi
fi

# ---- test 2: a '|' in --title must be escaped in the generated index, not
# left to break the markdown table it renders into.

REPO=$(fresh_repo t2)
set +e
(cd "$REPO" && printf 'body\n' | ./scripts/known-issue.sh add \
    --title "Foo | Bar" --severity LOW) >"$WORK/t2.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test2 (pipe in title): add exited $RC:
$(cat "$WORK/t2.out")"
elif grep -qF 'Foo \| Bar' "$REPO/docs/known-issues.md"; then
    ok "test2: a '|' in --title is escaped ('Foo \\| Bar') in the generated index"
elif grep -qF 'Foo | Bar' "$REPO/docs/known-issues.md"; then
    bad "test2: index contains an UNESCAPED 'Foo | Bar' — this breaks the markdown table's column count from this row onward"
else
    bad "test2: neither the escaped nor the unescaped form was found in the index — inspect $REPO/docs/known-issues.md by hand"
fi

# ---- test 3: `lint`'s row-shape check is a REAL second oracle. Routing a
# corrupted index through the full CLI cannot show that, since a hand edit
# already trips the equality check — so call the function directly instead.

ENGINE_SRC=$(awk '/^cat > "\$ENGINE" <<.PYEOF./{flag=1;next}/^PYEOF$/{flag=0}flag' "$KNOWN_ISSUE")
ENGINE_FILE="$WORK/engine_extracted.py"
printf '%s\n' "$ENGINE_SRC" > "$ENGINE_FILE"
CHECK=$(python3 -c '
import sys, importlib.util
spec = importlib.util.spec_from_file_location("known_issue_engine", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)  # module name != "__main__", so main() does not run
fn = getattr(mod, "lint_index_row_shapes", None)
if fn is None:
    print("MISSING")
    sys.exit(0)
good = "| Severity | Finding |\n| --- | --- |\n| LOW | [Clean](path.md) |\n"
corrupted = "| Severity | Finding |\n| --- | --- |\n| LOW | [Foo | Bar](path.md) |\n"
g, b = fn(good), fn(corrupted)
print("OK" if (not g and b) else "WRONG good=%r corrupted=%r" % (g, b))
' "$ENGINE_FILE" 2>&1)
if [ "$CHECK" = "MISSING" ]; then
    bad "test3 (independent row-shape check): lint_index_row_shapes does not exist in $KNOWN_ISSUE — lint has no check independent of build_index"
elif [ "$CHECK" = "OK" ]; then
    ok "test3: lint_index_row_shapes passes a well-formed row and flags a corrupted one, independent of build_index"
else
    bad "test3: $CHECK"
fi

# ---- test 4: a slug that resolves outside $ENTRIES_DIR must be refused,
# not passed through to `resolve`/`severity` because a file happens to
# exist at that resolved path.

REPO=$(fresh_repo t4)
(cd "$REPO" && printf 'body\n' | ./scripts/known-issue.sh add \
    --title "Real entry" --severity LOW) >"$WORK/t4setup.out" 2>&1
DECOY="$REPO/elsewhere.md"
cat > "$DECOY" <<'EOF'
---
title: "Decoy file outside entries dir"
heading_raw: "Decoy file outside entries dir — LOW"
severity: LOW
status: open
qualifiers: []
tickets: []
slug: ../../elsewhere
---

This file must never be rewritten by a `resolve`/`severity` call.
EOF
DECOY_BEFORE=$(cat "$DECOY")
set +e
(cd "$REPO" && ./scripts/known-issue.sh resolve '../../elsewhere') >"$WORK/t4.out" 2>&1
RC=$?
set -e
DECOY_AFTER=$(cat "$DECOY")
if [ "$RC" -eq 0 ]; then
    bad "test4 (slug path traversal): resolve '../../elsewhere' exited 0 — should have been refused as a malformed slug"
elif [ "$DECOY_BEFORE" != "$DECOY_AFTER" ]; then
    bad "test4: $DECOY was modified even though the run was refused ($RC):
$(cat "$WORK/t4.out")"
else
    ok "test4: a slug resolving outside \$ENTRIES_DIR is refused before anything is touched"
fi

# ---- test 5: lint must catch an entry hand-edited after it was written —
# the sha256 in _manifest.json is the only record of what add/resolve/
# severity last wrote, and a hand-edit that bypasses all three (so
# record_written never runs) must not pass silently.

REPO=$(fresh_repo t5)
(cd "$REPO" && printf 'original body text\n' | ./scripts/known-issue.sh add \
    --title "Drift target" --severity LOW) >"$WORK/t5setup.out" 2>&1
SLUG=""
for f in "$REPO"/docs/known-issues/*.md; do
    SLUG="$(basename "$f" .md)"
done
set +e
(cd "$REPO" && ./scripts/known-issue.sh lint) >"$WORK/t5before.out" 2>&1
RC_BEFORE=$?
set -e
printf '\nhand-tampered line, never hashed\n' >> "$REPO/docs/known-issues/$SLUG.md"
set +e
(cd "$REPO" && ./scripts/known-issue.sh lint) >"$WORK/t5after.out" 2>&1
RC_AFTER=$?
set -e
if [ "$RC_BEFORE" -ne 0 ]; then
    bad "test5 (drift detection): lint failed on the untouched entry before any tampering ($RC_BEFORE):
$(cat "$WORK/t5before.out")"
elif [ "$RC_AFTER" -eq 0 ]; then
    bad "test5: lint exited 0 after a hand-edit to $SLUG.md — the sha256 check did not catch it"
elif ! grep -q "does not match its recorded sha256" "$WORK/t5after.out"; then
    bad "test5: lint failed after the hand-edit (rc=$RC_AFTER) but not for the checksum reason expected:
$(cat "$WORK/t5after.out")"
else
    ok "test5: lint refuses when an entry file was hand-edited after known-issue.sh last wrote it"
fi

# NWM-145. The script lives in ai-toolkit and every real invocation is from
# another repo, so "which repo does this write to" must not be decided by the
# caller's cwd. TOOLKIT stands in for the ai-toolkit checkout; CALLER is the
# repo cwd happens to be in; TARGET is the repo the operator means.
TOOLKIT=$(fresh_repo toolkit)
KI="$TOOLKIT/scripts/known-issue.sh"
CALLER=$(fresh_repo caller)
TARGET=$(fresh_repo target)

caller_untouched() {
    [ -z "$(git -C "$CALLER" status --porcelain)" ] \
        && [ ! -e "$CALLER/docs/known-issues" ] \
        && [ ! -e "$CALLER/docs/known-issues.md" ]
}

set +e
(cd "$CALLER" && "$KI" --root "$TARGET" add \
    --title "Root before verb" --severity LOW --body "b") >"$WORK/t6.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test6 (--root): the call failed ($RC):
$(cat "$WORK/t6.out")"
elif [ ! -f "$TARGET/docs/known-issues/root-before-verb.md" ]; then
    bad "test6: --root did not write the entry into the target repo"
elif ! caller_untouched; then
    bad "test6: the entry (or the index) also landed in the caller's cwd repo:
$(git -C "$CALLER" status --porcelain)"
else
    ok "test6: --root writes into the named repo and nothing into the caller's cwd repo"
fi

set +e
(cd "$CALLER" && "$KI" add \
    --title "Cwd default" --severity LOW --body "b") >"$WORK/t7.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test7 (cwd default): the call failed ($RC):
$(cat "$WORK/t7.out")"
elif [ ! -f "$CALLER/docs/known-issues/cwd-default.md" ]; then
    bad "test7: without --root the entry did not land in the cwd repo — the plugin case is broken"
else
    ok "test7: without --root the repo still comes from cwd, so the plugin case is unbroken"
fi
rm -rf "$CALLER/docs/known-issues" "$CALLER/docs/known-issues.md"
git -C "$CALLER" checkout -q -- . 2>/dev/null || true

set +e
(cd "$CALLER" && "$KI" add \
    --title "Root after verb" --severity HIGH --body "b" --root "$TARGET") >"$WORK/t8.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ] || [ ! -f "$TARGET/docs/known-issues/root-after-verb.md" ]; then
    bad "test8: --root after the subcommand's own options did not take ($RC):
$(cat "$WORK/t8.out")"
elif ! caller_untouched; then
    bad "test8: something landed in the caller's cwd repo"
else
    ok "test8: --root is recognised after the subcommand as well as before it"
fi

set +e
(cd "$CALLER" && "$KI" lint "--root=$TARGET") >"$WORK/t9.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test9: the --root=PATH form was not accepted ($RC):
$(cat "$WORK/t9.out")"
elif ! grep -q "^OK: 2 entries" "$WORK/t9.out"; then
    bad "test9: --root=PATH linted something other than the target's 2 entries:
$(cat "$WORK/t9.out")"
else
    ok "test9: the --root=PATH form names the same repo as --root PATH"
fi

mkdir -p "$WORK/notarepo"
set +e
(cd "$TARGET" && "$KI" --root "$WORK/notarepo" lint) >"$WORK/t10.out" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
    bad "test10: --root at a directory that is not a git repo exited 0"
elif ! grep -q "not a git repository: $WORK/notarepo" "$WORK/t10.out"; then
    bad "test10: it failed but did not name the directory:
$(cat "$WORK/t10.out")"
elif [ -e "$WORK/notarepo/docs" ]; then
    bad "test10: it wrote into the directory it rejected"
else
    ok "test10: --root at a non-git directory dies naming it, and writes nothing"
fi

set +e
(cd "$TARGET" && "$KI" --root "$WORK/no-such-dir" lint) >"$WORK/t11.out" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ] || ! grep -q "no such directory: $WORK/no-such-dir" "$WORK/t11.out"; then
    bad "test11: --root at a missing directory did not die naming it ($RC):
$(cat "$WORK/t11.out")"
else
    ok "test11: --root at a missing directory dies naming it"
fi

# The LAB-228 shape: a harness writing --root "$SOME_UNSET_VAR" must fail here
# rather than read as "no --root given" and silently fall back to cwd, which
# is the exact target this flag exists to take away from cwd.
set +e
(cd "$CALLER" && "$KI" --root "" add \
    --title "Empty root" --severity LOW --body "b") >"$WORK/t12.out" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
    bad "test12: an empty --root exited 0"
elif ! grep -q -- "--root: PATH is empty" "$WORK/t12.out"; then
    bad "test12: an empty --root failed but not for the empty reason:
$(cat "$WORK/t12.out")"
elif ! caller_untouched; then
    bad "test12: an empty --root fell back to cwd and wrote into the caller's repo"
else
    ok "test12: an empty --root dies rather than falling back to cwd"
fi

# An argument sitting in a value-taking option's slot is a value, never the
# global flag. If --root were lifted out here, --note would lose its argument;
# because it is not, the path after it is what `add` rejects.
set +e
(cd "$CALLER" && "$KI" add --title "Value slot" --severity LOW --body "b" \
    --note --root "$TARGET") >"$WORK/t13.out" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
    bad "test13: the malformed call exited 0"
elif ! grep -q "unknown option: $TARGET" "$WORK/t13.out"; then
    bad "test13: --root was lifted out of --note's value slot:
$(cat "$WORK/t13.out")"
else
    ok "test13: --root in a value-taking option's slot stays that option's value"
fi

mkdir -p "$TARGET/docs/deep/deeper"
set +e
(cd "$CALLER" && "$KI" --root "$TARGET/docs/deep/deeper" lint) >"$WORK/t14.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ] || ! grep -q "^OK: 2 entries" "$WORK/t14.out"; then
    bad "test14: --root at a subdirectory did not resolve to the repo toplevel ($RC):
$(cat "$WORK/t14.out")"
else
    ok "test14: --root at a subdirectory resolves to that repo's toplevel, as cwd does"
fi

set +e
(cd "$CALLER" && "$KI" lint --root) >"$WORK/t15.out" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ] || ! grep -q -- "--root needs a PATH" "$WORK/t15.out"; then
    bad "test15: a trailing --root with no PATH did not die naming the flag ($RC):
$(cat "$WORK/t15.out")"
else
    ok "test15: --root with no PATH dies rather than swallowing the next thing"
fi

echo
echo "$PASS passed, $FAIL failed (against: $KNOWN_ISSUE)"
[ "$FAIL" -eq 0 ]
