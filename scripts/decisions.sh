#!/bin/bash
#
# Manage docs/decisions.d/ — one markdown file per decision, named
# <YYYY-MM-DD>-<slug>.md. There is no docs/decisions.md and no generated index;
# lookup is grep over the directory. Touches nothing but docs/decisions.d/;
# never contacts a host and reads no credential.
#
# Usage:
#   decisions.sh add --title T --decision D --why W --cost C
#                     [--supersedes PATH] [--root PATH]
#   decisions.sh lint [--root PATH]
#   decisions.sh list [--root PATH]
#
# Subcommands:
#   add     Write docs/decisions.d/<local YYYY-MM-DD>-<slug>.md. The slug is
#           the title lowercased and hyphenated. title, decision, why and cost
#           are all required and non-empty (the three-gate entry bar); a
#           missing or blank one writes nothing. Refuses a slug that already
#           exists under any date. --supersedes takes a repo-relative path to
#           an existing record. Never reads or writes docs/decisions.md.
#   lint    Fails if docs/decisions.md exists. Every record needs frontmatter
#           date, slug, title; date is YYYY-MM-DD or the literal 0000-00-00
#           (undated legacy entry); filename must match date and slug. A
#           record needs Decision, Why and Cost sections; Why or Cost may be
#           the literal `unrecorded` only when the frontmatter says
#           `migrated: true`. Every supersedes path resolves, and so does
#           every relative Markdown link into docs/decisions.d/ from any *.md
#           in the repo. Needs no network and no sibling checkout.
#   list    Print date, slug and title, tab-separated, oldest first.
#
# Global option, recognised anywhere in the argument list:
#   --root PATH   the repo to manage. Without it the repo comes from the
#                  CALLER'S cwd. A caller whose cwd has drifted then writes
#                  into whichever repo cwd is in, silently, so always pass it.
#                  A set-but-empty or non-git --root fails loudly.
#
# Record format (docs/decisions.d/<date>-<slug>.md):
#   ---
#   date: YYYY-MM-DD
#   slug: <slug>
#   title: "<title>"
#   supersedes: docs/decisions.d/<other>.md     (optional)
#   migrated: true                              (legacy records only)
#   ---
#
#   # <title>
#
#   ## Decision
#   ## Why
#   ## Cost
#
# Every subcommand answers -h/--help on its own.
#
set -euo pipefail
# shellcheck source=lib/kit.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/kit.sh"

need python3 git date

VALUE_OPTS="--title --decision --why --cost --supersedes --root"
HAVE_ROOT=0
ROOT_OVERRIDE=""
ARGS=()
PREV=""
# shellcheck disable=SC2086  # VALUE_OPTS is a deliberate word-split list
while [ $# -gt 0 ]; do
    if [ "$1" = "--root" ] && ! known_command "$PREV" $VALUE_OPTS; then
        [ $# -ge 2 ] || die "--root needs a PATH"
        ROOT_OVERRIDE="$2"; HAVE_ROOT=1; PREV=""; shift 2; continue
    fi
    case "$1" in
        --root=*)
            if ! known_command "$PREV" $VALUE_OPTS; then
                ROOT_OVERRIDE="${1#--root=}"; HAVE_ROOT=1; PREV=""; shift; continue
            fi ;;
    esac
    ARGS+=("$1"); PREV="$1"; shift
done
set -- ${ARGS[@]+"${ARGS[@]}"}

[ $# -ge 1 ] || show_help
case "$1" in -h|--help|help) show_help ;; esac
SUB="$1"; shift
case "$SUB" in
    add|lint|list) ;;
    *) die "unknown subcommand: $SUB (add|lint|list)" ;;
esac
for a in "$@"; do
    case "$a" in -h|--help) show_help ;; esac
done

if [ "$HAVE_ROOT" = 1 ]; then
    [ -n "$ROOT_OVERRIDE" ] || die "--root: PATH is empty"
    [ -d "$ROOT_OVERRIDE" ] || die "--root: no such directory: $ROOT_OVERRIDE"
    ROOT="$(git -C "$ROOT_OVERRIDE" rev-parse --show-toplevel 2>/dev/null)" \
        || die "--root: not a git repository: $ROOT_OVERRIDE"
else
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
fi
ENTRIES_DIR="$ROOT/docs/decisions.d"

slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

blank() { [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]; }

cmd_add() {
    local title="" decision="" why="" cost="" supersedes="" have_t=0 have_d=0 have_w=0 have_c=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --title|--decision|--why|--cost|--supersedes)
                [ $# -ge 2 ] || die "$1 needs a value"
                case "$1" in
                    --title) title="$2"; have_t=1 ;;
                    --decision) decision="$2"; have_d=1 ;;
                    --why) why="$2"; have_w=1 ;;
                    --cost) cost="$2"; have_c=1 ;;
                    --supersedes) supersedes="$2" ;;
                esac
                shift 2 ;;
            *) die "add: unknown argument: $1" ;;
        esac
    done
    [ "$have_t" = 1 ] && ! blank "$title" || die "add: --title is required and must not be empty"
    [ "$have_d" = 1 ] && ! blank "$decision" || die "add: --decision is required and must not be empty"
    [ "$have_w" = 1 ] && ! blank "$why" || die "add: --why is required and must not be empty"
    [ "$have_c" = 1 ] && ! blank "$cost" || die "add: --cost is required and must not be empty"
    case "$title" in *$'\n'*) die "add: --title must be one line" ;; esac

    local slug
    slug="$(slugify "$title")"
    [ -n "$slug" ] || die "add: --title yields an empty slug: $title"

    if [ -n "$supersedes" ]; then
        case "$supersedes" in /*|*..*) die "add: --supersedes must be a repo-relative path without '..': $supersedes" ;; esac
        [ -f "$ROOT/$supersedes" ] || die "add: --supersedes does not resolve: $supersedes"
    fi

    local existing
    existing="$(find "$ENTRIES_DIR" -maxdepth 1 -name "*-$slug.md" 2>/dev/null | head -n 1 || true)"
    [ -z "$existing" ] || die "add: slug already exists: $slug ($existing)"

    local today file qtitle
    today="$(date +%F)"
    file="$ENTRIES_DIR/$today-$slug.md"
    qtitle="$(printf '%s' "$title" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    mkdir -p "$ENTRIES_DIR"
    (
        set -o noclobber
        {
            printf -- '---\n'
            printf 'date: %s\n' "$today"
            printf 'slug: %s\n' "$slug"
            printf 'title: "%s"\n' "$qtitle"
            [ -z "$supersedes" ] || printf 'supersedes: %s\n' "$supersedes"
            printf -- '---\n\n# %s\n\n## Decision\n\n%s\n\n## Why\n\n%s\n\n## Cost\n\n%s\n' \
                "$title" "$decision" "$why" "$cost"
        } > "$file"
    ) 2>/dev/null || die "add: could not create $file (already exists?)"
    echo "$file"
}

# Not a command substitution around the heredoc: bash 3.2 mis-parses a backtick run inside one.
run_py() {
python3 -I - "$@" <<'PY'
import json, os, re, subprocess, sys

root, mode = sys.argv[1], sys.argv[2]
rel_dir = "docs/decisions.d"
d = os.path.join(root, rel_dir)
errors = []

def err(msg):
    errors.append(msg)

def parse(path):
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    if not lines or lines[0] != "---":
        return None, None
    fm, i = {}, 1
    while i < len(lines) and lines[i] != "---":
        m = re.match(r"^([A-Za-z_]+): ?(.*)$", lines[i])
        if m:
            v = m.group(2)
            if v.startswith('"'):
                try:
                    v = json.loads(v)
                except ValueError:
                    v = v.strip('"').replace('\\"', '"').replace("\\\\", "\\")
            fm[m.group(1)] = v
        i += 1
    if i >= len(lines):
        return None, None
    return fm, "\n".join(lines[i + 1:])

def sections(body):
    out, cur = {}, None
    for line in body.split("\n"):
        m = re.match(r"^## (Decision|Why|Cost)\s*$", line)
        if m:
            cur = m.group(1)
            out[cur] = []
        elif re.match(r"^#{1,2} ", line):
            cur = None
        elif cur:
            out[cur].append(line)
    return {k: "\n".join(v).strip() for k, v in out.items()}

records = []
if os.path.isdir(d):
    for name in sorted(os.listdir(d)):
        if name.endswith(".md"):
            records.append(name)

if mode == "list":
    for name in records:
        fm, _ = parse(os.path.join(d, name))
        if fm is None:
            continue
        print("\t".join([fm.get("date", ""), fm.get("slug", ""), fm.get("title", "")]))
    sys.exit(0)

if os.path.exists(os.path.join(root, "docs", "decisions.md")):
    err("docs/decisions.md exists: the end state is one record per file under docs/decisions.d/, no index")

for name in records:
    rel = f"{rel_dir}/{name}"
    fm, body = parse(os.path.join(d, name))
    if fm is None:
        err(f"{rel}: no parseable frontmatter")
        continue
    for k in ("date", "slug", "title"):
        if not fm.get(k, "").strip():
            err(f"{rel}: frontmatter {k} missing or empty")
    date, slug = fm.get("date", ""), fm.get("slug", "")
    if date and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        err(f"{rel}: date is not YYYY-MM-DD or 0000-00-00: {date}")
    if date and slug and name != f"{date}-{slug}.md":
        err(f"{rel}: filename does not match date-slug ({date}-{slug}.md)")
    migrated = fm.get("migrated", "") == "true"
    sec = sections(body)
    for k in ("Decision", "Why", "Cost"):
        if not sec.get(k):
            err(f"{rel}: section '## {k}' missing or empty")
    for k in ("Why", "Cost"):
        if sec.get(k) == "unrecorded" and not migrated:
            err(f"{rel}: {k} is 'unrecorded' but frontmatter lacks migrated: true")
    sup = fm.get("supersedes", "")
    if sup and not os.path.isfile(os.path.join(root, sup)):
        err(f"{rel}: supersedes does not resolve: {sup}")

files = subprocess.run(
    ["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.md"],
    capture_output=True, check=True).stdout.decode("utf-8", "replace").split("\0")
link_re = re.compile(r"\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
d_real = os.path.realpath(d)
for f in files:
    if not f or not os.path.isfile(os.path.join(root, f)):
        continue
    fence = None
    with open(os.path.join(root, f), encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            m = re.match(r"^\s*(`{3,}|~{3,})", line)
            if m:
                if fence is None:
                    fence = m.group(1)[0]
                elif m.group(1)[0] == fence:
                    fence = None
                continue
            if fence:
                continue
            for target in link_re.findall(line):
                if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target) or target.startswith("#") or target.startswith("/"):
                    continue
                path = target.split("#", 1)[0].split("?", 1)[0]
                if not path:
                    continue
                full = os.path.realpath(os.path.join(root, os.path.dirname(f), path))
                if full == d_real or full.startswith(d_real + os.sep):
                    if not os.path.exists(full):
                        err(f"{f}:{n}: link does not resolve: {target}")

for e in errors:
    print(f"lint: {e}", file=sys.stderr)
if errors:
    print(f"lint: {len(errors)} problem(s)", file=sys.stderr)
    sys.exit(1)
print(f"ok: {len(records)} decision record(s)")
PY
}

case "$SUB" in
    add) cmd_add "$@" ;;
    lint) [ $# -eq 0 ] || die "lint: unexpected argument: $1"; run_py "$ROOT" lint ;;
    list) [ $# -eq 0 ] || die "list: unexpected argument: $1"; run_py "$ROOT" list ;;
esac
