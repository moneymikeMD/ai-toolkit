#!/bin/bash
#
# Selftest for decisions.sh. Builds a scratch git repo per test case, with
# config LOCAL to that repo only, never the operator's global ~/.gitconfig.
#
# Usage: scripts/decisions-selftest.sh [path-to-decisions.sh]
# Defaults to the sibling scripts/decisions.sh. Fixtures live under
# scripts/fixtures/decisions/.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DECISIONS="${1:-$HERE/decisions.sh}"
KIT="$HERE/lib/kit.sh"
FIX="$HERE/fixtures/decisions"
[ -r "$DECISIONS" ] || { echo "cannot read $DECISIONS" >&2; exit 2; }
[ -r "$KIT" ] || { echo "cannot read $KIT" >&2; exit 2; }
[ -d "$FIX" ] || { echo "cannot read $FIX" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

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
        git config user.name "decisions selftest"
        git config user.signingkey ""
        cp "$DECISIONS" scripts/decisions.sh
        cp "$KIT" scripts/lib/kit.sh
        chmod +x scripts/decisions.sh
        git add -A
        git commit -q -m "init" --allow-empty
    ) >/dev/null
    printf '%s\n' "$d"
}

# run_in DIR ARGS... — run decisions.sh with cwd DIR; sets RC, OUT (stdout+stderr).
run_in() {
    local dir="$1"; shift
    set +e
    OUT=$(cd "$dir" && "$DECISIONS" "$@" 2>&1)
    RC=$?
    set -e
}

# run ARGS... — run from a neutral cwd so only --root decides the target.
run() {
    set +e
    OUT=$(cd "$WORK" && "$DECISIONS" "$@" 2>&1)
    RC=$?
    set -e
}

count_records() { find "$1/docs/decisions.d" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' '; }

# ---- 1: add writes exactly one record with the contract frontmatter.
R=$(fresh_repo t1)
run add --root "$R" --title "Use one file per decision" --decision "D" --why "W" --cost "C"
TODAY=$(date +%F)
F="$R/docs/decisions.d/$TODAY-use-one-file-per-decision.md"
if [ "$RC" = 0 ] && [ "$(count_records "$R")" = 1 ] && [ -f "$F" ] \
    && grep -q "^date: $TODAY\$" "$F" && grep -q '^slug: use-one-file-per-decision$' "$F" \
    && grep -q '^title: "Use one file per decision"$' "$F" && ! grep -q '^seq' "$F"; then
    ok "add writes one dated record with date/slug/title frontmatter"
else bad "add happy path: rc=$RC out=$OUT"; fi

# ---- 2: add never creates docs/decisions.md or any index.
if [ ! -e "$R/docs/decisions.md" ] && [ "$(ls "$R/docs")" = "decisions.d" ]; then
    ok "add creates no docs/decisions.md and no index"
else bad "add left something besides decisions.d under docs/"; fi

# ---- 3: lint passes on that record.
run lint --root "$R"
if [ "$RC" = 0 ]; then ok "lint passes a freshly added record"; else bad "lint on fresh record: $OUT"; fi

# ---- 4: each missing or blank required field refuses and writes nothing.
for missing in title decision why cost; do
    R=$(fresh_repo "t4-$missing")
    args=(--title T --decision D --why W --cost C)
    new=()
    skip=0
    for a in "${args[@]}"; do
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        if [ "$a" = "--$missing" ]; then skip=1; continue; fi
        new+=("$a")
    done
    run add --root "$R" ${new[@]+"${new[@]}"}
    if [ "$RC" != 0 ] && [ "$(count_records "$R")" = 0 ] && printf '%s' "$OUT" | grep -q -- "--$missing"; then
        ok "add without --$missing refuses, names it, writes nothing"
    else bad "add without --$missing: rc=$RC out=$OUT"; fi
    run add --root "$R" --title T --decision D --why W --cost C --"$missing" "   "
    if [ "$RC" != 0 ] && [ "$(count_records "$R")" = 0 ]; then
        ok "add with blank --$missing refuses, writes nothing"
    else bad "add with blank --$missing: rc=$RC out=$OUT"; fi
done

# ---- 5: an existing slug is refused, even under another date.
R=$(fresh_repo t5)
run add --root "$R" --title "Same Slug" --decision D --why W --cost C
mkdir -p "$R/docs/decisions.d"
run add --root "$R" --title "same   slug!" --decision D2 --why W2 --cost C2
if [ "$RC" != 0 ] && [ "$(count_records "$R")" = 1 ] && printf '%s' "$OUT" | grep -q 'slug already exists'; then
    ok "add refuses an existing slug"
else bad "duplicate slug: rc=$RC out=$OUT"; fi
mv "$R/docs/decisions.d/$TODAY-same-slug.md" "$R/docs/decisions.d/2020-01-01-same-slug.md"
run add --root "$R" --title "Same Slug" --decision D --why W --cost C
if [ "$RC" != 0 ] && [ "$(count_records "$R")" = 1 ]; then
    ok "add refuses an existing slug filed under an older date"
else bad "duplicate slug other date: rc=$RC out=$OUT"; fi

# ---- 6: multi-line body, quotes and backslashes survive; a newline title is refused.
R=$(fresh_repo t6)
run add --root "$R" --title 'Quote "q" and \ slash' --decision $'line1\nline2' --why 'W' --cost 'C'
F=$(find "$R/docs/decisions.d" -name '*.md')
run lint --root "$R"
if [ "$RC" = 0 ] && grep -q '^line2$' "$F" && grep -q '^title: "Quote \\"q\\" and \\\\ slash"$' "$F"; then
    ok "add escapes the title and keeps multi-line fields; lint accepts the result"
else bad "escaping: rc=$RC out=$OUT"; fi
run add --root "$R" --title $'two\nlines' --decision D --why W --cost C
if [ "$RC" != 0 ]; then ok "add refuses a multi-line title"; else bad "multi-line title accepted"; fi

# ---- 7: --supersedes writes the field; a dangling path is refused; lint checks it.
R=$(fresh_repo t7)
run add --root "$R" --title "First" --decision D --why W --cost C
FIRST="docs/decisions.d/$TODAY-first.md"
run add --root "$R" --title "Second" --decision D --why W --cost C --supersedes "$FIRST"
if [ "$RC" = 0 ] && grep -q "^supersedes: $FIRST\$" "$R/docs/decisions.d/$TODAY-second.md"; then
    ok "add --supersedes records the path"
else bad "supersedes: rc=$RC out=$OUT"; fi
run add --root "$R" --title "Third" --decision D --why W --cost C --supersedes docs/decisions.d/nope.md
if [ "$RC" != 0 ] && [ ! -e "$R/docs/decisions.d/$TODAY-third.md" ]; then
    ok "add refuses a --supersedes that does not resolve"
else bad "dangling supersedes accepted: $OUT"; fi
rm "$R/docs/decisions.d/$TODAY-first.md"
run lint --root "$R"
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'supersedes does not resolve'; then
    ok "lint fails a supersedes path that no longer resolves"
else bad "lint dangling supersedes: rc=$RC out=$OUT"; fi

# ---- 8: lint fails when docs/decisions.md exists, naming it.
R=$(fresh_repo t8)
run add --root "$R" --title T --decision D --why W --cost C
touch "$R/docs/decisions.md"
run lint --root "$R"
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'docs/decisions.md'; then
    ok "lint exits 1 naming docs/decisions.md when it exists"
else bad "lint with decisions.md: rc=$RC out=$OUT"; fi

# ---- 9: lint passes a repo with no docs/decisions.d at all (and no decisions.md).
R=$(fresh_repo t9)
run lint --root "$R"
if [ "$RC" = 0 ]; then ok "lint passes a repo with no decisions.d"; else bad "lint empty repo: $OUT"; fi

# ---- 10: fixtures. good/ passes; each bad-* fails with its own message.
good_repo() {
    local name="$1" fixture="$2" r
    r=$(fresh_repo "$name")
    mkdir -p "$r/docs"
    cp -R "$FIX/$fixture/." "$r/"
    printf '%s\n' "$r"
}
R=$(good_repo f-good good)
run lint --root "$R"
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'ok: 2 decision record'; then
    ok "fixture good: lint passes, counts 2 records, 0000-00-00 and migrated unrecorded accepted"
else bad "fixture good: rc=$RC out=$OUT"; fi

expect_bad() {
    local fixture="$1" needle="$2" r
    r=$(good_repo "f-$fixture" "$fixture")
    run lint --root "$r"
    if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q -- "$needle"; then
        ok "fixture $fixture: lint exits 1 naming '$needle'"
    else bad "fixture $fixture: rc=$RC out=$OUT"; fi
}
expect_bad bad-date 'date is not YYYY-MM-DD'
expect_bad bad-unrecorded "'unrecorded' but frontmatter lacks migrated"
expect_bad bad-filename 'filename does not match'
expect_bad bad-missing-section "section '## Cost' missing"
expect_bad bad-frontmatter 'no parseable frontmatter'
expect_bad bad-link 'link does not resolve'

# ---- 11: link check ignores code fences, URLs and links outside decisions.d.
R=$(fresh_repo t11)
run add --root "$R" --title T --decision D --why W --cost C
cat > "$R/README.md" <<'EOF'
```
[fenced](docs/decisions.d/ghost.md)
```

[web](https://example.com/docs/decisions.d/ghost.md) and [other](docs/elsewhere.md) and [anchor](#top).
EOF
run lint --root "$R"
if [ "$RC" = 0 ]; then ok "lint ignores fenced links, URLs and links outside decisions.d"; else bad "link scope: $OUT"; fi

# ---- 12: a link with an anchor resolves on the file part.
R=$(fresh_repo t12)
run add --root "$R" --title Anchored --decision D --why W --cost C
mkdir -p "$R/docs/sub"
printf '[a](../decisions.d/%s-anchored.md#why)\n' "$TODAY" > "$R/docs/sub/x.md"
run lint --root "$R"
if [ "$RC" = 0 ]; then ok "lint resolves a relative link with an anchor"; else bad "anchored link: $OUT"; fi

# ---- 13: list prints date, slug, title oldest first.
R=$(fresh_repo t13)
mkdir -p "$R/docs/decisions.d"
cp "$FIX/good/docs/decisions.d/"*.md "$R/docs/decisions.d/"
run list --root "$R"
FIRST_LINE=$(printf '%s\n' "$OUT" | head -n 1)
if [ "$RC" = 0 ] && [ "$FIRST_LINE" = "$(printf '0000-00-00\tlegacy-entry\tLegacy entry with no recorded rationale')" ] \
    && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 2 ]; then
    ok "list prints date, slug and title tab-separated, oldest first"
else bad "list: rc=$RC out=$OUT"; fi

# ---- 14: --root contract, same as known-issue.sh.
R=$(fresh_repo t14)
OTHER=$(fresh_repo t14-other)
run_in "$OTHER" add --root "$R" --title Rooted --decision D --why W --cost C
if [ "$RC" = 0 ] && [ "$(count_records "$R")" = 1 ] && [ "$(count_records "$OTHER")" = 0 ]; then
    ok "--root beats cwd: the record lands in --root, not the cwd repo"
else bad "--root vs cwd: rc=$RC out=$OUT"; fi
run_in "$OTHER" add --title Cwd --decision D --why W --cost C
if [ "$RC" = 0 ] && [ "$(count_records "$OTHER")" = 1 ]; then
    ok "no --root: cwd repo is the default"
else bad "cwd default: rc=$RC out=$OUT"; fi
run add --root "" --title X --decision D --why W --cost C
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'PATH is empty'; then
    ok "set-but-empty --root fails loudly"
else bad "empty --root: rc=$RC out=$OUT"; fi
run_in "$OTHER" add --root= --title X --decision D --why W --cost C
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'PATH is empty'; then
    ok "--root= (empty) fails loudly and does not fall back to cwd"
else bad "--root= : rc=$RC out=$OUT"; fi
mkdir -p "$WORK/notgit"
run lint --root "$WORK/notgit"
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'not a git repository'; then
    ok "non-git --root fails loudly"
else bad "non-git --root: rc=$RC out=$OUT"; fi
run lint --root "$WORK/does-not-exist"
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'no such directory'; then
    ok "missing --root directory fails loudly"
else bad "missing --root: rc=$RC out=$OUT"; fi
R=$(fresh_repo t14b)
run add --title "--root" --decision D --why W --cost C --root "$R"
if [ "$RC" = 0 ] && [ "$(count_records "$R")" = 1 ]; then
    ok "an argument in a value slot is never read as --root"
else bad "--root as a value: rc=$RC out=$OUT"; fi

# ---- 15: help, usage errors.
run --help
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'decisions.sh add --title'; then ok "--help prints usage and exits 0"; else bad "--help: rc=$RC"; fi
run add --help
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'decisions.sh add --title'; then ok "add --help prints usage and exits 0"; else bad "add --help: rc=$RC"; fi
run bogus
if [ "$RC" != 0 ]; then ok "unknown subcommand fails"; else bad "unknown subcommand accepted"; fi

# ---- 16: bash 3.2 guard. No bash 3.2 on Linux CI, so check the construct that broke it:
# a heredoc opened inside $( ) whose body holds a backtick (NWM-202 follow-up).
bash32_hazard() {
    awk '
        /\$\([^)]*<</ { match($0, /<<-?[ \t]*[\x27"]?[A-Za-z_]+/); tag = substr($0, RSTART, RLENGTH)
                         gsub(/<<-?[ \t]*[\x27"]?/, "", tag); inhd = 1; next }
        inhd && $0 == tag { inhd = 0; next }
        inhd && /`/ { print FILENAME ":" NR; bad = 1 }
        END { exit bad ? 0 : 1 }
    ' "$1"
}
printf 'X=$(cat <<\x27EOF\x27\nre = "`{3,}"\nEOF\n)\n' > "$WORK/hazard.sh"
printf 'X=$(cat <<\x27EOF\x27\nplain\nEOF\n)\n' > "$WORK/fine.sh"
if bash32_hazard "$WORK/hazard.sh" >/dev/null && ! bash32_hazard "$WORK/fine.sh" >/dev/null; then
    ok "bash32 guard flags a backtick in a heredoc inside \$( ) and passes a plain one"
else bad "bash32 guard self-check"; fi
if bash32_hazard "$DECISIONS" >/dev/null; then bad "decisions.sh has a backtick heredoc inside \$( ): bash 3.2 cannot parse it"
else ok "decisions.sh has no backtick heredoc inside a command substitution"; fi
if grep -nE '\$\([^)]*<<' "$DECISIONS" >/dev/null; then bad "decisions.sh opens a heredoc inside \$( )"
else ok "decisions.sh opens no heredoc inside a command substitution"; fi

echo "---"
echo "passed: $PASS failed: $FAIL"
[ "$FAIL" = 0 ]
