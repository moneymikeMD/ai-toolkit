#!/usr/bin/env bash
#
# workspace-selftest.sh — exercise workspace.sh against throwaway fixtures.
#
# Every fixture is built under a temp directory and every remote is a local
# bare repo, so the suite never reaches the network and never touches a real
# workspace.
#
# Usage: workspace-selftest.sh

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WS="$SCRIPT_DIR/workspace.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }

git_quiet() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }

# A bare repo standing in for a remote, plus one commit to clone.
mk_remote() {
    git_quiet init --bare "$TMP/remotes/$1.git"
    git_quiet clone "$TMP/remotes/$1.git" "$TMP/seed-$1"
    echo "seed" > "$TMP/seed-$1/README.md"
    git_quiet -C "$TMP/seed-$1" add README.md
    git_quiet -C "$TMP/seed-$1" commit -m "seed"
    git_quiet -C "$TMP/seed-$1" push origin main
}

mkdir -p "$TMP/remotes"
mk_remote alpha
mk_remote beta

WORK="$TMP/ws"
mkdir -p "$WORK"
cat > "$WORK/repos.yaml" <<YAML
workspace: test_ws
root: $WORK
repos:
  alpha:
    url: $TMP/remotes/alpha.git
    branch: main
    agent: true
  beta:
    url: $TMP/remotes/beta.git
    branch: main
    agent: false
  local-only:
    url: null
    agent: false
  plain-dir:
    url: null
    agent: false
extra_agent_dirs:
  - $TMP/extra
YAML

echo "== usage and arguments"
"$WS" --help >/dev/null 2>&1; check "--help exits 0" "$?" "0"
set +e
"$WS" bogus-verb >/dev/null 2>&1; check "unknown verb exits 2" "$?" "2"
"$WS" foreach --root "$WORK" >/dev/null 2>&1; check "foreach with no command exits 2" "$?" "2"
"$WS" list --root "$TMP/remotes" >/dev/null 2>&1; check "missing manifest exits 2" "$?" "2"
set -e

echo "== list"
LINES=$("$WS" list --root "$WORK" | tail -n +2 | wc -l | tr -d ' ')
check "lists every repo including local-only" "$LINES" "4"

echo "== clone"
"$WS" clone --root "$WORK" --dry-run > "$TMP/dry.txt" 2>&1
check "dry-run clones nothing" "$([ -d "$WORK/alpha" ] && echo present || echo absent)" "absent"
check "dry-run skips a null url" "$(grep -c 'skip   local-only' "$TMP/dry.txt")" "1"
"$WS" clone --root "$WORK" >/dev/null 2>&1
check "clone created alpha" "$([ -d "$WORK/alpha/.git" ] && echo yes || echo no)" "yes"
check "clone created beta" "$([ -d "$WORK/beta/.git" ] && echo yes || echo no)" "yes"
check "clone skipped local-only" "$([ -d "$WORK/local-only" ] && echo yes || echo no)" "no"
"$WS" clone --root "$WORK" >/dev/null 2>&1; check "clone is idempotent" "$?" "0"

echo "== status"
"$WS" status --root "$WORK" > "$TMP/status.txt"
check "absent repo reported ABSENT" "$(grep -c 'local-only .*ABSENT' "$TMP/status.txt")" "1"
echo "dirt" > "$WORK/alpha/dirty.txt"
check "dirty file counted" "$("$WS" status --root "$WORK" | awk '$1=="alpha"{print $3}')" "1"
rm "$WORK/alpha/dirty.txt"
check "manifested directory that is not a repo starts ABSENT" \
    "$("$WS" status --root "$WORK" | awk '$1=="plain-dir"{print $4}')" "ABSENT"
mkdir -p "$WORK/plain-dir"
check "non-repo directory reported NOT-A-REPO" \
    "$("$WS" status --root "$WORK" | awk '$1=="plain-dir"{print $4}')" "NOT-A-REPO"

echo "== foreach propagates failure"
set +e
"$WS" foreach --root "$WORK" -- 'true' >/dev/null 2>&1;  check "all-success exits 0" "$?" "0"
"$WS" foreach --root "$WORK" -- 'false' >/dev/null 2>&1; check "any-failure exits 1" "$?" "1"
set -e

echo "== pull"
echo "more" > "$TMP/seed-alpha/second.md"
git_quiet -C "$TMP/seed-alpha" add second.md
git_quiet -C "$TMP/seed-alpha" commit -m "second"
git_quiet -C "$TMP/seed-alpha" push origin main
"$WS" pull --root "$WORK" >/dev/null 2>&1
check "pull fast-forwarded alpha" "$([ -f "$WORK/alpha/second.md" ] && echo yes || echo no)" "yes"
echo "dirt" > "$WORK/beta/dirty.txt"
check "pull skips a dirty repo" "$("$WS" pull --root "$WORK" 2>&1 | grep -c 'skip   beta (dirty)')" "1"
rm "$WORK/beta/dirty.txt"

echo "== gen-settings"
mkdir -p "$WORK/.claude"
cat > "$WORK/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "allow": ["Bash(gh pr merge:*)"],
    "additionalDirectories": ["/stale/path"]
  },
  "unrelatedKey": "keep me"
}
JSON
"$WS" gen-settings --root "$WORK" >/dev/null
GOT=$(python3 -c "
import json;d=json.load(open('$WORK/.claude/settings.json'))
p=d['permissions']
print('|'.join([
  ','.join(p['additionalDirectories']),
  ','.join(p['allow']),
  d.get('unrelatedKey',''),
]))")
check "only agent:true repos plus extras, sorted, absolute" \
    "${GOT%%|*}" "$TMP/extra,$WORK/alpha"
check "existing allow list preserved" "$(echo "$GOT" | cut -d'|' -f2)" "Bash(gh pr merge:*)"
check "unrelated keys preserved" "$(echo "$GOT" | cut -d'|' -f3)" "keep me"
check "stale entry replaced, not appended" \
    "$(grep -c '/stale/path' "$WORK/.claude/settings.json")" "0"

echo
echo "workspace-selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
