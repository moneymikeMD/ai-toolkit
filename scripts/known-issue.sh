#!/bin/bash
#
# Manage docs/known-issues/ — one markdown file per finding, with
# docs/known-issues.md as a GENERATED index rendered from their frontmatter.
#
# Touches nothing but docs/known-issues/ and docs/known-issues.md;
# never contacts a host and reads no credential.
#
# Subcommands:
#   migrate                    ONE-SHOT. Split the hand-written
#                               docs/known-issues.md into one file per entry
#                               under docs/known-issues/, then regenerate the
#                               index. Heading detection is CommonMark
#                               fence-aware and cross-checked against two
#                               differently-shaped implementations. Entries
#                               are staged and verified ENTIRELY FROM DISK
#                               before going live, so a failure leaves the
#                               real docs/known-issues/ untouched.
#                               Refuses a second run unless the directory is
#                               empty or --force is given, which additionally
#                               requires every existing entry to match its
#                               recorded sha256. A heading with no severity is
#                               never guessed at: every one is printed with
#                               its line number unless --accept-severity
#                               -defaults is given, which defaults them LOW.
#   reindex                    Regenerate docs/known-issues.md from the
#                               frontmatter of every file under
#                               docs/known-issues/. Idempotent — running it
#                               twice with no entry changes produces a
#                               byte-identical file.
#   add                        Create a new entry file and reindex.
#   resolve <slug>              Mark an entry resolved (status + date) and
#                               reindex.
#   severity <slug> <SEV>       Change an entry's severity and reindex.
#   remanifest <slug>...        Re-record the sha256 of the named entries, so
#                               a lint that failed on drift can be made green
#                               deliberately. Per-slug and printed; no --all,
#                               because acceptance must be an act and not a
#                               rubber stamp. Touches only _manifest.json: it
#                               never rewrites an entry and never reindexes.
#   remanifest --drop <slug>... Drop the record of an entry whose file is
#                               GONE. Separate because it is a delete: it
#                               refuses a slug whose file is still there, and
#                               re-recording refuses one whose file is not.
#   lint                        Verify every entry parses, has the required
#                               frontmatter and a unique slug, still matches
#                               its sha256 in _manifest.json, and that
#                               docs/known-issues.md is exactly what
#                               `reindex` would produce. Non-zero on any
#                               failure; the check CI runs on every push. A
#                               manifest failure names `remanifest` as the
#                               way back to green.
#
# Every subcommand answers -h/--help on its own; run with no arguments for
# the same text this comment carries.
#
# Global option, recognised anywhere in the argument list:
#   --root PATH   the repo to manage. Without it the repo comes from the
#                  CALLER'S cwd, kept as the default for the plugin case. A
#                  caller whose cwd has drifted then writes into whichever
#                  repo cwd is in, silently; twice already (NWM-122, NWM-142).
#
# Frontmatter fields (docs/known-issues/<slug>.md):
#   title        entry title, without the trailing severity/status suffix
#   heading_raw  the ORIGINAL '## ' heading, verbatim, minus the '## '. The
#                lossless backstop: migrate asserts every source heading
#                reconstructs from some entry's heading_raw.
#   severity     one of HIGH | MEDIUM | LOW | COSMETIC (CRITICAL folds into
#                HIGH — there is no fifth bucket)
#   status       open | resolved
#   resolved     YYYY-MM-DD — present only when status is resolved
#   qualifiers   [ "...", ... ] — whatever the heading suffix said beyond
#                severity/status/date. May be empty.
#   note         optional one-line note (the index row after the em-dash)
#   tickets      [ "PREFIX-nnn", ... ] — may be empty
#   slug         the file's own slug, for round-trip safety
#
# docs/known-issues/_manifest.json is NOT an entry. It records the sha256 this
# tool wrote for every slug and is what --force and lint check against;
# never hand-edit.
#
set -euo pipefail
# shellcheck source=lib/kit.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/kit.sh"

need python3 git

# --root is lifted out of the argument list before the subcommand is read, so
# it works in any position and no subcommand parser has to know about it. An
# argument sitting in a value-taking option's slot is never treated as a flag,
# so `--note --root` stays a note.
VALUE_OPTS="--title --severity --body --note --tickets --date --root"
HAVE_ROOT=0
ROOT_OVERRIDE=""
ARGS=()
PREV=""
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

# ROOT is the repo being managed, NOT this script's own location: a plugin
# script runs from ${CLAUDE_PLUGIN_ROOT}, outside the target repo entirely.
# --root overrides that; cwd stays the default so the plugin case is unbroken.
if [ "$HAVE_ROOT" = 1 ]; then
    # HAVE_ROOT rather than [ -n "$ROOT_OVERRIDE" ]: a set-but-EMPTY --root is
    # a caller bug and must fail here, not read as "absent" and silently fall
    # back to cwd — the target this flag exists to take away from cwd.
    [ -n "$ROOT_OVERRIDE" ] || die "--root: PATH is empty"
    [ -d "$ROOT_OVERRIDE" ] || die "--root: no such directory: $ROOT_OVERRIDE"
    ROOT="$(git -C "$ROOT_OVERRIDE" rev-parse --show-toplevel 2>/dev/null)" \
        || die "--root: not a git repository: $ROOT_OVERRIDE"
else
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
fi
ENTRIES_DIR="$ROOT/docs/known-issues"
INDEX_FILE="$ROOT/docs/known-issues.md"
SEVERITIES="HIGH MEDIUM LOW COSMETIC"

valid_severity() {
    local want="$1" s
    for s in $SEVERITIES; do [ "$s" = "$want" ] && return 0; done
    return 1
}

valid_date() {
    case "$1" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

# Any tracker's key shape: a prefix (letters, optionally digits/underscore),
# a dash, then digits — "PROJ-42", "PROJ-007", "ENG_2-9" all match. Not tied
# to one tracker's convention.
valid_ticket() {
    case "$1" in
        [A-Za-z]*-[0-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

valid_slug_shape() {
    # Kept separate from the existence check so the two report DIFFERENT
    # messages: "not a slug" and "no such entry" are not the same failure.
    local s="$1"
    [ -n "$s" ] || return 1
    case "$s" in
        *[!a-z0-9-]*) return 1 ;;
        -*|*-|*--*) return 1 ;;
    esac
    return 0
}

valid_slug() {
    # Shape first, existence second: an existence-only check lets a slug like
    # '../../elsewhere/x' rewrite a file outside $ENTRIES_DIR.
    local s="$1"
    valid_slug_shape "$s" || return 1
    [ -f "$ENTRIES_DIR/$s.md" ]
}

# The engine is written to a kit.sh tmpfile once at startup and every
# subcommand below shells out to it.

tmpfile ENGINE || die "could not create the engine tempfile"
cat > "$ENGINE" <<'PYEOF'
#!/usr/bin/env python3
import argparse
import difflib
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile

# Sidecar manifest recording the sha256 this tool wrote for each slug, last
# write wins. Not a *.md file, so load_all_entries never sees it as an entry.
MANIFEST_NAME = "_manifest.json"


def manifest_path(entries_dir):
    return os.path.join(entries_dir, MANIFEST_NAME)


def load_manifest(entries_dir):
    p = manifest_path(entries_dir)
    if not os.path.exists(p):
        return None
    with open(p) as fh:
        return json.load(fh)


def save_manifest(entries_dir, manifest):
    with open(manifest_path(entries_dir), "w") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
        fh.write("\n")


def file_hash(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def record_written(entries_dir, slug, path):
    """Update (or create) the manifest entry for one just-written file.
    Used by add/resolve/severity so their own writes never look like a
    stray hand edit on the next --force."""
    manifest = load_manifest(entries_dir) or {}
    manifest[slug] = file_hash(path)
    save_manifest(entries_dir, manifest)


def check_manifest(entries_dir, entries):
    """Compare every entry's current sha256 against _manifest.json, the
    only record of what add/resolve/severity last wrote; a hand-edit that
    bypasses those commands leaves the recorded hash stale, and a deleted
    file leaves an orphaned key. Called from lint so this runs on every
    routine invocation, not only the rare migrate --force recovery path."""
    manifest = load_manifest(entries_dir)
    if manifest is None:
        return ["%s is missing — no record of what this tool last wrote, so "
                "a hand-edit to any entry would go undetected. Recreate it "
                "with `known-issue.sh remanifest <slug>...`, naming every "
                "entry you are vouching for." % manifest_path(entries_dir)]
    errors = []
    present_slugs = set()
    for meta, body, relpath, path in entries:
        present_slugs.add(meta["slug"])
        recorded = manifest.get(meta["slug"])
        if recorded is None:
            errors.append(
                "%s has no entry in %s — never recorded. Accept it with "
                "`known-issue.sh remanifest %s`." %
                (path, manifest_path(entries_dir), meta["slug"]))
        elif recorded != file_hash(path):
            errors.append(
                "%s does not match its recorded sha256 in %s — edited by "
                "something other than add/resolve/severity since it was "
                "last written. If that edit was intended, accept it with "
                "`known-issue.sh remanifest %s`." %
                (path, manifest_path(entries_dir), meta["slug"]))
    for slug in sorted(manifest):
        if slug not in present_slugs:
            errors.append(
                "%s is recorded in %s but %s does not exist — deleted since "
                "it was written. If that deletion was intended, drop the "
                "record with `known-issue.sh remanifest --drop %s`." % (
                    slug, manifest_path(entries_dir),
                    os.path.join(entries_dir, slug + ".md"), slug))
    return errors

SEV_ORDER = ["HIGH", "MEDIUM", "LOW", "COSMETIC"]
SEV_WORDS = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "COSMETIC"]
SEV_NORM = {"CRITICAL": "HIGH", "HIGH": "HIGH", "MEDIUM": "MEDIUM",
            "LOW": "LOW", "COSMETIC": "COSMETIC"}
DATE_RE = re.compile(r"\b(\d{4}-\d{2}-\d{2})\b")
TICKET_RE = re.compile(r"\b[A-Za-z][A-Za-z0-9_]*-\d+\b")
STRIKE_RE = re.compile(r"~~\s*([A-Za-z]+)\s*~~")

# Below this ratio a fuzzy title match is refused outright. Calibrated against
# real title edits (0.72-1.00) and a probe row (0.45-0.47); 0.6 splits them.
FUZZY_ACCEPT = 0.6
# Purely a labelling split for the report: above this an accepted match is a
# stale anchor, below it the title was substantively edited. Both are accepted.
FUZZY_CONFIDENT = 0.85

GENERATED_HEADER = """# Known issues

**GENERATED — do not hand-edit.** This file is produced by
`known-issue.sh reindex` from the frontmatter of every file in
`docs/known-issues/`. Edit an entry there (or via `known-issue.sh add`,
`resolve`, or `severity`), then run `reindex` — or just run any of those
subcommands, which reindex for you. `known-issue.sh lint` fails if this file
ever drifts from what `reindex` would produce.

"""

TRAILING_NOTE = (
    "Severity is about blast radius if the thing goes wrong, not effort to "
    "fix. Anything resolved is rewritten in place with what was verified, "
    "rather than deleted — the history is often the useful part.\n"
)


# CommonMark allows EITHER backtick or tilde fences, closed only by a run of
# the SAME character at least as long as the one that opened it.
#
# The WRITE path goes through find_heading_indices; verify_migration_on_disk
# deliberately does NOT reuse it, or a defect in this one shared function
# would be invisible to the step that claims to catch exactly that.

def _leading_indent(line):
    """Column width of a line's leading whitespace, tabs expanded to the
    next multiple of 4 (CommonMark's tab-stop rule). Used only to decide
    whether a run of backticks/tildes is a fence delimiter at all — a
    fence requires 0-3 columns of indent; 4+ is CommonMark's INDENTED CODE
    BLOCK, which is inert literal text, not a delimiter, and must not
    open or close anything."""
    n = 0
    for c in line:
        if c == " ":
            n += 1
        elif c == "\t":
            n += 4 - (n % 4)
        else:
            break
    return n


def _fence_marker(line):
    """(char, run_length) if `line` is a CommonMark fence delimiter, else
    (None, 0). Only the leading run counts — CommonMark ignores anything
    after it on the opening line (e.g. an info string: '```python').

    A review once reproduced a bogus single-entry migration from
    a 4-space-INDENTED '```' with no closing fence anywhere in the
    document: the previous version of this function received an
    already-`.strip()`-ed line, so it could not see that the backticks
    were indented, treated it as a real unclosed fence opener, and every
    heading after it was swallowed as "inside a fence" through EOF. A
    fence delimiter is column-sensitive; stripping the line before
    looking at it throws away the one fact that decides whether it is a
    delimiter or plain text."""
    indent = _leading_indent(line)
    if indent > 3:
        return None, 0
    content = line.lstrip(" \t")
    for ch in ("`", "~"):
        if content.startswith(ch * 3):
            n = 0
            while n < len(content) and content[n] == ch:
                n += 1
            return ch, n
    return None, 0


def fence_state_per_line(lines):
    """states[i] is True if line i's own '## ' prefix (if any) must NOT count
    as a heading because it sits inside an open fence (or is itself a fence
    delimiter line, which can't start with '## ' anyway)."""
    states = []
    open_char = None
    open_len = 0
    for l in lines:
        ch, n = _fence_marker(l)
        if ch is not None:
            if open_char is None:
                open_char, open_len = ch, n
                states.append(True)
                continue
            if ch == open_char and n >= open_len:
                open_char, open_len = None, 0
                states.append(True)
                continue
            states.append(True)
            continue
        states.append(open_char is not None)
    return states


def find_heading_indices(lines):
    states = fence_state_per_line(lines)
    return [i for i, l in enumerate(lines)
            if l.startswith("## ") and not states[i]]


def find_heading_indices_independent(lines):
    """A second, DELIBERATELY differently-shaped implementation of the same
    rule, used only by verify_migration_on_disk to cross-check
    find_heading_indices against something that does not share its
    traversal, its state variables, or even its regex. find_heading_indices
    walks every line updating two scalars; this one instead locates every
    fence-marker LINE with a single regex pass over the whole joined text,
    resolves opens/closes only among those matches, materialises the
    resulting fenced LINE RANGES, and only then filters headings — a
    structurally unrelated path to the same answer. If the two ever
    disagree, verify_migration_on_disk treats that as a hard failure rather
    than trusting either, on the theory that a bug shaped like "only
    recognises one fence delimiter" is unlikely to be written identically
    twice by two different-shaped implementations.
    """
    text = "\n".join(lines)
    # 0-3 leading spaces only — CommonMark's bound on a fence delimiter. A
    # leading tab always reaches column 4+, so excluding \t keeps that true.
    marker_re = re.compile(r"^[ ]{0,3}(`{3,}|~{3,})[^\n]*$", re.MULTILINE)

    line_starts = [0]
    for l in lines:
        line_starts.append(line_starts[-1] + len(l) + 1)

    def line_of(offset):
        lo, hi = 0, len(lines) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if line_starts[mid] <= offset:
                lo = mid
            else:
                hi = mid - 1
        return lo

    fenced_spans = []
    open_line = None
    open_marker = None
    for m in marker_re.finditer(text):
        idx = line_of(m.start())
        marker = m.group(1)
        ch, n = marker[0], len(marker)
        if open_line is None:
            open_line, open_marker = idx, (ch, n)
        elif ch == open_marker[0] and n >= open_marker[1]:
            fenced_spans.append((open_line, idx))
            open_line, open_marker = None, None
    if open_line is not None:
        fenced_spans.append((open_line, len(lines) - 1))

    fenced = [False] * len(lines)
    for start, end in fenced_spans:
        for i in range(start, end + 1):
            fenced[i] = True

    return [i for i, l in enumerate(lines) if l.startswith("## ") and not fenced[i]]


_STACK_FENCE_RE = re.compile(r"^( {0,3})(`{3,}|~{3,})")


def find_heading_indices_stack(lines):
    """A THIRD oracle, used only by verify_migration_on_disk alongside the
    two above. find_heading_indices and find_heading_indices_independent
    differ in traversal shape (per-line scalar toggle vs. whole-text regex
    with span pairing) but, at one point shared the exact same
    underlying rule bug: neither bounded a fence delimiter's indent, so a
    4-space-indented '```' (CommonMark: an INDENTED CODE BLOCK, inert,
    never a delimiter) was accepted as a real unclosed fence opener by
    BOTH — and because both were wrong identically, they agreed with each
    other and no disagreement-based check caught it. Fixing the shared
    bug in both is necessary but does not by itself prevent that from
    happening again the same way; this function is deliberately a THIRD,
    differently-shaped implementation (a single explicit LIFO stack of
    open fences, walked with its own regex, never sharing code with
    either of the above) so that if the indent bound is ever dropped from
    both of the others at once, this one still disagrees with them rather
    than completing a false 3-way consensus.
    """
    stack = []
    out = []
    for i, l in enumerate(lines):
        m = _STACK_FENCE_RE.match(l)
        if m:
            ch, n = m.group(2)[0], len(m.group(2))
            if stack and stack[-1][0] == ch and n >= stack[-1][1]:
                stack.pop()
            elif not stack:
                stack.append((ch, n))
            continue
        if not stack and l.startswith("## "):
            out.append(i)
    return out


# A structurally different invariant, not a fourth vote: three implementations
# of ONE rule are not three independent opinions, so a fence opened at indent 3
# and "closed" at indent 4 is unanimously swallowed to EOF by all of them.
# This asks instead whether every fence recognised as OPENED also got a
# recognised CLOSE before EOF.

def find_unclosed_fence(lines):
    """1-based line number of the outermost fence opener with no valid
    closer before EOF, or None if every opened fence closes. Deliberately
    policy over disagreement: rather than trusting any scanner's fence-state
    output (all three encode the same acceptance rule and would happily
    report "no heading found here" for every line the unclosed fence
    swallows), this refuses outright whenever an opened fence never
    receives a same-character, run->=length, 0-3-indent closer — on the
    working assumption that for a curated doc like docs/known-issues.md, an
    unclosed-to-EOF fence is essentially always a typo (a closing line
    indented one space too many, a closer using the wrong character, a
    forgotten closer entirely) rather than an intentional multi-heading
    code block, and silently absorbing every heading after it is a worse
    failure than refusing and asking a human to fix the fence."""
    open_line = None
    open_char = None
    open_len = 0
    for i, l in enumerate(lines):
        ch, n = _fence_marker(l)
        if ch is None:
            continue
        if open_char is None:
            open_char, open_len, open_line = ch, n, i
        elif ch == open_char and n >= open_len:
            open_char, open_len, open_line = None, 0, None
    return (open_line + 1) if open_line is not None else None



def gh_slug(heading):
    h = heading.strip().lower()
    kept = [c for c in h if c.isalnum() or c in "-_ "]
    return "".join(kept).replace(" ", "-")


SLUG_RE = re.compile(r'^[a-z0-9]+(-[a-z0-9]+)*$')


def validate_slug_arg(slug):
    """Refuse anything make_slug() could not have produced (no '/', no
    '..', no leading/trailing/doubled hyphen) BEFORE it is joined into a
    path — the bash wrapper's valid_slug() is meant to gate this already,
    but this engine is the one thing that actually opens the file, and
    should not trust an argument it was invoked with directly (e.g. a
    future caller that shells out to this engine without going through the
    bash wrapper) to have already been checked."""
    if not SLUG_RE.match(slug):
        print("Error: %r is not a valid slug (want lowercase "
              "letters/digits/hyphens, no leading/trailing/doubled hyphen)"
              % slug, file=sys.stderr)
        return False
    return True


def make_slug(title, existing):
    s = title.strip().lower()
    s = re.sub(r"`", "", s)
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = s.strip("-")
    s = re.sub(r"-+", "-", s)
    if not s:
        s = "entry"
    base = s
    n = 2
    while s in existing:
        s = "%s-%d" % (base, n)
        n += 1
    existing.add(s)
    return s



def split_top_level(text):
    """Split on every top-level ' — ' (not inside parens). Returns a list of
    >=1 segments; a heading with no top-level ' — ' returns [heading] whole."""
    parts = []
    depth = 0
    start = 0
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif depth == 0 and text[i:i + 3] == " — ":
            parts.append(text[start:i])
            i += 3
            start = i
            continue
        i += 1
    parts.append(text[start:])
    return parts


def cleanup_qualifier(text):
    s = re.sub(r"\s+", " ", text).strip()
    s = re.sub(r"\(\s*\)", "", s).strip()
    s = s.strip(" ,;-")
    s = re.sub(r"\s+", " ", s).strip()
    if not s or re.fullmatch(r"[\s,;\-()]*", s):
        return None
    return s


def process_heading(heading):
    """Returns (title, severity, status, resolved, qualifiers). Every scrap
    of the heading suffix that isn't consumed as a recognised severity/status/
    date token is kept as a qualifier string, one per top-level segment — so
    '(was MEDIUM)', '(REPEAT)', and '(was MEDIUM, UNVERIFIED cause)' all
    survive structurally, not just inside heading_raw's verbatim backstop."""
    parts = split_top_level(heading)
    title = parts[0].strip()
    if len(parts) == 1:
        return title, None, "open", None, []

    severity = None
    status = "open"
    resolved = None
    qualifiers = []

    for seg in parts[1:]:
        work = seg
        seg_had_signal = False

        # Leftmost severity word wins — position, not a fixed priority list,
        # so 'HIGH (was MEDIUM)' keeps 'MEDIUM' as part of the qualifier
        # rather than a second pass mistaking it for the current severity.
        sev_re = re.compile(
            r"\b(" + "|".join(SEV_WORDS) + r")\b", re.IGNORECASE)
        m = sev_re.search(work)
        if m:
            seg_had_signal = True
            if severity is None:
                severity = SEV_NORM[m.group(1).upper()]
            work = work[:m.start()] + work[m.end():]

        m = re.search(r"\bRESOLVED\b", work, re.IGNORECASE)
        if m:
            seg_had_signal = True
            status = "resolved"
            work = work[:m.start()] + work[m.end():]
            dm = DATE_RE.search(work)
            if dm:
                resolved = dm.group(1)
                work = work[:dm.start()] + work[dm.end():]
        else:
            m = re.search(r"\bOPEN\b", work, re.IGNORECASE)
            if m:
                seg_had_signal = True
                work = work[:m.start()] + work[m.end():]
                dm = DATE_RE.search(work)
                if dm:
                    work = work[:dm.start()] + work[dm.end():]
            else:
                m = re.search(r"\bowner decision\b", work, re.IGNORECASE)
                if m:
                    seg_had_signal = True
                    status = "resolved"
                    dm = DATE_RE.search(work)
                    if dm:
                        resolved = dm.group(1)
                        work = work[:dm.start()] + work[dm.end():]

        cleaned = cleanup_qualifier(work)
        if cleaned:
            qualifiers.append(cleaned)
        elif not seg_had_signal:
            cleaned = cleanup_qualifier(seg)
            if cleaned:
                qualifiers.append(cleaned)

    return title, severity, status, resolved, qualifiers



def parse_sections(lines):
    idxs = find_heading_indices(lines)
    sections = []
    for n, idx in enumerate(idxs):
        heading = lines[idx][3:]
        end = idxs[n + 1] if n + 1 < len(idxs) else len(lines)
        body = lines[idx + 1:end]
        while body and body[0].strip() == "":
            body.pop(0)
        while body and body[-1].strip() == "":
            body.pop()
        title, sev, status, resolved, qualifiers = process_heading(heading)
        sections.append({
            "line": idx + 1,
            "heading": heading,
            "heading_raw": heading,
            "title": title,
            "body": body,
            "severity": sev,
            "status": status,
            "resolved": resolved,
            "qualifiers": qualifiers,
            "note": None,
        })
    return sections


def parse_index(lines):
    rows = []
    in_table = False
    row_re = re.compile(
        r"^\|\s*(?P<sev>[^|]+?)\s*\|\s*\[(?P<title>[^\]]+)\]\(#(?P<anchor>[^)]+)\)(?P<rest>.*)\|\s*$"
    )
    for l in lines:
        if l.startswith("| Severity"):
            in_table = True
            continue
        if not in_table:
            continue
        if not l.startswith("|"):
            break
        if re.match(r"^\|\s*-+\s*\|", l):
            continue
        m = row_re.match(l)
        if not m:
            continue
        rest = m.group("rest").strip()
        note = None
        if rest.startswith("—"):
            note = rest[1:].strip()
        elif rest:
            note = rest.strip(" —")
        rows.append({
            "sev_raw": m.group("sev").strip(),
            "title": m.group("title").strip(),
            "anchor": m.group("anchor").strip(),
            "note": note or None,
        })
    return rows


def index_row_severity(row):
    m = STRIKE_RE.search(row["sev_raw"])
    word = m.group(1).upper() if m else row["sev_raw"].strip().upper()
    return SEV_NORM.get(word)


def match_index_to_sections(sections, index_rows):
    """Greedy 1:1: exact gh_slug(heading)==anchor first, then the best fuzzy
    title match among unclaimed sections — but only if its ratio clears
    FUZZY_ACCEPT. Below that, the row is left UNMATCHED (migration then
    fails loudly on it) rather than silently attached to a coin-flip
    candidate. Returns (unmatched_rows, title_warnings, status_warnings,
    ratio_report) — ratio_report lists every accepted fuzzy match with its
    score, split into confident vs needs-a-look, for the report.
    """
    slugs = [gh_slug(s["heading"]) for s in sections]
    used = set()
    title_warnings = []
    status_warnings = []
    ratio_report = []
    unmatched_rows = []

    for row in index_rows:
        match_idx = None
        exact = False
        for i, sl in enumerate(slugs):
            if sl == row["anchor"] and i not in used:
                match_idx = i
                exact = True
                break
        ratio = None
        if match_idx is None:
            best_ratio, best_i = -1.0, None
            norm_row = re.sub(r"`", "", row["title"]).lower()
            for i, s in enumerate(sections):
                if i in used:
                    continue
                norm_sec = re.sub(r"`", "", s["title"]).lower()
                r = difflib.SequenceMatcher(None, norm_row, norm_sec).ratio()
                if r > best_ratio:
                    best_ratio, best_i = r, i
            if best_ratio >= FUZZY_ACCEPT:
                match_idx = best_i
                ratio = best_ratio
        if match_idx is None:
            unmatched_rows.append(row)
            continue
        used.add(match_idx)
        sec = sections[match_idx]
        if not exact:
            confidence = "confident" if ratio >= FUZZY_CONFIDENT else "needs review"
            ratio_report.append(
                "%.2f (%s): index title %r (anchor #%s) -> entry %r at line %d"
                % (ratio, confidence, row["title"], row["anchor"],
                   sec["heading"], sec["line"])
            )
            if slugs[match_idx] != row["anchor"]:
                title_warnings.append(
                    "title/anchor mismatch: index title %r (anchor #%s) "
                    "matched to current heading %r at line %d (ratio %.2f) "
                    "— the title was edited after the anchor was set" % (
                        row["title"], row["anchor"], sec["heading"],
                        sec["line"], ratio)
                )
        sec["note"] = row["note"]
        if sec["severity"] is None:
            sev = index_row_severity(row)
            if sev:
                sec["severity"] = sev
        if "RESOLVED" in row["sev_raw"].upper() and sec["status"] != "resolved":
            status_warnings.append(
                "status disagreement for %r: the entry's own heading (line "
                "%d) does not say RESOLVED, but the index row marks it "
                "%r — kept 'open' from the heading (the heading/body prose "
                "read as still-active); verify by hand and use "
                "`known-issue.sh resolve <slug>` if it is actually fixed" % (
                    sec["title"], sec["line"], row["sev_raw"])
            )

    return unmatched_rows, title_warnings, status_warnings, ratio_report


def find_missing_severity(sections):
    """Sections with no severity from ANY source (heading, matched index
    row). Deliberately does NOT guess: an owner audit of the real doc found
    6 such headings, 5 of which are genuine entries the index table simply
    never listed and 1 of which is not — "missing from the index" cannot
    tell those apart, so there is no heuristic here to get wrong. The
    caller decides whether to refuse (default) or default them to LOW under
    --accept-severity-defaults, explicitly, once, out loud."""
    return [s for s in sections if s["severity"] is None]


def apply_severity_defaults(missing):
    """Only called once the caller has confirmed --accept-severity-defaults.
    Defaults every section in `missing` to LOW and returns one warning line
    per section, naming the fix-up command."""
    warnings = []
    for s in missing:
        s["severity"] = "LOW"
        warnings.append(
            "line %d: %r — no severity found anywhere (heading or a "
            "matched index row); defaulted to LOW because "
            "--accept-severity-defaults was given. Review with "
            "`known-issue.sh severity %s <SEV>`." % (
                s["line"], s["heading"], s["slug"])
        )
    return warnings


def extract_tickets(heading, body):
    text = heading + "\n" + "\n".join(body)
    return sorted(set(TICKET_RE.findall(text)))



def esc(s):
    # Order matters: backslash first, so a real backslash is not re-escaped by
    # the later steps. The newline case is load-bearing — FM_LINE_RE is
    # line-based, so an unescaped newline splits a field and breaks every
    # later read of the whole corpus.
    return (s.replace("\\", "\\\\")
             .replace('"', '\\"')
             .replace("\n", "\\n"))


def unesc(s):
    # Reverse of esc(), in reverse order: undo the last transform first.
    return (s.replace("\\n", "\n")
             .replace('\\"', '"')
             .replace("\\\\", "\\"))


def dump_list(items):
    return "[%s]" % ", ".join('"%s"' % esc(i) for i in items)


LIST_ITEM_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')


def parse_list(val):
    inner = val.strip()
    if inner.startswith("[") and inner.endswith("]"):
        inner = inner[1:-1]
    return [unesc(m) for m in LIST_ITEM_RE.findall(inner)]


FRONTMATTER_FIELDS = ["title", "heading_raw", "severity", "status",
                       "resolved", "qualifiers", "note", "tickets", "slug"]


def dump_entry(meta, body_lines):
    out = ["---"]
    out.append('title: "%s"' % esc(meta["title"]))
    out.append('heading_raw: "%s"' % esc(meta["heading_raw"]))
    out.append("severity: %s" % meta["severity"])
    out.append("status: %s" % meta["status"])
    if meta["status"] == "resolved" and meta.get("resolved"):
        out.append("resolved: %s" % meta["resolved"])
    out.append("qualifiers: %s" % dump_list(meta.get("qualifiers") or []))
    if meta.get("note"):
        out.append('note: "%s"' % esc(meta["note"]))
    out.append("tickets: %s" % dump_list(meta.get("tickets") or []))
    out.append("slug: %s" % meta["slug"])
    out.append("---")
    text = "\n".join(out) + "\n"
    if body_lines:
        text += "\n" + "\n".join(body_lines) + "\n"
    return text


FM_LINE_RE = re.compile(r'^(?P<key>[a-z_]+):\s*(?P<val>.*)$')


def load_entry(path):
    with open(path) as fh:
        text = fh.read()
    if not text.startswith("---\n"):
        raise ValueError("%s: missing frontmatter opening ---" % path)
    end = text.find("\n---", 4)
    if end == -1:
        raise ValueError("%s: missing frontmatter closing ---" % path)
    fm_text = text[4:end]
    rest = text[end + 4:]
    if rest.startswith("\n"):
        rest = rest[1:]
    body_lines = rest.split("\n")
    while body_lines and body_lines[0] == "":
        body_lines.pop(0)
    while body_lines and body_lines[-1] == "":
        body_lines.pop()
    meta = {"tickets": [], "qualifiers": []}
    for line in fm_text.split("\n"):
        if not line.strip():
            continue
        m = FM_LINE_RE.match(line)
        if not m:
            raise ValueError("%s: unparsable frontmatter line: %r" % (path, line))
        key, val = m.group("key"), m.group("val")
        if key in ("title", "note", "heading_raw"):
            if val.startswith('"') and val.endswith('"') and len(val) >= 2:
                val = unesc(val[1:-1])
            meta[key] = val
        elif key in ("tickets", "qualifiers"):
            meta[key] = parse_list(val)
        else:
            meta[key] = val
    for req in ("title", "heading_raw", "severity", "status", "slug"):
        if req not in meta:
            raise ValueError("%s: missing required frontmatter field %r" % (path, req))
    if meta["severity"] not in SEV_ORDER:
        raise ValueError("%s: invalid severity %r" % (path, meta["severity"]))
    if meta["status"] not in ("open", "resolved"):
        raise ValueError("%s: invalid status %r" % (path, meta["status"]))
    return meta, body_lines



def md_pipe_escape(s):
    # A literal '|' ends a table cell early and shifts every following cell;
    # an embedded newline splits the row outright, since load_entry() hands
    # build_index the UNESCAPED string. Both are structural breaks that
    # lint's build_index-based check structurally cannot see.
    return s.replace("|", "\\|").replace("\n", " ")


def build_index(entries):
    def sort_key(e):
        meta = e[0]
        sev_rank = SEV_ORDER.index(meta["severity"])
        status_rank = 0 if meta["status"] == "open" else 1
        return (sev_rank, status_rank, meta["title"].lower())

    rows = []
    for meta, relpath in sorted(entries, key=sort_key):
        sev_cell = meta["severity"] if meta["status"] == "open" else (
            "~~%s~~ RESOLVED" % meta["severity"])
        title_cell = md_pipe_escape(meta["title"])
        link = "[%s](%s)" % (title_cell, md_pipe_escape(relpath))
        if meta.get("note"):
            row = "| %s | %s — %s |" % (sev_cell, link, md_pipe_escape(meta["note"]))
        else:
            row = "| %s | %s |" % (sev_cell, link)
        rows.append(row)

    out = [GENERATED_HEADER.rstrip("\n")]
    out.append("")
    out.append("| Severity | Finding |")
    out.append("| --- | --- |")
    out.extend(rows)
    out.append("")
    out.append(TRAILING_NOTE.rstrip("\n"))
    return "\n".join(out) + "\n"


def load_all_entries(entries_dir):
    entries = []
    slugs_seen = {}
    for name in sorted(os.listdir(entries_dir)):
        if not name.endswith(".md"):
            continue
        path = os.path.join(entries_dir, name)
        meta, body = load_entry(path)
        expected_slug = name[:-3]
        if meta["slug"] != expected_slug:
            raise ValueError(
                "%s: slug field %r does not match filename" % (path, meta["slug"]))
        if expected_slug in slugs_seen:
            raise ValueError("duplicate slug %r (%s and %s)" % (
                expected_slug, slugs_seen[expected_slug], path))
        slugs_seen[expected_slug] = path
        entries.append((meta, body, "known-issues/%s.md" % expected_slug, path))
    return entries


def load_all_entries_safe(entries_dir):
    """Same as load_all_entries but never raises — callers that are not
    already inside a try/except (reindex/add/resolve/severity) get the
    tool's own 'Error: ...' presentation instead of a raw traceback."""
    try:
        return load_all_entries(entries_dir), None
    except ValueError as e:
        return None, str(e)


# post-write verification
#
# Reads everything FRESH from disk — the source again, and every staged file —
# rather than the in-memory `sections` that decided what to write, so a bug in
# the WRITE step cannot validate itself.

def verify_migration_on_disk(source_path, staging_dir):
    failures = []

    with open(source_path) as fh:
        fresh_text = fh.read()
    fresh_lines = fresh_text.split("\n")

    # cmd_migrate already refuses on an unclosed fence, but this function's
    # premise is trusting nothing except a fresh re-read from disk.
    unclosed_line = find_unclosed_fence(fresh_lines)
    if unclosed_line is not None:
        return [
            "unclosed fenced code block starting at line %d in a fresh "
            "re-read of %s — no closing delimiter was found before EOF; "
            "every heading after it would be silently swallowed. Refusing "
            "to trust any heading count derived from this file." % (
                unclosed_line, source_path)
        ]

    # Cross-check against a structurally independent implementation: reusing
    # the function the write path trusted would hide a defect in its shape.
    fresh_idxs = find_heading_indices(fresh_lines)
    fresh_idxs_cross = find_heading_indices_independent(fresh_lines)
    fresh_idxs_stack = find_heading_indices_stack(fresh_lines)
    scanners = [
        ("find_heading_indices", fresh_idxs),
        ("find_heading_indices_independent", fresh_idxs_cross),
        ("find_heading_indices_stack", fresh_idxs_stack),
    ]
    if not (fresh_idxs == fresh_idxs_cross == fresh_idxs_stack):
        disagreement = []
        for i, (name_a, idxs_a) in enumerate(scanners):
            for name_b, idxs_b in scanners[i + 1:]:
                only_a = sorted(x + 1 for x in set(idxs_a) - set(idxs_b))
                only_b = sorted(x + 1 for x in set(idxs_b) - set(idxs_a))
                if only_a or only_b:
                    disagreement.append(
                        "%s claims a heading at 1-based line(s) %r that %s "
                        "does not; the reverse is true for line(s) %r" % (
                            name_a, only_a, name_b, only_b))
        return [
            "heading-detection cross-check disagreement among all three "
            "independent scanners — refusing to trust any of them. Fix the "
            "disagreement before migrating."
        ] + disagreement

    if not fresh_idxs:
        return ["no '## ' headings found outside fenced code in %s" % source_path]
    fresh_heading_lines = [fresh_lines[i] for i in fresh_idxs]

    staged_names = sorted(f for f in os.listdir(staging_dir) if f.endswith(".md"))
    staged = []
    for name in staged_names:
        try:
            meta, body = load_entry(os.path.join(staging_dir, name))
        except ValueError as e:
            failures.append("could not read back staged entry %s: %s" % (name, e))
            continue
        staged.append((meta, body))

    # CHECK A — count from two independent sources: a fresh, fence-aware
    # re-scan of the source, versus a directory listing of what actually
    # landed on disk.
    if len(fresh_idxs) != len(staged_names):
        failures.append(
            "count mismatch: %d headings in a fresh fence-aware re-scan of "
            "%s, but %d entry files on disk in %s" % (
                len(fresh_idxs), source_path, len(staged_names), staging_dir)
        )

    # CHECK B — every fresh heading recoverable byte-for-byte from EXACTLY one
    # staged file, and no staged heading_raw the re-scan does not recognise
    # (that half catches a phantom entry from a false-positive heading).
    import collections
    ground_truth = collections.Counter(fresh_heading_lines)
    staged_headings = collections.Counter("## " + m["heading_raw"] for m, b in staged)
    missing = ground_truth - staged_headings
    phantom = staged_headings - ground_truth
    for line, n in missing.items():
        failures.append("heading not recoverable from any entry file (x%d): %r" % (n, line))
    for line, n in phantom.items():
        failures.append(
            "entry file carries a heading_raw that a fresh, fence-aware "
            "re-scan of the source does not recognise as a real heading "
            "(x%d): %r — likely a false-positive heading (e.g. inside a "
            "fenced code block)" % (n, line)
        )

    # CHECK D — ordered, byte-level reconstruction of non-blank lines from the
    # first heading to EOF. Stronger than a multiset diff: it also catches
    # content reordered or reattached between neighbouring entries.
    if not failures:
        by_heading_raw = {}
        for m, b in staged:
            by_heading_raw.setdefault(m["heading_raw"], []).append((m, b))
        reconstructed = []
        for i in fresh_idxs:
            h = fresh_lines[i][3:]
            bucket = by_heading_raw.get(h)
            if not bucket:
                failures.append("internal: no staged entry left for heading %r "
                                 "during reconstruction" % h)
                break
            m, b = bucket.pop(0)
            reconstructed.append("## " + m["heading_raw"])
            reconstructed.extend(b)
        if not failures:
            recon_nonblank = [l for l in reconstructed if l.strip() != ""]
            orig_nonblank = [l for l in fresh_lines[fresh_idxs[0]:] if l.strip() != ""]
            if recon_nonblank != orig_nonblank:
                sm = difflib.SequenceMatcher(None, orig_nonblank, recon_nonblank)
                for tag, i1, i2, j1, j2 in sm.get_opcodes():
                    if tag == "equal":
                        continue
                    failures.append(
                        "reconstruction mismatch (%s): original lines %r "
                        "vs migrated lines %r" % (
                            tag, orig_nonblank[i1:i2][:5], recon_nonblank[j1:j2][:5])
                    )
                    if len(failures) > 60:
                        break

    # CHECK E — index coverage, re-derived fresh (independent of whatever the
    # write step used to decide notes/severity).
    fresh_index_rows = parse_index(fresh_lines)
    for row in fresh_index_rows:
        if row.get("note") is None:
            continue
        if not any(m.get("note") == row["note"] for m, b in staged):
            failures.append("note lost for index row %r: %r" % (
                row["title"], row["note"]))

    return failures



def cmd_migrate(args):
    dest_exists = os.path.isdir(args.entries_dir) and os.listdir(args.entries_dir)
    if dest_exists and not args.force:
        print("Error: %s already exists and is not empty (use --force to "
              "overwrite)" % args.entries_dir, file=sys.stderr)
        return 1

    with open(args.source) as fh:
        src_text = fh.read()
    src_lines = src_text.split("\n")

    # Must run on the same src_lines parse_sections is about to walk: an
    # unclosed-to-EOF fence changes what it sees as headings at all.
    unclosed_line = find_unclosed_fence(src_lines)
    if unclosed_line is not None:
        print("Error: unclosed fenced code block starting at line %d in %s "
              "— no closing delimiter (same character, run length >= the "
              "opener's, indented 0-3 columns) was found before EOF. Every "
              "heading after this point would be silently swallowed into "
              "whichever entry precedes it. Fix the fence (a common cause: "
              "the closing line is indented one column more or less than "
              "required) before migrating." % (unclosed_line, args.source),
              file=sys.stderr)
        return 1

    sections = parse_sections(src_lines)
    if not sections:
        # --source and --index-file are the SAME path, so a successful migrate
        # overwrites the only thing a later migrate could read. Gets its own
        # message rather than a generic "no headings" error.
        if "GENERATED — do not hand-edit" in src_text:
            print("Error: %s is already the GENERATED index (produced by a "
                  "previous migrate or reindex) — there is no hand-written "
                  "content left to split. --force will not help here: it "
                  "protects entries from being clobbered, but it cannot "
                  "invent a source that no longer exists. If you meant to "
                  "redo the original one-shot split, restore the "
                  "pre-migration content of %s first (e.g. `git checkout "
                  "<commit-before-the-first-migrate> -- %s`), then re-run "
                  "migrate --force." % (args.source, args.source, args.source),
                  file=sys.stderr)
        else:
            print("Error: no '## ' headings found outside fenced code in %s" %
                  args.source, file=sys.stderr)
        return 1

    existing_slugs = set()
    for s in sections:
        s["slug"] = make_slug(s["title"], existing_slugs)
        s["tickets"] = extract_tickets(s["heading"], s["body"])

    if dest_exists and args.force:
        # A body-text edit round-trips through load+dump fine, so "survives its
        # own parser" proves nothing about whether content changed. The
        # manifest's per-slug sha256 is the only reference to what the tool
        # itself last wrote; no manifest at all is refused, not guessed at.
        manifest = load_manifest(args.entries_dir)
        if manifest is None:
            print("Error: --force refused: no %s found under %s, so there is "
                  "no record of what this tool last wrote — cannot tell a "
                  "hand-edited entry from an untouched one. Remove the "
                  "directory yourself if you are certain it is safe to "
                  "replace, then re-run without needing --force." % (
                      MANIFEST_NAME, args.entries_dir), file=sys.stderr)
            return 1
        entries, err = load_all_entries_safe(args.entries_dir)
        if err is not None:
            print("Error: --force refused: %s could not be read back to "
                  "check for hand edits (%s) — inspect it by hand before "
                  "retrying" % (args.entries_dir, err), file=sys.stderr)
            return 1
        fresh_slugs = {s["slug"] for s in sections}
        dirty = []
        orphaned = []
        present_slugs = set()
        for meta, body, relpath, path in entries:
            present_slugs.add(meta["slug"])
            recorded = manifest.get(meta["slug"])
            current = file_hash(path)
            if recorded is None or recorded != current:
                dirty.append(path)
            elif meta["slug"] not in fresh_slugs:
                # Untouched since written, but this run would not recreate it
                # — e.g. an entry made with `add`. Replacing the directory drops it.
                orphaned.append(path)
        # A manifest key with NO file on disk is a deliberately deleted entry.
        # The loop above only looks at files that EXIST, so it structurally
        # cannot see this case, and --force would silently resurrect it.
        deleted = sorted(
            os.path.join(args.entries_dir, slug + ".md")
            for slug in manifest
            if slug not in present_slugs
        )
        if deleted:
            print("Error: --force refused: %d slug(s) recorded in %s have no "
                  "file on disk under %s — deleted since this tool last "
                  "wrote them. Replacing the directory would silently bring "
                  "them back from the source. If the deletion was "
                  "intentional, remove the corresponding key(s) from %s by "
                  "hand first; if it was not, something else deleted these "
                  "files and needs investigating before --force is safe. "
                  "Affected slug(s):" % (
                      len(deleted), MANIFEST_NAME, args.entries_dir,
                      manifest_path(args.entries_dir)), file=sys.stderr)
            for p in deleted:
                print("  - " + p, file=sys.stderr)
            return 1
        if dirty:
            print("Error: --force refused: %d entry file(s) under %s do not "
                  "match the recorded checksum of what this tool last wrote "
                  "there — something touched them since (a hand edit, a "
                  "stale git checkout, a merge). Overwriting would silently "
                  "discard that. Affected files:" % (
                      len(dirty), args.entries_dir), file=sys.stderr)
            for p in dirty:
                print("  - " + p, file=sys.stderr)
            print("Resolve those by hand (or move them aside) before "
                  "re-running --force.", file=sys.stderr)
            return 1
        if orphaned:
            print("Error: --force refused: %d entry file(s) under %s are "
                  "untouched since they were written, but this migrate run "
                  "of %s would not recreate them (they are not one of its "
                  "headings) — replacing the directory would silently "
                  "delete them. Move them aside first if that is really "
                  "intended:" % (len(orphaned), args.entries_dir, args.source),
                  file=sys.stderr)
            for p in orphaned:
                print("  - " + p, file=sys.stderr)
            return 1

    index_rows = parse_index(src_lines)
    unmatched_rows, mismatch_warnings, status_warnings, ratio_report = \
        match_index_to_sections(sections, index_rows)

    pre_failures = []
    for r in unmatched_rows:
        pre_failures.append(
            "index row could not be matched to any entry with confidence "
            ">= %.2f: %r (anchor #%s) — its note would be lost; if this is "
            "a genuine entry, fix its heading or the index row by hand "
            "first" % (FUZZY_ACCEPT, r["title"], r["anchor"]))

    # Missing severity is never guessed: "missing from the index" does not
    # discriminate a genuine unlisted entry from a non-entry, and defaulting
    # silently is how a HIGH finding becomes a LOW one.
    missing_severity = find_missing_severity(sections)
    default_warnings = []
    if missing_severity and not args.accept_severity_defaults:
        pre_failures.append(
            "%d heading(s) have no severity anywhere (not in the heading, "
            "not in a matched index row) and --accept-severity-defaults was "
            "not given — refusing to guess:" % len(missing_severity))
        for s in missing_severity:
            pre_failures.append(
                "  line %d: %r" % (s["line"], s["heading"]))
        pre_failures.append(
            "Either give each of these an explicit severity in its heading "
            "or a matching index row, or re-run with "
            "--accept-severity-defaults to default them all to LOW (and "
            "fix them up afterwards with `known-issue.sh severity`)."
        )
    elif missing_severity:
        default_warnings = apply_severity_defaults(missing_severity)

    if pre_failures:
        print("MIGRATION VERIFICATION FAILED — nothing written.\n", file=sys.stderr)
        for f in pre_failures:
            print(" - " + f, file=sys.stderr)
        return 1

    staging = tempfile.mkdtemp(prefix="known-issue-migrate-")
    try:
        entries_for_index = []
        for s in sections:
            meta = {
                "title": s["title"], "heading_raw": s["heading_raw"],
                "severity": s["severity"], "status": s["status"],
                "resolved": s["resolved"], "qualifiers": s["qualifiers"],
                "note": s["note"], "tickets": s["tickets"], "slug": s["slug"],
            }
            path = os.path.join(staging, s["slug"] + ".md")
            with open(path, "w") as fh:
                fh.write(dump_entry(meta, s["body"]))
            entries_for_index.append((meta, "known-issues/%s.md" % s["slug"]))

        failures = verify_migration_on_disk(args.source, staging)
        if failures:
            print("MIGRATION VERIFICATION FAILED — nothing written.\n", file=sys.stderr)
            for f in failures:
                print(" - " + f, file=sys.stderr)
            return 1

        index_text = build_index(entries_for_index)

        if os.path.isdir(args.entries_dir):
            shutil.rmtree(args.entries_dir)
        shutil.move(staging, args.entries_dir)
        staging = None  # moved; do not clean up below

        manifest = {}
        for s in sections:
            manifest[s["slug"]] = file_hash(
                os.path.join(args.entries_dir, s["slug"] + ".md"))
        save_manifest(args.entries_dir, manifest)

        with open(args.index_file, "w") as fh:
            fh.write(index_text)
    finally:
        if staging is not None and os.path.isdir(staging):
            shutil.rmtree(staging)

    print("Migration OK.")
    print("  entries written: %d" % len(sections))
    print("  index rows matched: %d/%d" % (
        len(index_rows) - len(unmatched_rows), len(index_rows)))
    if ratio_report:
        print("\nFuzzy title matches accepted (ratio, confidence):")
        for w in ratio_report:
            print("  - " + w)
    if mismatch_warnings:
        print("\nTitle/anchor mismatches (title was edited after the anchor "
              "was generated — informational, not blocking):")
        for w in mismatch_warnings:
            print("  - " + w)
    if status_warnings:
        print("\nStatus disagreements between the heading and the stale "
              "index (kept the heading's status; review by hand):")
        for w in status_warnings:
            print("  - " + w)
    if default_warnings:
        print("\nSeverity backfilled from context — review these:")
        for w in default_warnings:
            print("  - " + w)
    return 0


def cmd_reindex(args):
    entries, err = load_all_entries_safe(args.entries_dir)
    if err is not None:
        print("Error: " + err, file=sys.stderr)
        return 1
    index_entries = [(meta, relpath) for meta, body, relpath, path in entries]
    with open(args.index_file, "w") as fh:
        fh.write(build_index(index_entries))
    print("Reindexed %d entries into %s" % (len(entries), args.index_file))
    return 0


def cmd_remanifest(args):
    """Re-record the sha256 of named entries, or drop named records whose
    file is gone. The only supported way back to a green lint once an entry
    has drifted; acceptance is per-slug and printed, never blanket, and it
    is all-or-nothing so a bad slug writes nothing."""
    manifest = load_manifest(args.entries_dir)
    if manifest is None:
        manifest = {}
    slugs = args.slug
    dupes = sorted({x for x in slugs if slugs.count(x) > 1})
    if dupes:
        print("Error: slug named more than once: %s" % ", ".join(dupes),
              file=sys.stderr)
        return 1

    mpath = manifest_path(args.entries_dir)
    errors, actions = [], []
    for slug in slugs:
        path = os.path.join(args.entries_dir, slug + ".md")
        exists = os.path.isfile(path)
        if args.drop:
            if exists:
                errors.append(
                    "%s still exists — --drop removes the record of a file "
                    "that is GONE. Re-record it instead, without --drop."
                    % path)
            elif slug not in manifest:
                errors.append("%s is not recorded in %s — nothing to drop"
                              % (slug, mpath))
            else:
                actions.append((slug, manifest[slug], None))
        elif not exists:
            errors.append(
                "%s does not exist — if the entry is gone on purpose, drop "
                "its record with --drop" % path)
        else:
            actions.append((slug, manifest.get(slug), file_hash(path)))

    if errors:
        print("Error:", file=sys.stderr)
        for e in errors:
            print(" - " + e, file=sys.stderr)
        return 1

    changed = 0
    for slug, old, new in actions:
        if new is None:
            del manifest[slug]
            print("dropped  %s (was %s)" % (slug, old))
            changed += 1
        elif old == new:
            print("current  %s (%s) — already recorded, nothing to accept"
                  % (slug, new))
        else:
            manifest[slug] = new
            print("recorded %s\n            was %s\n            now %s"
                  % (slug, old if old else "(never recorded)", new))
            changed += 1

    if changed:
        save_manifest(args.entries_dir, manifest)
        print("%s: %d record(s) changed" % (mpath, changed))
    else:
        print("%s: no change" % mpath)

    # Accepting a hash and regenerating the index are separate acts, so this
    # says the index is stale rather than quietly fixing it.
    entries, err = load_all_entries_safe(args.entries_dir)
    if err is None and entries:
        expected = build_index(
            [(meta, relpath) for meta, body, relpath, path in entries])
        actual = None
        if os.path.exists(args.index_file):
            with open(args.index_file) as fh:
                actual = fh.read()
        if actual != expected:
            print("note: %s is not what `reindex` would produce — run "
                  "`known-issue.sh reindex`" % args.index_file)
    return 0


def cmd_lint(args):
    entries, err = load_all_entries_safe(args.entries_dir)
    if err is not None:
        print("Error: " + err, file=sys.stderr)
        return 1
    if not entries:
        print("Error: no entries found in %s" % args.entries_dir, file=sys.stderr)
        return 1
    manifest_errors = check_manifest(args.entries_dir, entries)
    if manifest_errors:
        print("LINT FAILED:", file=sys.stderr)
        for e in manifest_errors:
            print(" - " + e, file=sys.stderr)
        return 1
    index_entries = [(meta, relpath) for meta, body, relpath, path in entries]
    expected = build_index(index_entries)
    actual = None
    if os.path.exists(args.index_file):
        with open(args.index_file) as fh:
            actual = fh.read()
    if actual != expected:
        print("LINT FAILED:", file=sys.stderr)
        print(" - %s is not what `reindex` would produce — run "
              "`known-issue.sh reindex`" % args.index_file, file=sys.stderr)
        return 1
    # Independent of build_index: "actual == expected" only confirms the index
    # agrees with itself. This scans the on-disk text directly, so it catches
    # a rendering defect comparison-against-itself structurally cannot.
    shape_errors = lint_index_row_shapes(actual)
    if shape_errors:
        print("LINT FAILED:", file=sys.stderr)
        for e in shape_errors:
            print(" - " + e, file=sys.stderr)
        return 1
    print("OK: %d entries, index up to date." % len(entries))
    return 0


def lint_index_row_shapes(index_text):
    """Independent structural check: every markdown table DATA row in
    index_text must have exactly 3 unescaped '|' delimiters (a 2-column
    table: | severity | finding |). Does not call build_index or any of
    its helpers — an unescaped '|' inside a title/note cell would silently
    shift a row's column count, and this is the check able to notice that
    even if the code that rendered the row is itself the buggy code."""
    errors = []
    in_table = False
    for lineno, line in enumerate(index_text.split("\n"), start=1):
        if line.startswith("| Severity | Finding |"):
            in_table = True
            continue
        if in_table and re.match(r'^\|\s*-+\s*\|\s*-+\s*\|$', line):
            continue  # the header separator row
        if in_table and line.startswith("|"):
            unescaped_pipes = len(re.findall(r'(?<!\\)\|', line))
            if unescaped_pipes != 3:
                errors.append(
                    "index line %d has %d unescaped '|' delimiters, expected 3 "
                    "(a title or note likely contains an unescaped '|'): %r"
                    % (lineno, unescaped_pipes, line))
        elif in_table and line == "":
            in_table = False
    return errors


def write_entry_verified(entries_dir, slug, path, meta, body_lines):
    """Write an entry, then immediately re-parse it FROM DISK with the
    same load_entry() any later lint/reindex/add call would use — never
    trust that a write which didn't raise produced a file the rest of this
    tool can actually read back. A dump_entry bug (escaping, field
    ordering, anything) would otherwise land on disk, get manifest-recorded
    via record_written, and only surface on the NEXT unrelated invocation
    of this tool, as a hard failure against a file nobody suspects. On
    failure, the bad file is removed (nothing was recorded, nothing is left
    behind to explain) and the caller reports the error and returns
    non-zero without calling record_written or cmd_reindex.
    Returns True on success, False (with an error already printed) on
    failure."""
    with open(path, "w") as fh:
        fh.write(dump_entry(meta, body_lines))
    try:
        load_entry(path)
    except ValueError as e:
        try:
            os.remove(path)
        except OSError:
            pass
        print("Error: wrote %s but could not read it back (%s) — removed it, "
              "nothing recorded" % (path, e), file=sys.stderr)
        return False
    record_written(entries_dir, slug, path)
    return True


def cmd_add(args):
    existing_slugs = set()
    if os.path.isdir(args.entries_dir):
        existing_slugs = {n[:-3] for n in os.listdir(args.entries_dir) if n.endswith(".md")}
    slug = make_slug(args.title, existing_slugs)
    with open(args.body_file) as fh:
        body_lines = fh.read().split("\n")
    while body_lines and body_lines[0] == "":
        body_lines.pop(0)
    while body_lines and body_lines[-1] == "":
        body_lines.pop()
    meta = {
        "title": args.title,
        "heading_raw": "%s — %s" % (args.title, args.severity),
        "severity": args.severity,
        "status": "open",
        "qualifiers": [],
        "note": args.note,
        "tickets": args.tickets.split(",") if args.tickets else [],
        "slug": slug,
    }
    os.makedirs(args.entries_dir, exist_ok=True)
    path = os.path.join(args.entries_dir, slug + ".md")
    if not write_entry_verified(args.entries_dir, slug, path, meta, body_lines):
        return 1
    print("Wrote %s" % path)
    return cmd_reindex(args)


def cmd_resolve(args):
    if not validate_slug_arg(args.slug):
        return 1
    path = os.path.join(args.entries_dir, args.slug + ".md")
    if not os.path.exists(path):
        print("Error: no such entry %r" % args.slug, file=sys.stderr)
        return 1
    try:
        meta, body = load_entry(path)
    except ValueError as e:
        print("Error: " + str(e), file=sys.stderr)
        return 1
    meta["status"] = "resolved"
    meta["resolved"] = args.date
    if args.note:
        meta["note"] = args.note
    if not write_entry_verified(args.entries_dir, args.slug, path, meta, body):
        return 1
    print("Resolved %s (%s)" % (args.slug, args.date))
    return cmd_reindex(args)


def cmd_severity(args):
    if not validate_slug_arg(args.slug):
        return 1
    path = os.path.join(args.entries_dir, args.slug + ".md")
    if not os.path.exists(path):
        print("Error: no such entry %r" % args.slug, file=sys.stderr)
        return 1
    try:
        meta, body = load_entry(path)
    except ValueError as e:
        print("Error: " + str(e), file=sys.stderr)
        return 1
    meta["severity"] = args.severity
    if not write_entry_verified(args.entries_dir, args.slug, path, meta, body):
        return 1
    print("%s severity now %s" % (args.slug, args.severity))
    return cmd_reindex(args)


def main():
    p = argparse.ArgumentParser(prog="known-issue-engine")
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--entries-dir", required=True)
        sp.add_argument("--index-file", required=True)

    m = sub.add_parser("migrate")
    common(m)
    m.add_argument("--source", required=True)
    m.add_argument("--force", action="store_true")
    m.add_argument("--accept-severity-defaults", action="store_true")

    common(sub.add_parser("reindex"))
    common(sub.add_parser("lint"))

    a = sub.add_parser("add")
    common(a)
    a.add_argument("--title", required=True)
    a.add_argument("--severity", required=True, choices=SEV_ORDER)
    a.add_argument("--note")
    a.add_argument("--tickets")
    a.add_argument("--body-file", required=True)

    r = sub.add_parser("resolve")
    common(r)
    r.add_argument("--slug", required=True)
    r.add_argument("--date", required=True)
    r.add_argument("--note")

    s = sub.add_parser("severity")
    common(s)
    s.add_argument("--slug", required=True)
    s.add_argument("--severity", required=True, choices=SEV_ORDER)

    rm = sub.add_parser("remanifest")
    common(rm)
    rm.add_argument("--slug", action="append", required=True)
    rm.add_argument("--drop", action="store_true")

    args = p.parse_args()
    fn = {
        "migrate": cmd_migrate, "reindex": cmd_reindex, "lint": cmd_lint,
        "add": cmd_add, "resolve": cmd_resolve, "severity": cmd_severity,
        "remanifest": cmd_remanifest,
    }[args.cmd]
    return fn(args)


if __name__ == "__main__":
    sys.exit(main())
PYEOF

run_engine() {
    python3 "$ENGINE" "$@"
}


usage_migrate() {
    cat <<EOF
Usage: known-issue.sh migrate [--force] [--accept-severity-defaults]

ONE-SHOT. Parses the current docs/known-issues.md (hand-written prose plus a
hand-maintained index table) and splits it into one file per entry under
docs/known-issues/, then regenerates docs/known-issues.md as the index.

Heading detection is fence-aware for both \`\`\` and ~~~ code blocks, and is
cross-checked against a second, independently-shaped implementation before
being trusted. Every entry is staged to a temp directory and verified
entirely from a FRESH re-read of both the source and the staged files —
never the in-memory data used to decide what to write — before anything
goes live. If any check fails, nothing is written and the real
docs/known-issues/ and docs/known-issues.md are untouched.

A heading with no severity anywhere — not in the heading itself, not in a
matched index row — is never guessed. "Missing from the index" cannot tell
a genuine entry the table simply forgot from something that is not really
an entry at all (both shapes exist in the real doc). migrate refuses,
printing every such heading with its line number, unless
--accept-severity-defaults is given, in which case they are set to LOW and
named in the output for follow-up with \`known-issue.sh severity\`.

Refuses to run if docs/known-issues/ already exists and is non-empty, unless
--force is given. --force only helps when docs/known-issues.md has been
restored to real hand-written content (its own successful run overwrites
that path with the generated index, so running it twice back to back with
nothing else changed fails earlier, with its own explanation, for a more
fundamental reason). When it does run, --force refuses unless every
existing entry is simultaneously unmodified since this tool last wrote it,
still produced by this run, and not a manifest entry whose file was deleted
out from under it — see the header comment for the full three-part check.
EOF
    exit 0
}

usage_reindex() {
    cat <<EOF
Usage: known-issue.sh reindex

Regenerates docs/known-issues.md from the frontmatter of every file under
docs/known-issues/. Idempotent: running it twice with no entry changes
produces a byte-identical file.
EOF
    exit 0
}

usage_lint() {
    cat <<EOF
Usage: known-issue.sh lint

Verifies every docs/known-issues/*.md file parses, carries the required
frontmatter (title, severity, status, slug), has a slug matching its own
filename and unique among all entries, matches its recorded sha256 in
_manifest.json (an entry edited by anything other than add/resolve/severity
would fail this), and that docs/known-issues.md is exactly what \`reindex\`
would produce right now. Exits non-zero on any failure — this is the guard
that keeps the index and the manifest from drifting again.
EOF
    exit 0
}

usage_remanifest() {
    cat <<EOF
known-issue.sh remanifest <slug>... [--root PATH]
known-issue.sh remanifest --drop <slug>... [--root PATH]

Re-record what this tool believes it wrote, so a lint that failed on manifest
drift has a supported way back to green.

Without --drop, each named slug's file must exist; its current sha256 is
recorded. With --drop, each named slug's file must be GONE and its record is
removed. Naming a slug the other way round is refused rather than guessed.

There is no --all: acceptance is an act, and a blanket one is a rubber stamp.
Nothing is written unless every named slug is valid, and every change is
printed. Only _manifest.json is touched — no entry is rewritten and the index
is not regenerated, so a stale index is reported and left for \`reindex\`.
EOF
    exit 0
}


usage_add() {
    cat <<EOF
Usage: known-issue.sh add --title TITLE --severity SEV [--note NOTE]
                           [--ticket PREFIX-nnn]... [--body TEXT]

Creates a new entry file under docs/known-issues/ and reindexes.

  --title TITLE      required
  --severity SEV     required; one of $SEVERITIES
  --note NOTE        optional one-line note shown in the index row
  --ticket PREFIX-nnn optional, repeatable
  --body TEXT        entry body. If omitted, the body is read from stdin.

Example:
  known-issue.sh add --title "Foo is broken" --severity MEDIUM \\
      --ticket PROJ-200 <<< "Foo has been broken since ..."
EOF
    exit 0
}

usage_resolve() {
    cat <<EOF
Usage: known-issue.sh resolve <slug> [--date YYYY-MM-DD] [--note NOTE]

Marks an existing entry resolved and reindexes.

  <slug>             required; the entry's filename under docs/known-issues/
                     without the .md suffix
  --date DATE        resolved date, YYYY-MM-DD (default: today)
  --note NOTE        replaces the entry's index-row note
EOF
    exit 0
}

usage_severity() {
    cat <<EOF
Usage: known-issue.sh severity <slug> <SEVERITY>

Changes an existing entry's severity and reindexes.

  <slug>             required; the entry's filename under docs/known-issues/
                     without the .md suffix
  <SEVERITY>         one of $SEVERITIES
EOF
    exit 0
}


[ $# -ge 1 ] || show_help
case "$1" in
    -h|--help) show_help ;;
esac

CMD="$1"; shift
known_command "$CMD" migrate reindex add resolve severity lint remanifest \
    || die "unknown subcommand: $CMD (try --help)"

case "$CMD" in
    migrate)
        ENGINE_ARGS=(migrate --source "$INDEX_FILE" --entries-dir "$ENTRIES_DIR"
                     --index-file "$INDEX_FILE")
        while [ $# -gt 0 ]; do
            case "$1" in
                --force) ENGINE_ARGS+=(--force); shift ;;
                --accept-severity-defaults)
                    ENGINE_ARGS+=(--accept-severity-defaults); shift ;;
                -h|--help) usage_migrate ;;
                *) die "migrate: unknown option: $1 (try --help)" ;;
            esac
        done
        run_engine "${ENGINE_ARGS[@]}"
        ;;

    reindex)
        if [ $# -gt 0 ]; then
            case "$1" in
                -h|--help) usage_reindex ;;
                *) die "reindex: unknown option: $1 (try --help)" ;;
            esac
        fi
        [ -d "$ENTRIES_DIR" ] || die "no entries yet — run 'migrate' first"
        run_engine reindex --entries-dir "$ENTRIES_DIR" --index-file "$INDEX_FILE"
        ;;

    lint)
        if [ $# -gt 0 ]; then
            case "$1" in
                -h|--help) usage_lint ;;
                *) die "lint: unknown option: $1 (try --help)" ;;
            esac
        fi
        [ -d "$ENTRIES_DIR" ] || die "no entries yet — run 'migrate' first"
        run_engine lint --entries-dir "$ENTRIES_DIR" --index-file "$INDEX_FILE"
        ;;

    add)
        TITLE=""; SEVERITY=""; NOTE=""; BODY=""; HAVE_BODY=0
        TICKETS=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --title) TITLE="$2"; shift 2 ;;
                --severity) SEVERITY="$2"; shift 2 ;;
                --note) NOTE="$2"; shift 2 ;;
                --ticket)
                    valid_ticket "$2" || die "add: not a ticket id (want PREFIX-nnn): $2"
                    TICKETS="${TICKETS:+$TICKETS,}$2"
                    shift 2
                    ;;
                --body) BODY="$2"; HAVE_BODY=1; shift 2 ;;
                -h|--help) usage_add ;;
                *) die "add: unknown option: $1 (try --help)" ;;
            esac
        done
        [ -n "$TITLE" ] || die "add: --title is required"
        [ -n "$SEVERITY" ] || die "add: --severity is required"
        valid_severity "$SEVERITY" || die "add: severity must be one of $SEVERITIES (got: $SEVERITY)"

        tmpfile BODY_FILE || die "could not create a body tempfile"
        if [ "$HAVE_BODY" = 1 ]; then
            printf '%s\n' "$BODY" > "$BODY_FILE"
        else
            cat > "$BODY_FILE"
        fi
        [ -s "$BODY_FILE" ] || die "add: entry body is empty (pass --body or pipe one on stdin)"

        # An array, not interpolated flags, so a note or ticket list with
        # spaces survives as ONE argument on its way to run_engine.
        ENGINE_ARGS=(add --entries-dir "$ENTRIES_DIR" --index-file "$INDEX_FILE"
                     --title "$TITLE" --severity "$SEVERITY" --body-file "$BODY_FILE")
        [ -n "$NOTE" ] && ENGINE_ARGS+=(--note "$NOTE")
        [ -n "$TICKETS" ] && ENGINE_ARGS+=(--tickets "$TICKETS")
        run_engine "${ENGINE_ARGS[@]}"
        ;;

    remanifest)
        # No `[ $# -ge 1 ] || usage_remanifest` as the other subcommands have:
        # a caller scripting `remanifest $SLUGS` with SLUGS empty must not get
        # exit 0. -h still prints the usage; nothing at all is an error.
        DROP=0
        SLUGS=()
        while [ $# -gt 0 ]; do
            case "$1" in
                --drop) DROP=1; shift ;;
                -h|--help) usage_remanifest ;;
                -*) die "remanifest: unknown option: $1 (try --help)" ;;
                *) SLUGS+=("$1"); shift ;;
            esac
        done
        [ ${#SLUGS[@]} -ge 1 ] || die "remanifest: name at least one slug (there is no --all)"
        [ -d "$ENTRIES_DIR" ] || die "no entries yet — run 'migrate' first"
        # Shape only. Existence is the engine's to judge, because --drop wants
        # a slug whose file is gone and re-recording wants one whose file is not.
        for SLUG in "${SLUGS[@]}"; do
            valid_slug_shape "$SLUG" \
                || die "remanifest: not a valid slug (want lowercase letters/digits/hyphens, no leading/trailing/doubled hyphen): $SLUG"
        done
        ENGINE_ARGS=(remanifest --entries-dir "$ENTRIES_DIR" --index-file "$INDEX_FILE")
        [ "$DROP" = 1 ] && ENGINE_ARGS+=(--drop)
        for SLUG in "${SLUGS[@]}"; do ENGINE_ARGS+=(--slug "$SLUG"); done
        run_engine "${ENGINE_ARGS[@]}"
        ;;

    resolve)
        [ $# -ge 1 ] || usage_resolve
        case "$1" in -h|--help) usage_resolve ;; esac
        SLUG="$1"; shift
        DATE="$(date +%Y-%m-%d)"
        NOTE=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --date) DATE="$2"; shift 2 ;;
                --note) NOTE="$2"; shift 2 ;;
                -h|--help) usage_resolve ;;
                *) die "resolve: unknown option: $1 (try --help)" ;;
            esac
        done
        valid_date "$DATE" || die "resolve: --date must be YYYY-MM-DD (got: $DATE)"
        [ -d "$ENTRIES_DIR" ] || die "no entries yet — run 'migrate' first"
        valid_slug_shape "$SLUG" || die "resolve: not a valid slug (want lowercase letters/digits/hyphens, no leading/trailing/doubled hyphen): $SLUG"
        valid_slug "$SLUG" || die "resolve: no such entry: $SLUG (no $ENTRIES_DIR/$SLUG.md)"

        ENGINE_ARGS=(resolve --entries-dir "$ENTRIES_DIR" --index-file "$INDEX_FILE"
                     --slug "$SLUG" --date "$DATE")
        [ -n "$NOTE" ] && ENGINE_ARGS+=(--note "$NOTE")
        run_engine "${ENGINE_ARGS[@]}"
        ;;

    severity)
        [ $# -ge 2 ] || usage_severity
        case "$1" in -h|--help) usage_severity ;; esac
        SLUG="$1"; SEV="$2"; shift 2
        [ $# -eq 0 ] || die "severity: unknown option: $1 (try --help)"
        valid_severity "$SEV" || die "severity: must be one of $SEVERITIES (got: $SEV)"
        [ -d "$ENTRIES_DIR" ] || die "no entries yet — run 'migrate' first"
        valid_slug_shape "$SLUG" || die "severity: not a valid slug (want lowercase letters/digits/hyphens, no leading/trailing/doubled hyphen): $SLUG"
        valid_slug "$SLUG" || die "severity: no such entry: $SLUG (no $ENTRIES_DIR/$SLUG.md)"

        run_engine severity --entries-dir "$ENTRIES_DIR" --index-file "$INDEX_FILE" \
            --slug "$SLUG" --severity "$SEV"
        ;;
esac
