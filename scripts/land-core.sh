#!/bin/bash
#
# land-core.sh — merge a finished branch onto a target branch and push it,
# through a dedicated integration worktree. The generic half of a "land a
# ticket" script: it knows nothing about tickets, trackers, dispatch or
# multiplexers. A consuming repo supplies those through one hook script.
#
# Usage:
#   land-core.sh --repo PATH --branch NAME
#                [--target BRANCH] [--label TEXT] [--merge-message MSG]
#                [--lint-cmd CMD] [--hook PATH] [--reset-land] [--dry-run]
#   land-core.sh --help
#
# --repo is MANDATORY and has no cwd fallback. Every other script here is
# invoked by absolute path from outside the repo it acts on, and this one
# merges, pushes and deletes a branch: a cwd default would silently pick
# whichever repo the caller happened to be standing in.
#
# INTEGRATION WORKTREE. Merge, lint and push run in
# `<parent-of-the-main-worktree>/<repo-basename>-land`, never in --repo
# itself. Every run resets it to origin/<target>; a dirty one is refused
# unless --reset-land is passed; a concurrent run is refused by the lock file
# at `<worktree>.lock`, which is never waited on. The main worktree is NOT
# fast-forwarded afterwards — the summary prints the pull to run by hand.
#
# THE HOOK CONTRACT. --hook PATH names one executable, called as
# `PATH <point>` with cwd set to the integration worktree, at four points:
#
#   pre-merge   the worktree is synced to origin/<target>; nothing is merged.
#               A hook may commit here; those commits are inside the push.
#               Non-zero: the worktree is reset to origin/<target> (undoing
#               any hook commit) and the run stops with exit 2.
#   post-merge  the merge commit exists, lint has not run.
#               Non-zero: the merge is reverted, exit 1.
#   pre-push    lint has passed, nothing is pushed. A hook may commit here;
#               those commits are inside the push.
#               Non-zero: the merge is reverted, exit 1.
#   post-push   the push succeeded (or there was no remote). The landing
#               stands and is never reverted. Non-zero is recorded, cleanup
#               still runs, and the script exits 1 reporting it.
#
# Exit 0 from a point the hook does not handle. Context arrives as env vars,
# not positional arguments, so later additions cannot shift a hook's $2:
# LAND_CORE_POINT, LAND_CORE_REPO (the main worktree), LAND_CORE_WORKTREE
# (the integration worktree), LAND_CORE_BRANCH, LAND_CORE_TARGET,
# LAND_CORE_LABEL, LAND_CORE_MERGE_SHA (empty before the merge) and
# LAND_CORE_PUSHED (post-push only: 1 pushed, 0 no remote).
#
# --dry-run calls NO hook and runs no mutating command, including creating
# the integration worktree. A consumer prints its own plan around this one.
#
# Reverting the merge means `git reset --hard ORIG_HEAD`, so a commit a
# pre-merge hook made survives it, unpushed; the next run's reset to
# origin/<target> discards it.
#
# Exit codes:
#   0   landed cleanly
#   1   a step failed AFTER the merge succeeded (post-merge hook, lint,
#       pre-push hook). The merge is reverted first — except a failed push
#       or a failed post-push hook, which are NOT reverted: the landing is
#       complete locally, and for a failed push, unpushed.
#   2   stopped early — bad input, a dirty tree, a merge conflict, a failed
#       git precondition, or a pre-merge hook refusal. Nothing was pushed.
#
# Env overrides (the flag always wins):
#   LAND_CORE_TARGET_BRANCH   branch to land onto (default: main).
#   LAND_CORE_LINT_CMD        command run on the merged tree (default:
#                             ./scripts/lint.sh in the merged tree if it is
#                             executable, else skipped with a warning).
#   LAND_CORE_HOOK            hook script path.
#
# --lint-cmd runs through `bash -c`, so `a && b` works. night-watchman's
# land-branch.sh word-splits it instead; that is a known issue there.

set -euo pipefail
# shellcheck source=lib/kit.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/kit.sh"

TARGET_BRANCH="${LAND_CORE_TARGET_BRANCH:-main}"
LINT_CMD="${LAND_CORE_LINT_CMD:-}"
HOOK="${LAND_CORE_HOOK:-}"
REPO_ARG=""
BRANCH=""
LABEL=""
MERGE_MSG_ARG=""
RESET_LAND=0
DRY_RUN=0

# This script never sets a trap: kit.sh keeps the one EXIT handler, so every
# controlled exit path releases the lock explicitly instead.
LAND_LOCK_FILE=""
LAND_LOCK_ACQUIRED=0

# release_land_lock — best-effort; a failure warns rather than exits, because
# the next run's stale-pid reclaim recovers an orphaned lock.
release_land_lock() {
    [ "$LAND_LOCK_ACQUIRED" = 1 ] || return 0
    [ -n "$LAND_LOCK_FILE" ] || return 0
    LAND_LOCK_ACQUIRED=0
    rm -f "$LAND_LOCK_FILE" 2>/dev/null \
        || warn "could not remove lock file '$LAND_LOCK_FILE' — remove it by hand once no land-core.sh run is using it"
}

# stop2 MESSAGE... — a precondition failed and nothing was pushed. Exit 2.
stop2() { release_land_lock; echo "Error: $*" >&2; exit 2; }

# reset_to_origin — undo whatever a pre-merge hook committed. Used only
# before the merge, where origin/<target> is the exact starting state.
reset_to_origin() {
    git reset --hard "origin/$TARGET_BRANCH" >/dev/null 2>&1 \
        || warn "could not reset to origin/$TARGET_BRANCH — the next run's sync will"
}

# revert_merge — put $TARGET_BRANCH back where the merge found it.
revert_merge() {
    git reset --hard ORIG_HEAD >/dev/null 2>&1 \
        || warn "git reset --hard ORIG_HEAD failed — the integration worktree may still carry the merge commit, check by hand"
}

stop2_reset() { release_land_lock; revert_merge; echo "Error: $*" >&2; exit 2; }
die_reset()   { release_land_lock; revert_merge; die "$*"; }

# acquire_land_lock FILE — never waits: wins the lock, or refuses naming the
# holder's pid. A holder whose pid is not running is reclaimed and retried.
acquire_land_lock() {
    local file="$1" attempt=0 tmp holder_pid holder_started
    LAND_LOCK_FILE="$file"
    while [ "$attempt" -lt 20 ]; do
        attempt=$((attempt + 1))
        tmp="$file.holder.$$"
        printf 'pid=%s\nstarted=%s\n' "$$" "$(date +%s)" > "$tmp" \
            || stop2 "could not write a temp lock-holder file '$tmp'"
        if ln "$tmp" "$file" 2>/dev/null; then
            rm -f "$tmp"
            LAND_LOCK_ACQUIRED=1
            return 0
        fi
        rm -f "$tmp"
        holder_pid=""
        holder_started=""
        if [ -f "$file" ]; then
            holder_pid=$(awk -F= '/^pid=/{print $2}' "$file" 2>/dev/null)
            holder_started=$(awk -F= '/^started=/{print $2}' "$file" 2>/dev/null)
        fi
        case "$holder_pid" in ''|*[!0-9]*) holder_pid="" ;; esac
        if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2>/dev/null; then
            stop2 "integration worktree '$LAND_WORKTREE' is locked by pid $holder_pid (started epoch $holder_started) — another land-core.sh run holds it. Wait for it, or remove '$file' by hand if you are certain that pid is not land-core.sh"
        fi
        rm -f "$file" 2>/dev/null
    done
    stop2 "could not acquire the integration worktree lock '$file' after $attempt attempts — repeatedly lost the race, or could not create/remove it (permissions?)"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|help) show_help ;;
        --dry-run) DRY_RUN=1; shift ;;
        --reset-land) RESET_LAND=1; shift ;;
        --repo)
            [ $# -ge 2 ] || stop2 "--repo needs a path"
            REPO_ARG="$2"; shift 2 ;;
        --branch)
            [ $# -ge 2 ] || stop2 "--branch needs a branch name"
            BRANCH="$2"; shift 2 ;;
        --target)
            [ $# -ge 2 ] || stop2 "--target needs a branch name"
            TARGET_BRANCH="$2"; shift 2 ;;
        --label)
            [ $# -ge 2 ] || stop2 "--label needs text"
            LABEL="$2"; shift 2 ;;
        --merge-message)
            [ $# -ge 2 ] || stop2 "--merge-message needs text"
            MERGE_MSG_ARG="$2"; shift 2 ;;
        --lint-cmd)
            [ $# -ge 2 ] || stop2 "--lint-cmd needs a command"
            LINT_CMD="$2"; shift 2 ;;
        --hook)
            [ $# -ge 2 ] || stop2 "--hook needs a path"
            HOOK="$2"; shift 2 ;;
        -*) stop2 "unknown option: $1 (see --help)" ;;
        *)  stop2 "unexpected positional argument '$1' — every input is a flag (see --help)" ;;
    esac
done

need git

[ -n "$REPO_ARG" ] || stop2 "--repo PATH is required and has no cwd default — name the repository to land in"
[ -d "$REPO_ARG" ] || stop2 "--repo '$REPO_ARG' is not a directory"
[ -n "$BRANCH" ] || stop2 "--branch NAME is required"
[ -n "$TARGET_BRANCH" ] || stop2 "--target must not be empty"
LF=$'\n'
case "$LABEL" in *"$LF"*) stop2 "--label must not contain a newline — it becomes the merge subject's prefix" ;; esac

if [ -n "$HOOK" ]; then
    [ -x "$HOOK" ] || stop2 "--hook '$HOOK' is missing or not executable"
    case "$HOOK" in
        /*) ;;
        *) HOOK="$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")" ;;
    esac
fi

REPO_TOP=$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null) \
    || stop2 "--repo '$REPO_ARG' is not inside a git repository"

git -C "$REPO_TOP" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null \
    || stop2 "branch '$BRANCH' does not exist in '$REPO_TOP'"

# A real `git worktree list` failure swallowed into "" is indistinguishable
# from "no worktrees", so it stops here rather than being guessed past.
if ! WT_PORCELAIN=$(git -C "$REPO_TOP" worktree list --porcelain 2>&1); then
    stop2 "could not evaluate 'git worktree list' in '$REPO_TOP': $WT_PORCELAIN"
fi
MAIN_WORKTREE=$(printf '%s\n' "$WT_PORCELAIN" | awk '/^worktree /{sub(/^worktree /,""); print; exit}')
[ -n "$MAIN_WORKTREE" ] || stop2 "could not determine the main worktree of '$REPO_TOP'"
LAND_WORKTREE="$(dirname "$MAIN_WORKTREE")/$(basename "$MAIN_WORKTREE")-land"
LAND_EXISTS=0
printf '%s\n' "$WT_PORCELAIN" | grep -qxF "worktree $LAND_WORKTREE" && LAND_EXISTS=1

BRANCH_WT=$(printf '%s\n' "$WT_PORCELAIN" | awk -v b="refs/heads/$BRANCH" '
    /^worktree / { path=$0; sub(/^worktree /,"",path) }
    /^branch /   { br=$0; sub(/^branch /,"",br); if (br==b) print path }
')
if [ -n "$BRANCH_WT" ]; then
    if ! WT_STATUS=$(git -C "$BRANCH_WT" status --porcelain 2>&1); then
        stop2 "could not check worktree '$BRANCH_WT' for branch '$BRANCH' (removed or corrupt worktree?): $WT_STATUS"
    fi
    [ -z "$WT_STATUS" ] || stop2 "branch '$BRANCH' worktree at '$BRANCH_WT' has uncommitted changes — commit or stash them first"
fi

MERGE_MSG="$MERGE_MSG_ARG"
[ -n "$MERGE_MSG" ] || MERGE_MSG="${LABEL:+$LABEL: }merge branch '$BRANCH' into $TARGET_BRANCH

Landed via land-core.sh."

MERGE_SHA=""
PUSHED=0
POST_PUSH_FAILED=""

# run_hook POINT — call the hook script with its context. Returns the hook's
# exit code; callers decide what that means at their point.
run_hook() {
    [ -n "$HOOK" ] || return 0
    echo "hook: $HOOK $1"
    LAND_CORE_POINT="$1" \
    LAND_CORE_REPO="$MAIN_WORKTREE" \
    LAND_CORE_WORKTREE="$LAND_WORKTREE" \
    LAND_CORE_BRANCH="$BRANCH" \
    LAND_CORE_TARGET="$TARGET_BRANCH" \
    LAND_CORE_LABEL="$LABEL" \
    LAND_CORE_MERGE_SHA="$MERGE_SHA" \
    LAND_CORE_PUSHED="$PUSHED" \
        "$HOOK" "$1"
}

if [ "$LAND_EXISTS" = 1 ]; then
    if ! LAND_PLAN_STATUS=$(git -C "$LAND_WORKTREE" status --porcelain 2>&1); then
        LAND_STATE_DESC="exists, but its status could not be checked: $LAND_PLAN_STATUS"
    elif [ -z "$LAND_PLAN_STATUS" ]; then
        LAND_STATE_DESC="exists, clean"
    else
        LAND_STATE_DESC="exists, DIRTY:
$LAND_PLAN_STATUS"
    fi
else
    LAND_STATE_DESC="does not exist yet — will be created via 'git worktree add --detach' on '$TARGET_BRANCH'"
fi

# The lint preview reads the MAIN worktree; the gate reads the merged tree,
# which does not exist yet. They can disagree, hence "preview".
LINT_PREVIEW="(no lint command configured, and '$MAIN_WORKTREE/scripts/lint.sh' is not executable — will be skipped)"
if [ -n "$LINT_CMD" ]; then
    LINT_PREVIEW="$LINT_CMD"
elif [ -x "$MAIN_WORKTREE/scripts/lint.sh" ]; then
    LINT_PREVIEW="./scripts/lint.sh (preview from '$MAIN_WORKTREE'; the gate reads the merged tree)"
fi

echo "Plan:"
echo "  0. integration worktree: '$LAND_WORKTREE' ($LAND_STATE_DESC)"
echo "  1. hook pre-merge${HOOK:+ ($HOOK)}"
echo "  2. merge '$BRANCH' into '$TARGET_BRANCH' (--no-ff), inside the integration worktree"
echo "  3. hook post-merge${HOOK:+ ($HOOK)}"
echo "  4. lint on the merged tree: $LINT_PREVIEW"
echo "  5. hook pre-push${HOOK:+ ($HOOK)}"
echo "  6. git push origin HEAD:$TARGET_BRANCH (from the integration worktree; '$MAIN_WORKTREE' is not fast-forwarded automatically)"
echo "  7. hook post-push${HOOK:+ ($HOOK)}"
WT_PLAN=" git worktree remove $BRANCH_WT, then"
[ -n "$BRANCH_WT" ] && [ "$BRANCH_WT" != "$MAIN_WORKTREE" ] || WT_PLAN=""
echo "  8.$WT_PLAN git branch -d '$BRANCH'"
[ -n "$HOOK" ] || echo "  (no --hook given — every hook step is a no-op)"

if [ "$DRY_RUN" = 1 ]; then
    echo
    echo "--dry-run: stopping before any git-mutating command, and before any hook call. Nothing was changed."
    exit 0
fi

echo
echo "Acquiring the integration worktree lock..."
acquire_land_lock "$LAND_WORKTREE.lock"

# Recomputed under the lock: the preflight read ran before this run held it,
# so another run could have created or removed the worktree in between.
if ! WT_PORCELAIN=$(git -C "$REPO_TOP" worktree list --porcelain 2>&1); then
    stop2 "could not re-evaluate 'git worktree list' after acquiring the lock: $WT_PORCELAIN"
fi
LAND_EXISTS=0
printf '%s\n' "$WT_PORCELAIN" | grep -qxF "worktree $LAND_WORKTREE" && LAND_EXISTS=1

if [ "$LAND_EXISTS" != 1 ]; then
    if [ -e "$LAND_WORKTREE" ]; then
        stop2 "'$LAND_WORKTREE' exists on disk but is not a registered worktree of this repo — remove it or move it aside, then re-run"
    fi
    echo "Creating integration worktree '$LAND_WORKTREE' (detached, on '$TARGET_BRANCH')..."
    ADD_OUT=$(git -C "$MAIN_WORKTREE" worktree add --detach "$LAND_WORKTREE" "$TARGET_BRANCH" 2>&1) \
        || stop2 "could not create integration worktree '$LAND_WORKTREE': $ADD_OUT"
elif [ ! -e "$LAND_WORKTREE/.git" ]; then
    echo "Integration worktree '$LAND_WORKTREE' is registered but missing on disk — pruning and recreating..."
    git -C "$MAIN_WORKTREE" worktree prune >/dev/null 2>&1 || true
    ADD_OUT=$(git -C "$MAIN_WORKTREE" worktree add --detach "$LAND_WORKTREE" "$TARGET_BRANCH" 2>&1) \
        || stop2 "could not recreate integration worktree '$LAND_WORKTREE': $ADD_OUT"
fi

# Refuse a dirty integration worktree BEFORE the reset below, which would
# otherwise discard an uncommitted change silently. --reset-land opts in.
LAND_STATUS_PRE=$(git -C "$LAND_WORKTREE" status --porcelain 2>&1) \
    || stop2 "could not check integration worktree '$LAND_WORKTREE' status: $LAND_STATUS_PRE"
if [ -n "$LAND_STATUS_PRE" ]; then
    if [ "$RESET_LAND" = 1 ]; then
        echo "--reset-land: discarding uncommitted changes in '$LAND_WORKTREE':"
        printf '%s\n' "$LAND_STATUS_PRE"
        git -C "$LAND_WORKTREE" reset --hard >/dev/null 2>&1 || stop2 "--reset-land: 'git reset --hard' failed in '$LAND_WORKTREE'"
        git -C "$LAND_WORKTREE" clean -fd >/dev/null 2>&1 || stop2 "--reset-land: 'git clean -fd' failed in '$LAND_WORKTREE'"
    else
        stop2 "integration worktree '$LAND_WORKTREE' has uncommitted changes:
$LAND_STATUS_PRE
Pass --reset-land to discard them, or clean '$LAND_WORKTREE' by hand. '$MAIN_WORKTREE' is untouched either way."
    fi
fi

if git -C "$LAND_WORKTREE" remote 2>/dev/null | grep -qx origin; then
    echo "Fetching origin into '$LAND_WORKTREE'..."
    FETCH_OUT=$(git -C "$LAND_WORKTREE" fetch origin 2>&1) || stop2 "git fetch origin failed in '$LAND_WORKTREE': $FETCH_OUT"
    echo "Resetting '$LAND_WORKTREE' to origin/$TARGET_BRANCH..."
    git -C "$LAND_WORKTREE" reset --hard "origin/$TARGET_BRANCH" >/dev/null 2>&1 \
        || stop2 "could not reset '$LAND_WORKTREE' to origin/$TARGET_BRANCH — does that ref exist on origin?"
else
    warn "no 'origin' remote — syncing '$LAND_WORKTREE' to local '$TARGET_BRANCH' instead, and nothing will be pushed"
    git -C "$LAND_WORKTREE" reset --hard "$TARGET_BRANCH" >/dev/null 2>&1 \
        || stop2 "could not reset '$LAND_WORKTREE' to '$TARGET_BRANCH'"
fi
git -C "$LAND_WORKTREE" clean -fd >/dev/null 2>&1 \
    || stop2 "could not clean untracked files from '$LAND_WORKTREE' after reset"

cd "$LAND_WORKTREE"

# Nothing is merged yet, so a refusal here needs no ORIG_HEAD revert — only
# the reset that undoes a commit the hook itself may have made.
HOOK_RC=0
run_hook pre-merge || HOOK_RC=$?
if [ "$HOOK_RC" != 0 ]; then
    reset_to_origin
    stop2 "the pre-merge hook refused (exit $HOOK_RC) — nothing merged, nothing pushed"
fi

echo
echo "Merging '$BRANCH' into '$TARGET_BRANCH'..."
MERGE_OUTPUT=""
if ! MERGE_OUTPUT=$(git merge --no-ff "$BRANCH" -m "$MERGE_MSG" 2>&1); then
    if ! CONFLICTS=$(git diff --name-only --diff-filter=U 2>&1); then
        CONFLICTS="(could not list conflicting files: $CONFLICTS)"
    fi
    git merge --abort >/dev/null 2>&1 || true
    if [ -n "$CONFLICTS" ]; then
        stop2 "merge conflict, aborted, nothing changed. Conflicting file(s):
$CONFLICTS"
    fi
    stop2 "git merge failed, aborted, nothing changed — not a content conflict (no conflicting files were left). git said:
$MERGE_OUTPUT"
fi

if ! STILL_UNMERGED=$(git diff --name-only --diff-filter=U 2>&1); then
    stop2_reset "could not verify the merge left no unmerged paths: $STILL_UNMERGED"
fi
[ -z "$STILL_UNMERGED" ] || stop2_reset "merge reported success but left unmerged paths — reverted:
$STILL_UNMERGED"
MERGE_SHA=$(git rev-parse HEAD)
echo "merged clean ($MERGE_SHA)."

run_hook post-merge || die_reset "the post-merge hook failed — merge reverted, nothing pushed"

EFFECTIVE_LINT="$LINT_CMD"
if [ -z "$EFFECTIVE_LINT" ] && [ -x ./scripts/lint.sh ]; then
    EFFECTIVE_LINT="./scripts/lint.sh"
fi
if [ -n "$EFFECTIVE_LINT" ]; then
    echo "Running $EFFECTIVE_LINT on the merged tree..."
    if ! bash -c "$EFFECTIVE_LINT"; then
        echo "lint failed on the merged tree — reverting the merge." >&2
        die_reset "lint failed; merge reverted, nothing pushed"
    fi
    echo "lint: clean."
else
    warn "no lint command configured (--lint-cmd / \$LAND_CORE_LINT_CMD) and no executable ./scripts/lint.sh in the merged tree — skipping"
fi

run_hook pre-push || die_reset "the pre-push hook failed — merge reverted, nothing pushed"

REMOTES=$(git remote 2>/dev/null) || REMOTES=""
if [ -n "$REMOTES" ]; then
    echo "Pushing (the integration worktree is detached — explicit refspec)..."
    if ! git push origin "HEAD:$TARGET_BRANCH"; then
        release_land_lock
        die "git push failed — the landing is complete LOCALLY (in '$LAND_WORKTREE'); resolve, then run 'git -C \"$LAND_WORKTREE\" push origin HEAD:$TARGET_BRANCH' by hand — do not reset, that would discard a completed landing"
    fi
    PUSHED=1
    echo "pushed."
    echo
    echo "Note: '$MAIN_WORKTREE' was NOT fast-forwarded automatically (a sibling may hold uncommitted edits there). To update it:"
    echo "  git -C '$MAIN_WORKTREE' pull --ff-only"
else
    echo "no remote configured — skipping push."
fi

# The push is the deploy. The landing stands whatever happens from here; a
# post-push failure is reported at the end and exits 1, never reverted.
HOOK_RC=0
run_hook post-push || HOOK_RC=$?
[ "$HOOK_RC" = 0 ] || POST_PUSH_FAILED="the post-push hook failed (exit $HOOK_RC)"

if [ -n "$BRANCH_WT" ] && [ "$BRANCH_WT" != "$MAIN_WORKTREE" ] && [ -e "$BRANCH_WT" ]; then
    case "$(pwd -P)/" in
        "$BRANCH_WT"/*) warn "worktree '$BRANCH_WT' holds branch '$BRANCH' but this script is running inside it — left in place" ;;
        *)
            if WT_RM=$(git -C "$MAIN_WORKTREE" worktree remove "$BRANCH_WT" 2>&1); then
                echo "removed worktree '$BRANCH_WT'."
            else
                warn "could not remove worktree '$BRANCH_WT' — left in place: $WT_RM"
            fi
            ;;
    esac
fi

# Run from the integration worktree, whose HEAD carries the merge: `git
# branch -d` refuses a branch not merged into the HEAD it is run against,
# and the main worktree is deliberately left un-fast-forwarded.
if git branch -d "$BRANCH" >/dev/null 2>&1; then
    echo "deleted local branch '$BRANCH'."
else
    warn "could not delete local branch '$BRANCH' — left in place"
fi

echo
if [ -n "$POST_PUSH_FAILED" ]; then
    release_land_lock
    die "branch '$BRANCH' landed on '$TARGET_BRANCH' and was pushed — the landing stands and was NOT reverted — but $POST_PUSH_FAILED. Whatever that hook owns is unfinished; finish it by hand"
fi
echo "branch '$BRANCH' landed on '$TARGET_BRANCH'."
release_land_lock
exit 0
