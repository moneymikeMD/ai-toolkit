#!/usr/bin/env bash
#
# Selftest for verify-run.sh. Structurally offline: every fixture is a
# ticket file and a git repo built in a temp directory, so no assertion
# depends on a network, a remote or a credential. Each of the four
# 2026-09-19 defects gets one assertion named after it, plus one for the
# unfalsifiable-check idiom.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/verify-run.sh"
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

# write_ticket NAME VERIFY_BODY — a minimal ticket file whose frontmatter
# carries only what verify-run.sh reads: the `verify: |` block.
write_ticket() {
    local path="$WORK/$1.md"
    {
        echo "---"
        echo "id: $1"
        echo "verify: |"
        sed 's/^/  /'
        echo "---"
        echo
        echo "## Problem"
    } > "$path"
    echo "$path"
}

run_sut() {
    "$SUT" "$@" >"$WORK/stdout" 2>"$WORK/stderr"
    echo $?
}

# --- rule 1: every line gates the result, not only the last -----------------
ticket="$(write_ticket rule1 <<'EOF'
cd ~/code/placeholder
true
false
echo "should never run"
EOF
)"
rc="$(run_sut "$ticket" --root "$WORK")"
if [ "$rc" != 0 ] && ! grep -q 'should never run' "$WORK/stdout" "$WORK/stderr"; then
    ok "every line gates the result, not only the last"
else
    nope "every line gates the result, not only the last" "rc=$rc"
fi

# --- rule 2: no shell trace flag is ever set --------------------------------
ticket="$(write_ticket rule2 <<'EOF'
cd ~/code/placeholder
echo one
echo two
EOF
)"
rc="$(run_sut "$ticket" --root "$WORK")"
if [ "$rc" = 0 ] && ! grep -qE '^\+ ' "$WORK/stdout" "$WORK/stderr"; then
    ok "no shell trace flag is ever set"
else
    nope "no shell trace flag is ever set" "rc=$rc"
fi

# --- rule 4: the repo root is substituted so a block runs from a worktree --
: > "$WORK/marker.txt"
ticket="$(write_ticket rule4 <<'EOF'
cd ~/code/some-repo-that-does-not-exist
test -f marker.txt
EOF
)"
rc="$(run_sut "$ticket" --root "$WORK")"
check "the repo root is substituted so a block runs from a worktree" 0 "$rc"

# --- unfalsifiable idiom: rejected by static inspection ---------------------
ticket="$(write_ticket idiom <<'EOF'
cd ~/code/placeholder
! false || echo "FAIL: should not happen"
touch ran.marker
EOF
)"
rm -f "$WORK/ran.marker"
rc="$(run_sut "$ticket" --root "$WORK")"
if [ "$rc" != 0 ] && [ ! -e "$WORK/ran.marker" ]; then
    ok "a check ending in || echo FAIL is rejected as unfalsifiable"
else
    nope "a check ending in || echo FAIL is rejected as unfalsifiable" "rc=$rc"
fi

# A grep for the idiom's own text (this project's tickets do this) must NOT
# be mistaken for the idiom, since it is quoted text, not a live operator.
ticket="$(write_ticket idiom_quoted <<'EOF'
cd ~/code/placeholder
echo "ok - a check ending in || echo FAIL is rejected as unfalsifiable" | grep -q 'ok - a check ending in || echo FAIL is rejected as unfalsifiable'
EOF
)"
rc="$(run_sut "$ticket" --root "$WORK")"
check "a quoted mention of the idiom is not itself rejected" 0 "$rc"

# --- rule 3 / --against: a block that passes at the base ref is non-discriminating --
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
echo base > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -q -m base
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
echo head > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -q -m head

ticket="$(write_ticket nondiscriminating <<'EOF'
cd ~/code/placeholder
true
EOF
)"
rc="$(run_sut "$ticket" --root "$REPO" --against "$BASE_SHA")"
if [ "$rc" != 0 ] && grep -qi 'non-discriminating' "$WORK/stdout" "$WORK/stderr"; then
    ok "a block that passes at the base ref is reported as non-discriminating"
else
    nope "a block that passes at the base ref is reported as non-discriminating" "rc=$rc"
fi

# The mirror case: a block that genuinely differs across the ref passes clean.
ticket="$(write_ticket discriminating <<'EOF'
cd ~/code/placeholder
grep -q head file.txt
EOF
)"
rc="$(run_sut "$ticket" --root "$REPO" --against "$BASE_SHA")"
check "a block that fails at the base ref and passes on HEAD is reported clean" 0 "$rc"

# --- usage / plumbing -------------------------------------------------------
rc="$(run_sut --help)"
check "--help exits 0" 0 "$rc"
if grep -q -- '--against' "$WORK/stdout"; then ok "--help documents --against"; else nope "--help documents --against"; fi

rc="$(run_sut)"
check "no ticket file is a usage error" 2 "$rc"

rc="$(run_sut "$WORK/does-not-exist.md")"
check "a missing ticket file is a usage error" 2 "$rc"

echo
echo "$((PASS + FAIL)) assertion(s), $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { echo "verify-run-selftest.sh: FAILED"; exit 1; }
echo "verify-run-selftest.sh: all assertions passed"
