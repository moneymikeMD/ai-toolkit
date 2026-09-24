#!/usr/bin/env bash
#
# workspace.sh — operate on every repo a workspace manifest names, and generate
# the agent read scope from it.
#
# A workspace is a directory holding a repos.yaml and one subdirectory per
# project, each its own independent git clone. There is no superproject and no
# pinning: the manifest records which repos belong together and which an agent
# may read, not which commit each one sits at.
#
# Usage:
#   workspace.sh [--root PATH] <verb> [args]   (options go either side of the verb)
#
#   list                  one line per repo: name, branch, agent flag, url
#   clone                 clone any repo missing from disk (skips url: null)
#   status                per-repo branch, dirty count, unpushed count
#   pull                  git pull --ff-only in every clean repo
#   foreach -- CMD...     run CMD in each repo directory that exists
#   gen-settings          write .claude/settings.json additionalDirectories
#                          from every `agent: true` repo plus extra_agent_dirs,
#                          leaving all other settings keys untouched
#
#   --root PATH   the workspace directory. Default: nearest ancestor of the
#                  current directory that contains a repos.yaml.
#   --dry-run     gen-settings and clone print what they would do.
#
# Exit codes: 0 all good; 1 a repo-level operation failed; 2 usage or setup.

set -eu

VERB=""
ROOT=""
DRY_RUN=0

die_usage() { echo "workspace.sh: $1" >&2; exit 2; }
die() { echo "workspace.sh: $1" >&2; exit 1; }
usage() { sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; }

[ $# -ge 1 ] || { usage; exit 2; }

FOREACH_CMD=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --root)
            [ $# -ge 2 ] || die_usage "--root needs a PATH"
            ROOT="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --)
            [ -n "$VERB" ] || die_usage "'--' before a verb (try --help)"
            shift; FOREACH_CMD="$*"; break ;;
        list|clone|status|pull|foreach|gen-settings)
            [ -z "$VERB" ] || die_usage "unexpected argument '$1'"
            VERB="$1"; shift ;;
        *)
            [ -n "$VERB" ] || die_usage "unknown verb '$1' (try --help)"
            die_usage "unexpected argument '$1'" ;;
    esac
done

[ -n "$VERB" ] || die_usage "no verb given (try --help)"
[ "$VERB" != "foreach" ] || [ -n "$FOREACH_CMD" ] || die_usage "foreach needs -- CMD..."

if [ -z "$ROOT" ]; then
    ROOT=$(pwd)
    while [ ! -f "$ROOT/repos.yaml" ] && [ "$ROOT" != "/" ]; do
        ROOT=$(dirname "$ROOT")
    done
    [ -f "$ROOT/repos.yaml" ] || die_usage "no repos.yaml here or in any parent; pass --root"
fi
ROOT=$(cd "$ROOT" && pwd)
MANIFEST="$ROOT/repos.yaml"
[ -f "$MANIFEST" ] || die_usage "no manifest at $MANIFEST"

python3 -c 'import yaml' 2>/dev/null || die "PyYAML is required: pip3 install pyyaml (or apt install python3-yaml)"

# Emits one TAB-separated record per repo: name, url, branch, agent.
# A url of "-" means the manifest declared it local-only.
read_manifest() {
    python3 - "$MANIFEST" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
for name, r in (doc.get("repos") or {}).items():
    r = r or {}
    url = r.get("url") or "-"
    print("\t".join([name, url, r.get("branch") or "main",
                     "true" if r.get("agent") else "false"]))
PY
}

case "$VERB" in
list)
    printf '%-24s %-8s %-6s %s\n' NAME BRANCH AGENT URL
    while IFS="$(printf '\t')" read -r name url branch agent; do
        printf '%-24s %-8s %-6s %s\n' "$name" "$branch" "$agent" "$url"
    done < <(read_manifest)
    ;;

clone)
    rc=0
    while IFS="$(printf '\t')" read -r name url branch agent; do
        if [ -e "$ROOT/$name" ]; then
            continue
        fi
        if [ "$url" = "-" ]; then
            echo "skip   $name (local only, no remote in manifest)"
            continue
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "would  git clone -b $branch $url $ROOT/$name"
            continue
        fi
        echo "clone  $name"
        git clone -b "$branch" "$url" "$ROOT/$name" || rc=1
    done < <(read_manifest)
    exit $rc
    ;;

status)
    printf '%-24s %-28s %-7s %s\n' NAME BRANCH DIRTY UNPUSHED
    while IFS="$(printf '\t')" read -r name url branch agent; do
        d="$ROOT/$name"
        if [ ! -d "$d" ]; then
            printf '%-24s %-28s %-7s %s\n' "$name" "-" "-" "ABSENT"
            continue
        fi
        if [ ! -e "$d/.git" ]; then
            printf '%-24s %-28s %-7s %s\n' "$name" "-" "-" "NOT-A-REPO"
            continue
        fi
        b=$(git -C "$d" branch --show-current)
        [ -n "$b" ] || b="(detached)"
        n=$(git -C "$d" status --porcelain | wc -l | tr -d ' ')
        u=$(git -C "$d" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "no-upstream")
        printf '%-24s %-28s %-7s %s\n' "$name" "$b" "$n" "$u"
    done < <(read_manifest)
    ;;

pull)
    rc=0
    while IFS="$(printf '\t')" read -r name url branch agent; do
        d="$ROOT/$name"
        [ -e "$d/.git" ] || continue
        if [ -n "$(git -C "$d" status --porcelain)" ]; then
            echo "skip   $name (dirty)"
            continue
        fi
        git -C "$d" rev-parse '@{u}' >/dev/null 2>&1 || { echo "skip   $name (no upstream)"; continue; }
        echo "pull   $name"
        git -C "$d" pull --ff-only --quiet || rc=1
    done < <(read_manifest)
    exit $rc
    ;;

foreach)
    rc=0
    while IFS="$(printf '\t')" read -r name url branch agent; do
        d="$ROOT/$name"
        [ -d "$d" ] || continue
        echo "=== $name"
        ( cd "$d" && eval "$FOREACH_CMD" ) || rc=1
    done < <(read_manifest)
    exit $rc
    ;;

gen-settings)
    OUT="$ROOT/.claude/settings.json"
    DRY_RUN="$DRY_RUN" python3 - "$MANIFEST" "$ROOT" "$OUT" <<'PY'
import json, os, sys, yaml
manifest, root, out = sys.argv[1], sys.argv[2], sys.argv[3]
doc = yaml.safe_load(open(manifest)) or {}

dirs = [os.path.join(root, n)
        for n, r in (doc.get("repos") or {}).items() if (r or {}).get("agent")]
dirs += [os.path.expanduser(p) for p in (doc.get("extra_agent_dirs") or [])]
dirs.sort()

settings = {}
if os.path.exists(out):
    with open(out) as fh:
        settings = json.load(fh)

# Absolute, because a relative additionalDirectories entry resolves against a
# root that is not the settings file's own directory, which silently yields a
# path that does not exist.
settings.setdefault("permissions", {})["additionalDirectories"] = dirs
rendered = json.dumps(settings, indent=2) + "\n"

if os.environ.get("DRY_RUN") == "1":
    sys.stdout.write(rendered)
else:
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as fh:
        fh.write(rendered)
    print("wrote %s (%d directories)" % (out, len(dirs)))
PY
    ;;
esac
