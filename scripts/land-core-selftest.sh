#!/usr/bin/env bash
#
# Selftest for land-core.sh. Structurally offline: every case builds a local
# bare repo as its own "origin", so no assertion can reach a network, a
# remote host or a credential. Each case gets a fresh repo, because a
# successful landing deletes the branch it landed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/land-core.sh"
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

contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in *"$needle"*) ok "$name" ;; *) nope "$name" "expected to find [$needle] in:
$hay" ;; esac
}

lacks() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in *"$needle"*) nope "$name" "did NOT expect [$needle] in:
$hay" ;; *) ok "$name" ;; esac
}

# newrepo [--no-remote] — echo a fresh repo dir with main pushed to a local
# bare origin and a one-commit `feature` branch waiting to land. mktemp, not
# a counter: this runs in a command substitution, so a counter never advances
# in the caller and every case would reuse one directory.
newrepo() {
    local remote=1 d
    [ "${1:-}" = "--no-remote" ] && remote=0
    d=$(mktemp -d "$WORK/repoXXXXXX")
    {
        git init -q -b main "$d/repo"
        git -C "$d/repo" config user.email "selftest@example.invalid"
        git -C "$d/repo" config user.name "land-core selftest"
        git -C "$d/repo" config commit.gpgsign false
        echo base > "$d/repo/base.txt"
        git -C "$d/repo" add -A
        git -C "$d/repo" commit -qm base
        if [ "$remote" = 1 ]; then
            git init -q --bare -b main "$d/origin.git"
            git -C "$d/repo" remote add origin "$d/origin.git"
            git -C "$d/repo" push -q origin main
        fi
        git -C "$d/repo" checkout -q -b feature
        echo work > "$d/repo/work.txt"
        git -C "$d/repo" add -A
        git -C "$d/repo" commit -qm "feature work"
        git -C "$d/repo" checkout -q main
    } >/dev/null 2>&1
    printf '%s' "$d"
}

RC=0
OUT=""
# run ARGS... — invoke the script from $WORK, which is not a git repository,
# so nothing can pass by falling back to the caller's cwd.
run() { OUT=$(cd "$WORK" && "$SUT" "$@" 2>&1); RC=$?; }
run_in() { local d="$1"; shift; OUT=$(cd "$d" && "$SUT" "$@" 2>&1); RC=$?; }

origin_main() { git -C "$1/origin.git" rev-parse main 2>/dev/null || echo NONE; }
repo_main()   { git -C "$1/repo" rev-parse main 2>/dev/null || echo NONE; }

# hookfile PATH BODY — write an executable hook and echo its path.
hookfile() {
    local p="$1"
    shift
    printf '%s\n' '#!/usr/bin/env bash' "$@" > "$p"
    chmod +x "$p"
    printf '%s' "$p"
}

echo "== input validation =="

run
check "no arguments is a usage error" 2 "$RC"

run --branch feature
check "--repo omitted is refused" 2 "$RC"
contains "--repo omitted says so by name" "--repo PATH is required" "$OUT"

D=$(newrepo)
run --repo "$D/repo"
check "--branch omitted is refused" 2 "$RC"

run --repo "$WORK" --branch feature
check "--repo outside a git repository is refused" 2 "$RC"

run --repo "$D/repo" --branch does-not-exist
check "a branch that does not exist is refused" 2 "$RC"

run --repo "$D/repo" --branch feature --wat
check "an unknown option is refused" 2 "$RC"

run --repo "$D/repo" --branch feature extra
check "a positional argument is refused" 2 "$RC"

run --repo "$D/repo" --branch feature --hook "$WORK/nope.sh"
check "a --hook that is not executable is refused" 2 "$RC"

# The LAB-300 class: cwd must never decide which repository is landed.
D2=$(newrepo)
D2_BEFORE=$(repo_main "$D2")
run_in "$D2/repo" --branch feature
check "standing inside a repo does not supply --repo" 2 "$RC"
check "the refusal left that repo's main alone" "$D2_BEFORE" "$(repo_main "$D2")"
check "the refusal pushed nothing to that repo's origin" "$D2_BEFORE" "$(origin_main "$D2")"
[ -e "$D2/repo-land" ] && nope "the refusal built no integration worktree" "$D2/repo-land exists" || ok "the refusal built no integration worktree"

echo
echo "== happy path =="

D=$(newrepo)
BEFORE_MAIN=$(repo_main "$D")
run --repo "$D/repo" --branch feature --label TKT-1
check "a clean landing exits 0" 0 "$RC"
AFTER_ORIGIN=$(origin_main "$D")
[ "$AFTER_ORIGIN" != "$BEFORE_MAIN" ] && ok "origin/main advanced" || nope "origin/main advanced" "still $AFTER_ORIGIN"
check "the pushed commit is a merge (two parents)" 2 "$(git -C "$D/origin.git" rev-list --parents -n1 main | wc -w | tr -d ' ' | awk '{print $1-1}')"
contains "the merge subject carries --label" "TKT-1: merge branch 'feature' into main" "$(git -C "$D/origin.git" log -1 --format=%s main)"
check "the landed work is in the pushed tree" "work" "$(git -C "$D/origin.git" show main:work.txt)"
check "the main worktree is NOT fast-forwarded" "$BEFORE_MAIN" "$(repo_main "$D")"
git -C "$D/repo" rev-parse --verify --quiet refs/heads/feature >/dev/null \
    && nope "the landed branch is deleted" "refs/heads/feature still exists" \
    || ok "the landed branch is deleted"
[ -d "$D/repo-land" ] && ok "the integration worktree is created beside the repo" || nope "the integration worktree is created beside the repo" "no $D/repo-land"

D=$(newrepo)
run --repo "$D/repo" --branch feature --merge-message "wholly custom subject"
check "--merge-message lands" 0 "$RC"
check "--merge-message replaces the whole subject" "wholly custom subject" "$(git -C "$D/origin.git" log -1 --format=%s main)"

D=$(newrepo --no-remote)
run --repo "$D/repo" --branch feature
check "a repo with no origin still lands locally" 0 "$RC"
contains "a repo with no origin says nothing was pushed" "no remote configured" "$OUT"

echo
echo "== lint gate =="

D=$(newrepo)
BEFORE=$(origin_main "$D")
run --repo "$D/repo" --branch feature --lint-cmd "false"
check "a failing --lint-cmd exits 1" 1 "$RC"
check "a failing lint pushes nothing" "$BEFORE" "$(origin_main "$D")"
check "a failing lint reverts the merge" "$BEFORE" "$(git -C "$D/repo-land" rev-parse HEAD)"

# The word-splitting fix. Running $LINT_CMD unquoted passes the operator to
# the first word as an argument, so `false || true` fails a lint that should
# pass and `true && false` passes one that should fail. The second direction
# is the dangerous one: a red lint lands.
D=$(newrepo)
run --repo "$D/repo" --branch feature --lint-cmd "false || true"
check "--lint-cmd goes through bash -c, so '||' is evaluated" 0 "$RC"

D=$(newrepo)
BEFORE=$(origin_main "$D")
run --repo "$D/repo" --branch feature --lint-cmd "true && false"
check "--lint-cmd '&&' is evaluated, so a red lint still fails" 1 "$RC"
check "a word-split lint cannot push a red tree" "$BEFORE" "$(origin_main "$D")"

D=$(newrepo)
git -C "$D/repo" checkout -q feature 2>/dev/null
mkdir -p "$D/repo/scripts"
printf '#!/usr/bin/env bash\nexit 1\n' > "$D/repo/scripts/lint.sh"
chmod +x "$D/repo/scripts/lint.sh"
git -C "$D/repo" add -A >/dev/null 2>&1
git -C "$D/repo" commit -qm "add a failing lint" >/dev/null 2>&1
git -C "$D/repo" checkout -q main
BEFORE=$(origin_main "$D")
run --repo "$D/repo" --branch feature
check "./scripts/lint.sh in the MERGED tree is the default gate" 1 "$RC"
check "the default gate failing pushes nothing" "$BEFORE" "$(origin_main "$D")"

D=$(newrepo)
run --repo "$D/repo" --branch feature
check "no lint anywhere still lands" 0 "$RC"
contains "no lint anywhere warns" "skipping" "$OUT"

echo
echo "== the four-point hook contract =="

D=$(newrepo)
LOG="$WORK/hook.log"
: > "$LOG"
H=$(hookfile "$WORK/h-log.sh" \
    "echo \"\$1 sha=[\${LAND_CORE_MERGE_SHA}] pushed=\${LAND_CORE_PUSHED} branch=\${LAND_CORE_BRANCH} target=\${LAND_CORE_TARGET} cwd=\$(pwd -P)\" >> '$LOG'" \
    "exit 0")
run --repo "$D/repo" --branch feature --hook "$H"
check "a hook that exits 0 everywhere lands" 0 "$RC"
check "the four points fire in order" "pre-merge post-merge pre-push post-push" "$(awk '{printf "%s%s", sep, $1; sep=" "} END{print ""}' "$LOG")"
check "LAND_CORE_MERGE_SHA is empty at pre-merge" "sha=[]" "$(awk '$1=="pre-merge"{print $2}' "$LOG")"
[ "$(awk '$1=="post-merge"{print $2}' "$LOG")" = "sha=[]" ] \
    && nope "LAND_CORE_MERGE_SHA is set at post-merge" "still empty" \
    || ok "LAND_CORE_MERGE_SHA is set at post-merge"
check "LAND_CORE_PUSHED is 1 at post-push" "pushed=1" "$(awk '$1=="post-push"{print $3}' "$LOG")"
check "LAND_CORE_BRANCH reaches the hook" "branch=feature" "$(awk '$1=="pre-merge"{print $4}' "$LOG")"
check "LAND_CORE_TARGET reaches the hook" "target=main" "$(awk '$1=="pre-merge"{print $5}' "$LOG")"
check "the hook runs in the integration worktree" "cwd=$(cd "$D" && pwd -P)/repo-land" "$(awk '$1=="pre-merge"{print $6}' "$LOG")"

# A pre-merge hook may commit; a pre-merge refusal must undo that commit,
# which is what the reset to origin/<target> is for.
D=$(newrepo)
BEFORE=$(origin_main "$D")
H=$(hookfile "$WORK/h-premerge-fail.sh" \
    'if [ "$1" = pre-merge ]; then' \
    '  echo half >> half.txt; git add -A' \
    '  git -c user.email=h@example.invalid -c user.name=hook commit -qm "half-made hook commit"' \
    '  exit 3' \
    'fi' \
    'exit 0')
run --repo "$D/repo" --branch feature --hook "$H"
check "a pre-merge refusal exits 2" 2 "$RC"
contains "a pre-merge refusal reports the hook's exit code" "exit 3" "$OUT"
check "a pre-merge refusal pushes nothing" "$BEFORE" "$(origin_main "$D")"
check "a pre-merge refusal undoes the hook's own commit" "$BEFORE" "$(git -C "$D/repo-land" rev-parse HEAD)"
git -C "$D/repo" rev-parse --verify --quiet refs/heads/feature >/dev/null \
    && ok "a pre-merge refusal leaves the branch in place" \
    || nope "a pre-merge refusal leaves the branch in place" "feature was deleted"

D=$(newrepo)
BEFORE=$(origin_main "$D")
H=$(hookfile "$WORK/h-postmerge-fail.sh" '[ "$1" = post-merge ] && exit 4; exit 0')
run --repo "$D/repo" --branch feature --hook "$H"
check "a post-merge failure exits 1" 1 "$RC"
check "a post-merge failure pushes nothing" "$BEFORE" "$(origin_main "$D")"
check "a post-merge failure reverts the merge" "$BEFORE" "$(git -C "$D/repo-land" rev-parse HEAD)"

D=$(newrepo)
BEFORE=$(origin_main "$D")
H=$(hookfile "$WORK/h-prepush-fail.sh" '[ "$1" = pre-push ] && exit 5; exit 0')
run --repo "$D/repo" --branch feature --hook "$H"
check "a pre-push failure exits 1" 1 "$RC"
check "a pre-push failure pushes nothing" "$BEFORE" "$(origin_main "$D")"
check "a pre-push failure reverts the merge" "$BEFORE" "$(git -C "$D/repo-land" rev-parse HEAD)"

# The point the decision entry called the hard one: a pre-push hook's commit
# has to be inside the history the push carries.
D=$(newrepo)
H=$(hookfile "$WORK/h-prepush-commit.sh" \
    'if [ "$1" = pre-push ]; then' \
    '  echo done > completion.txt; git add -A' \
    '  git -c user.email=h@example.invalid -c user.name=hook commit -qm "completion commit"' \
    'fi' \
    'exit 0')
run --repo "$D/repo" --branch feature --hook "$H"
check "a pre-push hook commit lands" 0 "$RC"
check "a pre-push hook commit is INSIDE the pushed history" "done" "$(git -C "$D/origin.git" show main:completion.txt 2>&1)"
check "the pushed tip is the hook's commit, not the merge" "completion commit" "$(git -C "$D/origin.git" log -1 --format=%s main)"

D=$(newrepo)
H=$(hookfile "$WORK/h-postpush-fail.sh" '[ "$1" = post-push ] && exit 6; exit 0')
run --repo "$D/repo" --branch feature --hook "$H"
check "a post-push failure exits 1" 1 "$RC"
check "a post-push failure does NOT revert the landing" "work" "$(git -C "$D/origin.git" show main:work.txt 2>&1)"
contains "a post-push failure says the landing stands" "the landing stands and was NOT reverted" "$OUT"

echo
echo "== dry run =="

D=$(newrepo)
BEFORE=$(origin_main "$D")
: > "$LOG"
H=$(hookfile "$WORK/h-log2.sh" "echo \"\$1\" >> '$LOG'" "exit 0")
run --repo "$D/repo" --branch feature --hook "$H" --dry-run
check "--dry-run exits 0" 0 "$RC"
check "--dry-run pushes nothing" "$BEFORE" "$(origin_main "$D")"
[ -e "$D/repo-land" ] && nope "--dry-run creates no integration worktree" "$D/repo-land exists" || ok "--dry-run creates no integration worktree"
check "--dry-run calls no hook" "" "$(cat "$LOG")"
contains "--dry-run says it called no hook" "before any hook call" "$OUT"

echo
echo "== integration worktree and lock =="

D=$(newrepo)
git -C "$D/repo" worktree add -q --detach "$D/repo-land" main >/dev/null 2>&1
echo dirt > "$D/repo-land/dirt.txt"
run --repo "$D/repo" --branch feature
check "a dirty integration worktree is refused" 2 "$RC"
contains "the refusal names --reset-land" "--reset-land" "$OUT"

run --repo "$D/repo" --branch feature --reset-land
check "--reset-land accepts a dirty integration worktree" 0 "$RC"

D=$(newrepo)
printf 'pid=%s\nstarted=%s\n' "$$" "$(date +%s)" > "$D/repo-land.lock"
run --repo "$D/repo" --branch feature
check "a lock held by a live pid is refused" 2 "$RC"
contains "the lock refusal names the holder's pid" "locked by pid $$" "$OUT"
rm -f "$D/repo-land.lock"

D=$(newrepo)
printf 'pid=%s\nstarted=%s\n' 999999 0 > "$D/repo-land.lock"
run --repo "$D/repo" --branch feature
check "a lock held by a dead pid is reclaimed" 0 "$RC"

D=$(newrepo)
git -C "$D/repo" worktree add -q "$D/feature-wt" feature >/dev/null 2>&1
echo uncommitted > "$D/feature-wt/scratch.txt"
run --repo "$D/repo" --branch feature
check "a dirty worktree holding the branch is refused" 2 "$RC"

echo
echo "== what the move must not carry =="

SRC="$(cat "$SUT")"
lacks "the core never calls tmpfile (kit.sh's signature differs per repo)" "tmpfile" "$SRC"
lacks "the core never reads CLAUDE_PROJECT_DIR (unset outside a hook)" "CLAUDE_PROJECT_DIR" "$SRC"
lacks "the core names no tracker directory" ".night-watchman" "$SRC"
lacks "the core names no multiplexer" "herdr" "$SRC"
lacks "the core carries no attribution trailer" "Co-Authored-By" "$SRC"
lacks "the core carries no session trailer" "Claude-Session" "$SRC"
contains "the core resolves its library from BASH_SOURCE, not \$0" 'dirname "${BASH_SOURCE[0]}"' "$SRC"

echo
echo "$((PASS + FAIL)) assertion(s), $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { echo "land-core-selftest.sh: FAILED"; exit 1; }
echo "land-core-selftest.sh: all assertions passed"
