#!/usr/bin/env bash
#
# Selftest for no-personal-paths. Every fixture is built under a temp git
# checkout, so the suite never reads the caller's own repository.
#
# The assertions that matter are the discriminating ones: the linter must FAIL
# on a real leak and PASS on a declared fixture. A gate that cannot fail is
# worse than no gate, because it reports green over a leak.

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$HERE/no-personal-paths.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }

run() { ( cd "$TMP/repo" && python3 "$LINT" "$@" 2>&1 ); }
rc()  { ( cd "$TMP/repo" && python3 "$LINT" "$@" >/dev/null 2>&1; echo $? ); }

mkdir -p "$TMP/repo"
cd "$TMP/repo"
git -c init.defaultBranch=main init -q .
git config user.email t@t
git config user.name t

echo '{"args":["/Users/realperson/.claude/mcp/x/server.js"]}' > leak.json
printf 'ok\n' > clean.txt
mkdir -p fixtures
echo '{"cwd":"/Users/fixture/repoC"}' > fixtures/stdin.json
printf 'home is /home/runner/work on a runner\n' > runner.md
printf 'see /Users/somebody/x\n' > CHANGELOG.md
printf 'bin\0/Users/hidden/x\n' > blob.bin
git add -A
git -c user.email=t@t -c user.name=t commit -q -m seed

echo "== a real leak fails"
check "exit 1 on a leak" "$(rc)" "1"
check "names the file and line" \
    "$(run | grep -c '^leak.json:1:')" "1"
check "reports the home directory name" \
    "$(run | grep -c 'home directory name(s): fixture, realperson')" "1"

echo "== built-in exemptions"
check "/home/runner is not a person" "$(run | grep -c 'runner.md')" "0"
check "CHANGELOG.md is exempt (release-please generates it)" \
    "$(run | grep -c 'CHANGELOG.md')" "0"
check "binary file skipped" "$(run | grep -c 'blob.bin')" "0"

echo "== the allow file"
mkdir -p .github
printf 'fixtures/**\n' > .github/personal-paths-allow
check "a path glob silences its fixture" "$(run | grep -c 'fixtures/stdin.json')" "0"
check "but the real leak still fails" "$(rc)" "1"
printf 'fixtures/**\nname:realperson\n' > .github/personal-paths-allow
check "a declared name silences the leak too" "$(rc)" "0"
check "clean run says so" "$(run | grep -c 'file(s) clean')" "1"

printf '# a comment\n\nname:realperson\n' > .github/personal-paths-allow
check "comments and blank lines are ignored" "$(rc)" "1"
check "and the fixture is the one still reported" \
    "$(run | grep -c '^fixtures/stdin.json:1:')" "1"

rm -f .github/personal-paths-allow
check "no allow file is not an error" "$(rc)" "1"
check "a missing --allow-file IS an error" "$(rc --allow-file nope)" "2"

echo "== glob translation"
printf 'leak.json\n' > .github/personal-paths-allow
check "a bare basename matches at any depth" "$(run | grep -c 'leak.json')" "0"
printf '*.json\n' > .github/personal-paths-allow
check "an extension glob matches" "$(run | grep -c 'leak.json')" "0"
printf 'fixtures/\n' > .github/personal-paths-allow
check "a trailing slash means everything beneath" \
    "$(run | grep -c 'fixtures/stdin.json')" "0"
printf 'other/**\n' > .github/personal-paths-allow
check "a non-matching glob silences nothing" "$(rc)" "1"
rm -f .github/personal-paths-allow

echo "== interface"
check "--format json is parseable" \
    "$(run --format json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["violations"]))')" "2"
check "--stats exits 0 even with violations" "$(rc --stats)" "0"
check "--help exits 0" "$(rc --help)" "0"
check "an explicit path argument is honoured" "$(rc clean.txt)" "0"
check "a directory argument is walked" "$(rc fixtures)" "1"

echo ""
echo "no-personal-paths-selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
