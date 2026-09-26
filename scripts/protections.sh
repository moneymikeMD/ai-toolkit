#!/usr/bin/env bash
#
# protections.sh — record how a landing works in every repo a workspace
# manifest names, and gate on drift from the live GitHub API.
#
# For each repo in repos.yaml it reads the facts that decide whether a change
# can be pushed, needs a green check, or needs a human review, and mirrors
# them back into the manifest as generated keys:
#
#   landing                 direct | checks | review | unavailable
#   required_checks         a list of contexts, or none, or unavailable
#   code_owner              a handle, or none, or unavailable
#   protections_fetched_at  UTC, when the three above were measured
#
# visibility is one of the facts fetched, but the manifest already carries a
# hand-written visibility key, so it is checked rather than duplicated. A
# write run corrects it in place and says so; --check reports a difference
# like any other drift.
#
# Two top-level keys are read. `repos:` holds the workspace's own members, one
# per subdirectory. `adjacent_repos:` holds repos whose landing policy matters
# but which are not subdirectories of the workspace at all — the container repo
# the manifest itself lives in, and a dotfiles checkout elsewhere on disk. Both
# are iterated identically here: same generated keys, same store rows, same
# --check drift gate. workspace.sh reads only `repos:`, so an adjacent entry is
# never cloned, pulled, nor handed to an agent as a readable directory. A name
# under both keys is an error, not a merge.
#
# unavailable is not a synonym for "no protections". A private repo on GitHub
# Free cannot have rulesets at all, and the API answers 403 Upgrade to GitHub
# Pro rather than an empty list, so the two are recorded apart: one is a fact
# about the branch, the other is a plan-upgrade decision. All three generated
# values carry it, because "none" in any of them would read as
# measured-and-empty. Any other API failure is an error, never unavailable.
#
# Sources, per repo: gh api repos/OWNER/REPO for visibility and the default
# branch; gh api repos/OWNER/REPO/rulesets and then each id for its rules;
# and, only when a rule requires a code-owner review, the CODEOWNERS file,
# which is where a handle can be read rather than a boolean. A ruleset counts
# only when it is active and its conditions actually match the default branch
# — a ruleset aimed at a branch name that does not exist protects nothing,
# and has already shipped in this ecosystem once (night-watchman, 2026-09-15).
#
# Usage:
#   protections.sh [--root PATH] [--check] [--dry-run] [--emit-json PATH]
#
#   (no flag)         fetch, then write the generated block into repos.yaml
#   --check           compare recorded against live, write nothing, and exit
#                      non-zero naming every repo that differs
#   --dry-run         print the diff a write would make, and write nothing
#   --store           also write the facts to the workspace-state store, via
#                      the workspace-state CLI. A write, so it cannot be
#                      combined with --check or --dry-run.
#   --emit-json PATH  write the collected facts as JSON. `-` means stdout,
#                      which moves the per-repo table to stderr so it cannot
#                      corrupt the payload.
#   --root PATH       the workspace directory. Default: the nearest ancestor
#                      of the current directory holding a repos.yaml.
#
# Exit codes: 0 all good; 1 drift under --check, or a fetch failed; 2 usage;
# 4 --store reached the CLI and the store was unreachable or unconfigured.
# 4 is passed straight through from workspace-state, where it never means an
# empty result, so a caller can tell a store that said nothing from no store
# at all. repos.yaml is written before the store is touched, so a 4 means the
# manifest half succeeded.
#
# The store write is the second half of LAB-292 and needs LAB-291's CLI. It is
# resolved from $WORKSPACE_STATE_BIN, then PATH, and resolved BEFORE any
# fetching so a missing CLI costs nothing. There is deliberately no fallback
# to a dotfiles install path: this repo is public and does not get to know
# where one operator keeps their binaries. Off by default, because the script
# has to keep working on a machine that cannot reach the store at all.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/kit.sh
. "$HERE/lib/kit.sh"

die_usage() { echo "protections.sh: $1" >&2; exit 2; }

ROOT=""
MODE="write"
EMIT_JSON=""
STORE=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) show_help ;;
        --root)
            [ $# -ge 2 ] || die_usage "--root needs a PATH"
            ROOT="$2"; shift 2 ;;
        --check)   MODE="check";   shift ;;
        --dry-run) MODE="dry-run"; shift ;;
        --store)   STORE=1;        shift ;;
        --emit-json)
            [ $# -ge 2 ] || die_usage "--emit-json needs a PATH"
            EMIT_JSON="$2"; shift 2 ;;
        *) die_usage "unexpected argument '$1' (try --help)" ;;
    esac
done

if [ "$STORE" -eq 1 ] && [ "$MODE" != "write" ]; then
    die_usage "--store is a write, so it cannot be combined with --$MODE"
fi

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

need gh python3
python3 -c 'import yaml' 2>/dev/null || die "PyYAML is required: pip3 install pyyaml"

# Resolved before any fetching, so a missing CLI costs nothing rather than
# being discovered after twenty API calls. It is not on PATH by default.
WORKSPACE_STATE=""
if [ "$STORE" -eq 1 ]; then
    if [ -n "${WORKSPACE_STATE_BIN+set}" ]; then
        [ -n "$WORKSPACE_STATE_BIN" ] || die_usage "WORKSPACE_STATE_BIN is set but empty"
        WORKSPACE_STATE="$WORKSPACE_STATE_BIN"
    elif command -v workspace-state >/dev/null 2>&1; then
        WORKSPACE_STATE="$(command -v workspace-state)"
    else
        die_usage "--store needs workspace-state: not on PATH and \$WORKSPACE_STATE_BIN is unset. This repo is public and deliberately does not know where your dotfiles install it."
    fi
    [ -x "$WORKSPACE_STATE" ] || die_usage "not executable: $WORKSPACE_STATE"
    # --store always has a payload to hand the CLI, whether or not the caller
    # asked for one of their own.
    if [ -z "$EMIT_JSON" ]; then
        tmpfile EMIT_JSON || die "could not create the payload tempfile"
    fi
    [ "$EMIT_JSON" != "-" ] || die_usage "--store needs --emit-json to name a file, not -"
fi

set +e
python3 - "$MANIFEST" "$MODE" "$EMIT_JSON" <<'PY'
import base64, difflib, fnmatch, json, os, re, subprocess, sys
from datetime import datetime, timezone

import yaml

MANIFEST, MODE, EMIT_JSON = sys.argv[1], sys.argv[2], sys.argv[3]

BEGIN = "# Generated by ai-toolkit/scripts/protections.sh from the live GitHub API."
NOTE = "# Do not hand-edit: protections.sh --check exits non-zero on any drift."
END = "# end generated"
MEMBERS = "repos"
ADJACENT = "adjacent_repos"
BEGIN_RE = re.compile(r"^\s*# Generated by ai-toolkit/scripts/protections\.sh")
END_RE = re.compile(r"^\s*# end generated\s*$")
UNAVAILABLE = "unavailable"


class Fatal(Exception):
    pass


class Unavailable(Exception):
    pass


def gh_api(path):
    proc = subprocess.run(
        ["gh", "api", path], capture_output=True, text=True)
    if proc.returncode == 0:
        return json.loads(proc.stdout or "null")
    body = {}
    try:
        body = json.loads(proc.stdout or "{}")
    except ValueError:
        pass
    message = (body.get("message") if isinstance(body, dict) else "") or ""
    # The one failure that is a recorded state rather than an error. Matched on
    # the plan message, not on 403 alone, so a scope or permission 403 stays an
    # error instead of being written down as "this repo has no rulesets".
    if str(body.get("status") if isinstance(body, dict) else "") == "403" \
            and "Upgrade to GitHub" in message:
        raise Unavailable(message)
    detail = message or (proc.stderr or "").strip() or "no output"
    raise Fatal("gh api %s failed: %s" % (path, detail))


def slug_of(url):
    match = re.search(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?$", url or "")
    if not match:
        raise Fatal("cannot read OWNER/REPO out of url %r" % url)
    return "%s/%s" % (match.group(1), match.group(2))


def applies_to_default(conditions, default_branch):
    ref = (conditions or {}).get("ref_name") or {}
    full = "refs/heads/%s" % default_branch
    included = False
    for pattern in ref.get("include") or []:
        if pattern in ("~ALL", "~DEFAULT_BRANCH") or fnmatch.fnmatch(full, pattern):
            included = True
            break
    if not included:
        return False
    for pattern in ref.get("exclude") or []:
        if fnmatch.fnmatch(full, pattern):
            return False
    return True


def codeowners_handle(slug, branch):
    for path in (".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"):
        try:
            data = gh_api("repos/%s/contents/%s?ref=%s" % (slug, path, branch))
        except (Fatal, Unavailable):
            continue
        if not isinstance(data, dict) or "content" not in data:
            continue
        text = base64.b64decode(data["content"]).decode("utf-8", "replace")
        for line in text.splitlines():
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if parts[0] == "*" and len(parts) > 1:
                return ",".join(parts[1:])
    # A rule requires a code-owner review but no `*` owner resolves. Saying so
    # is the honest record; "none" would read as no code owner required.
    return "required"


def fetch(name, url, adjacent):
    slug = slug_of(url)
    repo = gh_api("repos/%s" % slug)
    facts = {
        "name": name,
        "slug": slug,
        "adjacent": adjacent,
        "visibility": repo.get("visibility"),
        "default_branch": repo.get("default_branch") or "main",
    }
    try:
        listed = gh_api("repos/%s/rulesets" % slug) or []
    except Unavailable:
        facts.update(landing=UNAVAILABLE, required_checks=UNAVAILABLE,
                     code_owner=UNAVAILABLE, required_approvals=UNAVAILABLE,
                     rulesets=UNAVAILABLE)
        return facts

    contexts, approvals, code_owner_required = [], 0, False
    for entry in sorted(listed, key=lambda r: r.get("id") or 0):
        detail = gh_api("repos/%s/rulesets/%s" % (slug, entry.get("id")))
        if detail.get("target") != "branch":
            continue
        if detail.get("enforcement") != "active":
            continue
        if not applies_to_default(detail.get("conditions"), facts["default_branch"]):
            continue
        for rule in detail.get("rules") or []:
            params = rule.get("parameters") or {}
            if rule.get("type") == "required_status_checks":
                for check in params.get("required_status_checks") or []:
                    context = check.get("context")
                    if context and context not in contexts:
                        contexts.append(context)
            elif rule.get("type") == "pull_request":
                approvals = max(
                    approvals,
                    int(params.get("required_approving_review_count") or 0))
                code_owner_required = code_owner_required or bool(
                    params.get("require_code_owner_review"))

    if approvals > 0 or code_owner_required:
        landing = "review"
    elif contexts:
        landing = "checks"
    else:
        landing = "direct"
    facts.update(
        landing=landing,
        required_checks=contexts or "none",
        code_owner=(codeowners_handle(slug, facts["default_branch"])
                    if code_owner_required else "none"),
        required_approvals=approvals,
        rulesets=len(listed),
    )
    return facts


def scalar(value):
    return '"%s"' % value if value.startswith("@") else value


def render(facts, stamp, indent):
    out = [indent + BEGIN, indent + NOTE,
           indent + "landing: %s" % facts["landing"]]
    checks = facts["required_checks"]
    if isinstance(checks, list):
        out.append(indent + "required_checks:")
        out.extend(indent + "  - %s" % c for c in checks)
    else:
        out.append(indent + "required_checks: %s" % checks)
    out.append(indent + "code_owner: %s" % scalar(facts["code_owner"]))
    out.append(indent + 'protections_fetched_at: "%s"' % stamp)
    out.append(indent + END)
    return out


def section_blocks(lines, section, required):
    """Yield (name, start, end) for each repo mapping under one top-level key."""
    head = re.compile(r"^%s:\s*$" % re.escape(section))
    try:
        top = next(i for i, l in enumerate(lines) if head.match(l))
    except StopIteration:
        if required:
            raise Fatal("no top-level %s: key in the manifest" % section)
        return []
    heads = []
    for i in range(top + 1, len(lines)):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0:
            break
        match = re.match(r"^  ([^\s:#][^:]*):\s*$", line)
        if indent == 2 and match:
            heads.append((match.group(1), i))
    ends = []
    for pos, (_, start) in enumerate(heads):
        stop = heads[pos + 1][1] if pos + 1 < len(heads) else None
        if stop is None:
            stop = len(lines)
            for i in range(start + 1, len(lines)):
                line = lines[i]
                if line.strip() and len(line) - len(line.lstrip()) == 0:
                    stop = i
                    break
        ends.append(stop)
    return [(heads[i][0], heads[i][1], ends[i]) for i in range(len(heads))]


def repo_blocks(lines):
    blocks = section_blocks(lines, MEMBERS, True)
    blocks += section_blocks(lines, ADJACENT, False)
    return sorted(blocks, key=lambda b: b[1])


def strip_generated(block):
    out, skipping = [], False
    for line in block:
        if BEGIN_RE.match(line):
            skipping = True
            continue
        if skipping:
            if END_RE.match(line):
                skipping = False
            continue
        out.append(line)
    return out


def rewrite(lines, name_to_facts, stamp):
    out = list(lines)
    for name, start, end in reversed(repo_blocks(out)):
        facts = name_to_facts.get(name)
        if facts is None:
            continue
        block = strip_generated(out[start + 1:end])
        body = [i for i, l in enumerate(block)
                if l.strip() and not l.lstrip().startswith("#")]
        if not body:
            raise Fatal("repo %s has no keys to append to" % name)
        last = body[-1]
        # Indented from the entry key, never from the last body line: that
        # line may be a block-scalar continuation, and a key written at its
        # indent parses as more of the string.
        indent = " " * (len(out[start]) - len(out[start].lstrip()) + 2)
        visibility = "%svisibility: %s" % (indent, facts["visibility"])
        seen = False
        for i in body:
            if re.match(r"^\s*visibility:", block[i]):
                block[i] = visibility
                seen = True
        generated = render(facts, stamp, indent)
        if not seen:
            generated.insert(0, visibility)
        block[last + 1:last + 1] = generated
        out[start + 1:end] = block
    return out


def recorded(manifest):
    """Every entry to be measured, plus the names that came from adjacent_repos."""
    doc = yaml.safe_load(open(manifest)) or {}
    def section(key):
        return {n: (r or {}) for n, r in (doc.get(key) or {}).items()}
    members, adjacent = section(MEMBERS), section(ADJACENT)
    # A name in both sections would make the write order decide which entry
    # wins, so it is refused rather than merged.
    both = sorted(set(members) & set(adjacent))
    if both:
        raise Fatal("named under both %s: and %s:: %s"
                    % (MEMBERS, ADJACENT, ", ".join(both)))
    members.update(adjacent)
    return members, set(adjacent)


def compare(name, entry, facts):
    differences = []
    if "landing" not in entry:
        return ["%s: no generated block recorded — run protections.sh" % name]
    pairs = [("landing", entry.get("landing"), facts["landing"]),
             ("required_checks", entry.get("required_checks"),
              facts["required_checks"]),
             ("code_owner", entry.get("code_owner"), facts["code_owner"]),
             ("visibility", entry.get("visibility"), facts["visibility"])]
    for key, got, want in pairs:
        if got != want:
            differences.append(
                "%s: %s recorded %r, live %r" % (name, key, got, want))
    return differences


def main():
    text = open(MANIFEST).read()
    lines = text.splitlines()
    entries, adjacent = recorded(MANIFEST)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    collected, failures = {}, []
    for name, entry in entries.items():
        url = entry.get("url")
        if not url:
            print("skip   %s (no url in the manifest)" % name, file=sys.stderr)
            continue
        try:
            collected[name] = fetch(name, url, name in adjacent)
        except Fatal as exc:
            failures.append("%s: %s" % (name, exc))

    for line in failures:
        print("ERROR  %s" % line, file=sys.stderr)

    n_adjacent = len(adjacent & set(collected))
    n_members = len(collected) - n_adjacent

    # With --emit-json - the payload owns stdout, so the human-readable table
    # moves to stderr rather than corrupting it.
    report = sys.stderr if EMIT_JSON == "-" else sys.stdout
    for name in sorted(collected):
        facts = collected[name]
        checks = facts["required_checks"]
        print("%-20s %-11s %-11s checks=%s approvals=%s code_owner=%s adjacent=%s"
              % (name, facts["visibility"], facts["landing"],
                 ",".join(checks) if isinstance(checks, list) else checks,
                 facts["required_approvals"], facts["code_owner"],
                 "yes" if facts["adjacent"] else "no"), file=report)

    if EMIT_JSON:
        payload = {"fetched_at": stamp,
                   "repos": [collected[n] for n in sorted(collected)]}
        if EMIT_JSON == "-":
            json.dump(payload, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
        else:
            with open(EMIT_JSON, "w") as handle:
                json.dump(payload, handle, indent=2, sort_keys=True)
                handle.write("\n")
            print("wrote %s" % EMIT_JSON, file=report)

    if failures:
        return 1

    if MODE == "check":
        drift = []
        for name in sorted(collected):
            drift.extend(compare(name, entries[name], collected[name]))
        if drift:
            print("protections drift:", file=sys.stderr)
            for line in drift:
                print("  %s" % line, file=sys.stderr)
            return 1
        print("protections --check: %d repos, %d adjacent, no drift"
              % (n_members, n_adjacent), file=report)
        return 0

    updated = rewrite(lines, collected, stamp)
    rendered = "\n".join(updated) + "\n"
    if rendered == text:
        print("repos.yaml unchanged", file=report)
        return 0
    if MODE == "dry-run":
        sys.stdout.writelines(difflib.unified_diff(
            text.splitlines(True), rendered.splitlines(True),
            fromfile=MANIFEST, tofile="%s (would write)" % MANIFEST))
        return 0
    with open(MANIFEST, "w") as handle:
        handle.write(rendered)
    print("wrote %s (%d repos, %d adjacent)"
          % (MANIFEST, n_members, n_adjacent), file=report)
    for name in sorted(collected):
        if entries[name].get("visibility") not in (None, collected[name]["visibility"]):
            print("note   %s: corrected the hand-written visibility key to %s"
                  % (name, collected[name]["visibility"]), file=report)
    return 0


try:
    sys.exit(main())
except Fatal as exc:
    print("protections.sh: %s" % exc, file=sys.stderr)
    sys.exit(1)
PY
STATUS=$?
set -e

if [ "$STATUS" -ne 0 ] || [ "$MODE" != "write" ]; then
    exit "$STATUS"
fi

if [ "$STORE" -eq 0 ]; then
    echo "state store: not written (pass --store)" >&2
    exit 0
fi

# Exit 4 is the CLI's "unreachable or unconfigured", and it is never an empty
# result, so it is passed through rather than folded into a generic failure:
# a caller has to be able to tell a store that said nothing from no store.
set +e
"$WORKSPACE_STATE" protections set --file "$EMIT_JSON"
STORE_STATUS=$?
set -e
case "$STORE_STATUS" in
    0) echo "state store: written via $WORKSPACE_STATE" >&2 ;;
    4) echo "state store: unreachable or unconfigured (workspace-state exit 4); repos.yaml was still written" >&2 ;;
    *) echo "state store: write failed (workspace-state exit $STORE_STATUS); repos.yaml was still written" >&2 ;;
esac
exit "$STORE_STATUS"
