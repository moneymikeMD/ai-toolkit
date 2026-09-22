#!/usr/bin/env python3
"""script-analytics.py — quantitative evidence on the script-author /
script-reviewer lane, extracted from local Claude Code JSONL transcripts.

Turns "that script took a lot of rounds and a long time before it was
useful" from an anecdote into numbers: rework rounds and their causes
(review findings, lint failures, usage/selftest failures), turns, tokens,
USD, and wall time to acceptance, per script and per agent type — so
"does a process tweak add time without adding quality" has evidence
behind it, not one memorable incident.

Read-only: it only reads local JSONL transcript files under
--projects-dir (default ~/.claude/projects) and appends to a local events
file the caller names. It never prints message, prompt, or tool
content — only derived counts, paths, timestamps, and ids.

Transcript layout this script expects (Claude Code CLI, verified live
2026-09-10 against 2.1.267):
    <projects-dir>/<slug>/<session-id>.jsonl
        the main-thread session transcript.
    <projects-dir>/<slug>/<session-id>/subagents/agent-<id>.jsonl
        one file per Agent-tool subagent launched from that session.
    <projects-dir>/<slug>/<session-id>/subagents/agent-<id>.meta.json
        {"agentType": "...", "description": "...", "toolUseId": "toolu_...",
         "spawnDepth": 1, "model": "..."}. toolUseId matches the id of the
        {"type":"tool_use","name":"Agent",...} block in the PARENT
        session's transcript that spawned this subagent; that block's
        "input" carries subagent_type, description, prompt (script paths
        and ticket live in the prompt), and model.

Numeric helpers are VENDORED, not imported (NWM-156): the table/tsv/md
renderers and the timestamp/price/cost helpers below are copies of
claude-cost.py's and claude-cost-scan.py's, so this file loads no sibling
at import time and runs from any directory in any repo. While all three
files live here, scripts/script-analytics-selftest.sh asserts each copy
still behaves identically to its original (see docs/cost.md). This
script's own fold_turns() below is a DELIBERATE, NAMED DEVIATION from
reusing the scanner's own fold:
claude-cost-scan.py's own scan_file() folds turns straight into
cost-only aggregates and never exposes a turn's message content, but
this script needs that content (to find Agent/Bash tool_use blocks and
text blocks) — so fold_turns() re-implements the same dedup algorithm
(message.id/requestId, line-fallback if neither is present, keep the
line with the highest output_tokens) while also carrying the surviving
line's full, UNIONED content-block list (a turn with two tool_use blocks
issued in one message puts each block on its own JSONL line, both
sharing message.id — taking only the max-output_tokens line's content
would silently drop whichever block was not on that one line).

Events file format (the deliverable): one JSON object per line, keys in
this fixed order: ts, script, scripts, event, cause, outcome, round,
session, agent_id, agent_type, model, turns, tokens, usd, duration_s,
findings, ticket, source, key, note. `event` is one of: author | review |
lint | selftest | rework | live-run | accepted | invoke | owner_wait
(live-run and accepted are manual-only, via `record`).

`invoke` events: one per Bash tool_use block, across EVERY transcript
scanned — the main-thread session transcript itself, and every subagent
transcript regardless of agentType, not only script-author/
script-reviewer — whose command actually RUNS at least one scripts/*.sh,
scripts/*.py, hooks/*.sh, or hooks/*.py path in an executable position of
one of its shell segments (see find_script_invocations()), excluding a
lint-shaped command entirely (its arguments are files being linted, not
run). This is a usage signal, not an authoring signal: it answers "is this
script actually being run", the quantitative check behind the "does a
one-off become a reusable script" bar.

No new EVENT_KEYS field was added for `invoke` — three existing fields are
reused:
  - `cause` carries "selftest" when the invoked path itself is a
    *-selftest.sh/*-selftest.py script, else "-". `report --usage` uses
    this to exclude a selftest-shaped invocation from its thresholds.
  - `agent_type` carries the raw agentType string for a subagent-hosted
    call (the event is still recorded even for script-author/
    script-reviewer, but `report --usage` excludes those from its "real
    usage" counts, since a script's own author calling the very script it
    is writing is not a real-world use), or the literal string "main" for
    a Bash call found directly in the top-level session transcript.
  - `ticket` is always "-" on an invoke event — out of scope for what
    invoke detection tracks.

`--help`/`-h` invocations are counted as an ordinary `invoke` event, no
special-casing — telling "just checking usage" apart from "a real
invocation" from command text alone is unreliable and out of scope.

`owner_wait` events: one per owner-attended interval found in ANY
transcript scanned — main session or subagent, any agentType — so that
wall-clock time genuinely spent waiting on the owner has real interval
data instead of a guess. A wait STARTS at whichever of these is seen
first, in turn order, per OWNER_WAIT_TRIGGER_PREFIXES below (a list
constant so a project with a different interactive tool can extend the
trigger set without touching the detection logic itself):
  - a tool_use block whose name matches one of the configured trigger
    prefixes (default: an exact "AskUserQuestion", or any tool whose name
    starts with a configured MCP-server prefix) — the owner is being
    asked something and the agent blocks for the answer.
  - BEST-EFFORT, UNVERIFIED: the transcript's LAST text-shaped assistant
    turn, if its text matches HUMAN_STEP_RE (vocabulary for a genuinely
    human remainder: sign in, install an app, click in a console, act at
    a registrar, etc). No agent-state transition to blocked/idle is
    exposed in these transcripts at all, so this is a textual proxy, not
    a confirmed state transition — a directional lower bound only, never
    a precise measurement. It is the only one of the signals above that
    can both over-match (unrelated prose reusing the same words) and
    under-match (a human step phrased differently), which is why it gets
    its own `note` value below rather than folding into a trigger-prefix
    note.

A wait ENDS at the next "type":"user" line in the SAME transcript file
after the start. A start with no following "type":"user" line (still open
— unanswered as of extraction time) produces NO event; it is picked up on
a later extract run once it has an end.

No new EVENT_KEYS field was added for `owner_wait` either — four existing
fields are reused:
  - `session`/`agent_id`/`agent_type` carry the same values they would for
    any other event from that transcript ("main" for the top-level
    session, same as `invoke`).
  - `ticket` is the ticket already known for an attributed author/review
    subagent transcript, or, when that is unavailable, a best-effort scan
    of the transcript's OWN text for a ticket-shaped mention
    (extract_session_ticket()) — "-" if neither finds one.
  - `duration_s` carries the interval's seconds.
  - `note` carries which signal fired — one of the configured trigger
    notes, or "human_step_heuristic" — so a consumer can exclude the
    unverified signal from anything that needs to be precise.
`script`/`scripts` are always "-"/[] (an owner_wait is not about a
script), `cause`/`outcome`/`round` are always "-", and
`model`/`turns`/`tokens`/`usd` are always "-"/0/0/0.0.

`report --usage`: a quantitative check on whether a script is actually
being run, kept as a separate code path from the default `report` table
(the default output is untouched line-for-line by this feature). Per
script: invocations/sessions/pass-fail/first-last-used/lint+selftest run
counts/rework_rounds/lint_wall_clock_s/author_usd/rework_ratio, plus a
retirement `flag` — see usage_flag() for the exact keep/retire?/flag
precedence and its day/count thresholds. Only NON-TEST invocations count
toward any of this: an invoke event with cause "selftest", agent_type
script-author/script-reviewer, or a session matching one of the script's
own `author` events (the authoring session) is excluded — see
build_usage_rows(). A *-selftest.sh/*-selftest.py file never gets its own
row at all (USAGE_SELFTEST_FILE_RE) — it is a fixture, not a script anyone
else runs. `report --usage` also prints an owner_wait summary — total
owner-attended seconds per ticket in the same --since/--until window, plus
a wave-total row (see build_owner_wait_rows()).

Every already-recorded `script`/`scripts` value is resolved to its CURRENT
repo-relative path by basename lookup against the real scripts/ and
hooks/ trees on disk (normalize_script_path()) — both going forward, at
extract/record time, and via the `backfill-script-paths` subcommand for
events already on disk (rerunnable, not a one-time migration — a script
moving directories again needs this again). Without this, the same script
landed on two different rows depending on whatever path string a dispatch
prompt, Bash command, or `record --script` argument happened to use at the
time (a bare basename, or a stale subdirectory from before a move), each
carrying only a fraction of its real invocation count.

`rework` events: a script-author subagent RESUMED via SendMessage for
another round of work appends to its OWN transcript rather than spawning
a new subagent, so a fresh-invocation round (a brand-new author subagent
for the same script) is not the only way rework happens — resuming the
same one is at least as common. Each resume prompt inside an author
transcript (a "type":"user" line whose content is text-shaped, after the
first — see find_resume_prompts()) emits its own `rework` event, with
`round` continuing the same (session, script) counter the author event
started, and `cause` inferred from that resume's own prompt text via the
same review/lint/usage heuristics used for a fresh-invocation round. The
transcript is SLICED at each resume prompt's timestamp: the author
event's turns/tokens/usd/duration_s cover only the window up to the
first resume, and each rework event covers its own window up to the next
resume or the end — so the slices sum to the same total a
whole-transcript figure would give with no resumes. `report`'s `rounds`
and `rework_review`/`rework_lint`/`rework_usage` counts include `rework`
events alongside `author` events, and its turns/tokens/usd totals sum
`author` + `review` + `rework`.

`extract --session ID` and `extract --agent-id ID` (mutually exclusive)
restrict the scan to one session or one subagent, found by glob
(<projects-dir>/*/<ID>.jsonl or <projects-dir>/*/*/subagents/agent-<ID>.jsonl)
rather than walking every session under --projects-dir — for a
SubagentStop hook invoking this after every subagent finishes (see
hooks/script-events-hook.sh). Both are scope restrictions only:
idempotence by "key" is unchanged, and if the matched subagent's
agentType is not in scope (not script-author/script-reviewer, or in
--agent-types), the run exits 0 and writes nothing, same as it would
during a full scan. `--quiet` prints nothing on stdout when 0 new events
are found; the summary line still prints when any are.

Exit codes: 0 success, 2 a validation failure (bad input, printed to
stderr), 1 an unexpected error.
"""

import argparse
import csv
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))

PRICES_BASENAME = "claude-prices.tsv"
TOKEN_CLASSES = ("input", "output", "cache_write", "cache_read")
PRICE_COLUMNS = ("model",) + tuple("%s_per_mtok" % c for c in TOKEN_CLASSES)


class ValidationError(Exception):
    """Raised for any expected user-input problem. Caught in main() and
    reported to stderr with exit 2 — never a traceback."""


def render_table(headers, rows):
    """Render rows as a space-padded fixed-width table. Vendored from
    claude-cost.py; the selftest asserts the two still agree."""
    if not rows:
        widths = [len(h) for h in headers]
    else:
        widths = [
            max(len(h), max(len(str(r[i])) for r in rows))
            for i, h in enumerate(headers)
        ]
    lines = ["  ".join(h.ljust(widths[i]) for i, h in enumerate(headers))]
    lines.append("  ".join("-" * w for w in widths))
    for r in rows:
        lines.append("  ".join(str(r[i]).ljust(widths[i]) for i in range(len(headers))))
    return "\n".join(lines)


def render_tsv(headers, rows):
    """Render rows as tab-separated lines. Vendored from claude-cost.py."""
    lines = ["\t".join(headers)]
    lines.extend("\t".join(str(x) for x in r) for r in rows)
    return "\n".join(lines)


def render_md(headers, rows):
    """Render rows as a GitHub-flavored markdown table. Vendored from
    claude-cost.py."""
    lines = ["| " + " | ".join(headers) + " |"]
    lines.append("| " + " | ".join("---" for _ in headers) + " |")
    for r in rows:
        lines.append("| " + " | ".join(str(x) for x in r) + " |")
    return "\n".join(lines)


RENDERERS = {"table": render_table, "tsv": render_tsv, "md": render_md}


def parse_timestamp(text):
    """Parse an ISO-8601 timestamp, defaulting a naive one to UTC. Vendored
    from claude-cost-scan.py; raises ValidationError on a malformed value."""
    if text is None:
        return None
    # A bare "Z" suffix is rewritten to +00:00: Python's fromisoformat
    # predates that shorthand.
    text = text.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        raise ValidationError("could not parse timestamp: %r" % text)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def read_prices(path):
    """Read a price table TSV into {model: {token_class: rate_per_mtok}}.
    Vendored from claude-cost-scan.py; the header must match exactly."""
    prices = {}
    with open(path) as f:
        reader = csv.DictReader(f, delimiter="\t")
        if reader.fieldnames != list(PRICE_COLUMNS):
            raise ValidationError(
                "--prices %s: header must be exactly %s (found %s)"
                % (path, "\t".join(PRICE_COLUMNS), "\t".join(reader.fieldnames or []))
            )
        for row in reader:
            model = row["model"]
            try:
                prices[model] = {c: float(row["%s_per_mtok" % c]) for c in TOKEN_CLASSES}
            except ValueError:
                raise ValidationError("--prices %s: non-numeric rate for model %r" % (path, model))
    return prices


def turn_cost(turn, prices, warned_models):
    """Cost one turn against a price table, warning once per unpriced model
    and costing it as 0. Vendored from claude-cost-scan.py."""
    rate = prices.get(turn["model"])
    if rate is None:
        if turn["model"] not in warned_models:
            print("script-analytics.py: no price row for model %r; costing as $0" % turn["model"],
                  file=sys.stderr)
            warned_models.add(turn["model"])
        return 0.0
    tokens = turn["tokens"]
    return sum(tokens[c] / 1_000_000.0 * rate[c] for c in TOKEN_CLASSES)


def prices_path_candidates():
    """Every layout default_prices_path() will try, in order. Public so the
    not-found error can name them all."""
    out = [
        os.path.join(HERE, "..", "templates", PRICES_BASENAME),
        os.path.join(HERE, PRICES_BASENAME),
    ]
    project = os.environ.get("CLAUDE_PROJECT_DIR")
    if project:
        out.append(os.path.join(project, "templates", PRICES_BASENAME))
        out.append(os.path.join(project, PRICES_BASENAME))
    return out


def default_prices_path():
    """The price table to use when --prices is not given: $CLAUDE_PRICES_TSV
    if set, else the first candidate layout that exists (NWM-156)."""
    env = os.environ.get("CLAUDE_PRICES_TSV")
    if env:
        if not os.path.isfile(env):
            raise ValidationError("$CLAUDE_PRICES_TSV does not name a file: %s" % env)
        return env
    candidates = prices_path_candidates()
    for path in candidates:
        if os.path.isfile(path):
            return path
    raise ValidationError(
        "no %s found; tried %s. Pass --prices PATH or set $CLAUDE_PRICES_TSV."
        % (PRICES_BASENAME, ", ".join(os.path.normpath(p) for p in candidates)))

EVENT_KEYS = (
    "ts", "script", "scripts", "event", "cause", "outcome", "round",
    "session", "agent_id", "agent_type", "model", "turns", "tokens",
    "usd", "duration_s", "findings", "ticket", "source", "key", "note",
)

DEFAULT_AGENT_TYPE_MAP = {
    "script-author": "author",
    "script-reviewer": "review",
}

# scripts/ and hooks/ are this repo's two script-bar directories (see the
# shell-scripting skill) — a script-author/reviewer brief names a path
# under either.
SCRIPT_RE = re.compile(r"(?:scripts|hooks)/[A-Za-z0-9_./-]+\.(?:sh|py)")
# A generic TICKET-123-shaped id, not tied to one tracker's prefix (see
# ai-toolkit's known-issue.sh TICKET_RE — kept identical on purpose so the
# two agree on what a ticket reference looks like, now across two repos).
TICKET_RE = re.compile(r"\b[A-Za-z][A-Za-z0-9_]*-\d+\b")
LINT_CMD_RE = re.compile(r"shellcheck|ruff check|lint")
SELFTEST_CMD_RE = re.compile(r"selftest")
FAIL_RESULT_RE = re.compile(r"SELFTEST FAILED|FAIL|found issue|error:")
# Do NOT add re.IGNORECASE to FAIL_RESULT_RE above: it is SHARED with the
# lint/selftest outcome check, and a case-insensitive "fail" flips outcomes
# store-wide the moment the bare word appears in ordinary successful output.
# This widens only "error:", only for build_invoke_events.
INVOKE_ERROR_CI_RE = re.compile(r"error:", re.IGNORECASE)
FINDING_RE = re.compile(r"(?<![A-Za-z])(CRITICAL|HIGH|MEDIUM|LOW)(?![A-Za-z])")
# Negation words must be WHOLE words immediately preceding the token, or
# "techno HIGH severity finding" reads as negated because "techno" ends in "no".
NEGATION_RE = re.compile(
    r"(?<![A-Za-z0-9_])(?:no|zero|none|0)\s*$", re.IGNORECASE
)
# "2 HIGH" means TWO findings. The digit run must not be glued to a preceding
# letter/digit/underscore, or "line2 HIGH" reads "2" as a count.
COUNT_PREFIX_RE = re.compile(r"(?<![A-Za-z0-9_])(\d+)\s*$")

# For line_is_finding_shaped(): a prose mention like "the HIGH finding" must
# NOT count. PATH_TOKEN_RE matches "path:line — SEVERITY — ...";
# LIST_SEVERITY_RE matches a bare bullet/heading finding line.
PATH_TOKEN_RE = re.compile(r"[A-Za-z0-9_./-]+\.(?:sh|py|json|md)(?::\d+)?")
LIST_SEVERITY_RE = re.compile(r"^\s*(?:[-*\d.]+\s*)?(?:\*\*)?(?:CRITICAL|HIGH|MEDIUM|LOW)\b")

REVIEW_CAUSE_RE = re.compile(r"review|finding|CRITICAL|HIGH|MEDIUM|reviewer", re.IGNORECASE)
LINT_CAUSE_RE = re.compile(r"lint|shellcheck|ruff", re.IGNORECASE)
USAGE_CAUSE_RE = re.compile(r"selftest|failed|live run|usage|error", re.IGNORECASE)

# owner_wait detection — see the module docstring for why the heuristic path
# is UNVERIFIED. A constant so an adopter can extend the trigger set without
# touching the logic; (name_prefix, note) entries, matched by str.startswith.
OWNER_WAIT_TRIGGER_PREFIXES = (
    ("AskUserQuestion", "askuser"),
    ("mcp__spokenly__", "spokenly"),
)
# UNVERIFIED, best-effort: a textual heuristic with no fixture evidence behind
# it — no real transcript has been observed to confirm this path fires. This
# marker is deliberately kept, not resolved; see the module docstring.
HUMAN_STEP_RE = re.compile(
    r"sign in|install (?:the |an )?app|click in a console|at a registrar|"
    r"waiting on you|over to you|your turn now|need you to|"
    r"please (?:sign|click|install|provide|run|confirm|approve)",
    re.IGNORECASE,
)


def owner_wait_trigger_note(tool_name):
    """Return the owner_wait `note` value for a tool_use block's `name` if
    it matches one of OWNER_WAIT_TRIGGER_PREFIXES (by prefix, in list
    order), else None."""
    for prefix, note in OWNER_WAIT_TRIGGER_PREFIXES:
        if tool_name.startswith(prefix):
            return note
    return None


def zero_findings():
    return {"critical": 0, "high": 0, "medium": 0, "low": 0}


# `record --note` lands verbatim in a caller-owned events file, so a note is
# refused if it looks credential-shaped: a long opaque token, or a key=value
# pair whose key names a common secret word. LONG_TOKEN_RE is deliberately
# generic because a bare pasted token carries no key name to match against.
LONG_TOKEN_RE = re.compile(r"[A-Za-z0-9_-]{24,}")
KEYVALUE_RE = re.compile(r"([A-Za-z0-9_.-]+)\s*=\s*(\S+)")
SECRET_WORDS = (
    "password", "passwd", "secret", "token", "api_key", "apikey",
    "credential", "auth", "private_key",
)


def note_is_credential_shaped(note):
    """True if note contains either a long id-shaped token (24+
    [A-Za-z0-9_-] chars) or a key=value pair whose key contains one of
    SECRET_WORDS as a substring (an env-style compound key like
    DB_PASSWORD is the common shape a pasted note would carry)."""
    if LONG_TOKEN_RE.search(note):
        return True
    for m in KEYVALUE_RE.finditer(note):
        key = m.group(1).lower()
        for word in SECRET_WORDS:
            if word in key:
                return True
    return False


def parse_iso(text, label):
    try:
        dt = parse_timestamp(text)
    except ValidationError as exc:
        raise ValidationError("%s: %s" % (label, exc))
    if dt is None:
        raise ValidationError("%s: could not parse timestamp: %r" % (label, text))
    return dt


def fmt_ts(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _num(x):
    try:
        return int(x)
    except (TypeError, ValueError):
        return 0


def load_prices(path):
    return read_prices(path or default_prices_path())


def usd_cost(model, tok, prices, warned_models):
    return turn_cost({"model": model, "tokens": tok}, prices, warned_models)


def read_jsonl_lines(path, warnings=None):
    """Yield (lineno, dict) for every line in path that parses as a JSON
    object. A line that fails to parse as JSON is skipped silently
    (partial writes are normal for a live session's active file). A line
    that parses to something other than a dict is skipped and, if
    `warnings` is given, named on it."""
    try:
        with open(path, "r", errors="replace") as fh:
            for lineno, raw in enumerate(fh, start=1):
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    d = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if not isinstance(d, dict):
                    if warnings is not None:
                        warnings.append("%s:%d: skipped — line is not a JSON object" % (path, lineno))
                    continue
                yield lineno, d
    except OSError as exc:
        if warnings is not None:
            warnings.append("%s: ERROR reading file: %s" % (path, exc))
        return


def line_timestamp(d):
    raw_ts = d.get("timestamp")
    if not raw_ts:
        return None
    try:
        return parse_iso(raw_ts, "timestamp")
    except ValidationError:
        return None


def file_timespan(path, warnings):
    """Return (first_ts, last_ts) across every line in path that carries a
    parseable "timestamp", regardless of line type. None, None if no line
    carries one."""
    first = last = None
    for _lineno, d in read_jsonl_lines(path, warnings):
        ts = line_timestamp(d)
        if ts is None:
            continue
        if first is None or ts < first:
            first = ts
        if last is None or ts > last:
            last = ts
    return first, last


def fold_turns(path, warnings):
    """Group "type":"assistant" lines by message.id (or requestId, or —
    failing both — the line itself). Each such line carries only ITS OWN
    content block (one line per tool_use/text/thinking block), not a
    cumulative array — so a turn with TWO tool_use blocks (e.g. two Agent
    calls issued in one turn) puts each block on its OWN line, both
    sharing the same message.id. UNION every line's content blocks into
    the turn's content list, deduped by a block's own "id" field when it
    has one (tool_use/tool_result blocks do; text/thinking blocks are
    deduped by equality instead, since they carry no id) — while
    usage/ts/model come from whichever line has the highest
    usage.output_tokens (the signal for "this line's usage is the turn's
    true, complete total"). Returns the survivors as a list of dicts (ts,
    model, usage, content, order) sorted by original appearance order."""
    turns = {}
    order_counter = [0]

    def next_order():
        order_counter[0] += 1
        return order_counter[0]

    for lineno, d in read_jsonl_lines(path, warnings):
        if d.get("type") != "assistant":
            continue
        msg = d.get("message")
        if msg is None:
            continue
        if not isinstance(msg, dict):
            warnings.append("%s:%d: skipped — \"message\" is not an object" % (path, lineno))
            continue
        usage = msg.get("usage")
        if usage is None:
            # Skipped BEFORE turn_id/content are touched, so these blocks do
            # not contribute to tool-call/text detection either.
            continue
        if not isinstance(usage, dict):
            warnings.append("%s:%d: skipped — \"usage\" is not an object" % (path, lineno))
            continue
        content = msg.get("content")
        if not isinstance(content, list):
            content = []
        ts = line_timestamp(d)
        model = msg.get("model") or "unknown"
        output_tokens = _num(usage.get("output_tokens"))

        turn_id = msg.get("id") or d.get("requestId")
        if turn_id is None:
            turn_id = ("_line", lineno)

        existing = turns.get(turn_id)
        if existing is None:
            existing = {
                "ts": ts, "model": model, "usage": usage or {},
                "content": [], "output_tokens": output_tokens,
                "order": next_order(), "_seen_block_ids": set(),
            }
            turns[turn_id] = existing

        for block in content:
            block_id = block.get("id") if isinstance(block, dict) else None
            if block_id is not None:
                if block_id in existing["_seen_block_ids"]:
                    continue
                existing["_seen_block_ids"].add(block_id)
                existing["content"].append(block)
            elif block not in existing["content"]:
                existing["content"].append(block)

        if output_tokens >= existing["output_tokens"]:
            existing["ts"] = ts
            existing["model"] = model
            existing["usage"] = usage or {}
            existing["output_tokens"] = output_tokens

    epoch = datetime.min.replace(tzinfo=timezone.utc)
    return sorted(turns.values(), key=lambda t: (t["ts"] or epoch, t["order"]))


def collect_tool_results(path, warnings):
    """Return {tool_use_id: {"is_error": ..., "content": ..., "ts": ...}}
    from every "type":"user" line's tool_result content blocks. Unlike
    assistant turns, a tool_result is not known to be duplicated across
    lines, so no dedup is applied here."""
    results = {}
    for _lineno, d in read_jsonl_lines(path, warnings):
        if d.get("type") != "user":
            continue
        msg = d.get("message")
        if not isinstance(msg, dict):
            continue
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        ts = line_timestamp(d)
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_result":
                tuid = block.get("tool_use_id")
                if tuid:
                    results[tuid] = {
                        "is_error": block.get("is_error"),
                        "content": block.get("content"),
                        "ts": ts,
                    }
    return results


def tool_result_text(content):
    """Best-effort flatten of a tool_result's "content" field (a string, or
    a list of {"type":"text","text":...} blocks) to plain text for the
    pass/fail regex. Never printed — only matched against."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and isinstance(block.get("text"), str):
                parts.append(block["text"])
        return "\n".join(parts)
    return ""


def find_resume_prompts(path, warnings):
    """Return [(ts, text), ...] for every "type":"user" line in an author
    transcript whose message.content is TEXT-shaped — a plain string, or a
    list containing at least one {"type":"text"} block — excluding the
    FIRST such line. Rework delivered by resuming the same subagent via
    SendMessage appends to the SAME transcript rather than spawning a new
    agent. The FIRST text-shaped user line is the original dispatch
    brief, not a resume, and is excluded from the returned list. A
    "type":"user" line whose content is ONLY tool_result block(s) (a Bash
    result, etc.) is not text-shaped and is skipped entirely — it is
    neither the brief nor a resume."""
    text_lines = []
    for _lineno, d in read_jsonl_lines(path, warnings):
        if d.get("type") != "user":
            continue
        msg = d.get("message")
        if not isinstance(msg, dict):
            continue
        content = msg.get("content")
        text = None
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            texts = [
                block.get("text") for block in content
                if isinstance(block, dict) and block.get("type") == "text"
                and isinstance(block.get("text"), str)
            ]
            if texts:
                text = "\n".join(texts)
        if text is None:
            continue
        text_lines.append((line_timestamp(d), text))
    return text_lines[1:]


def turns_in_window(folded_turns, start, end):
    """Return the folded turns whose ts falls in the half-open window
    [start, end) — end=None means "no upper bound" (the final slice runs
    to the end of the transcript). A turn with ts=None (unparseable
    timestamp) is excluded from every window."""
    out = []
    for t in folded_turns:
        ts = t["ts"]
        if ts is None:
            continue
        if start is not None and ts < start:
            continue
        if end is not None and ts >= end:
            continue
        out.append(t)
    return out


def turn_tokens(usage):
    return {
        "input": _num(usage.get("input_tokens")),
        "output": _num(usage.get("output_tokens")),
        "cache_read": _num(usage.get("cache_read_input_tokens")),
        "cache_write": _num(usage.get("cache_creation_input_tokens")),
    }


def sum_turns(folded_turns, prices, warned_models):
    """Aggregate turns/tokens/usd/model across a list of folded turns
    (as returned by fold_turns). model is the most common model string
    seen across the turns, or None if there are no turns."""
    total_tokens = 0
    total_usd = 0.0
    model_counts = {}
    for t in folded_turns:
        tok = turn_tokens(t["usage"])
        total_tokens += sum(tok.values())
        total_usd += usd_cost(t["model"], tok, prices, warned_models)
        model_counts[t["model"]] = model_counts.get(t["model"], 0) + 1
    model = None
    if model_counts:
        model = sorted(model_counts.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
    return len(folded_turns), total_tokens, total_usd, model


# Paths named as the CONVENTION being followed, not the script under work.
# Excluded from the primary-script pool unless the only one named at all.
REFERENCE_SCRIPTS = frozenset({"scripts/lib/kit.sh"})


# Events keep whatever path string a prompt or command used, so the SAME
# script lands on two rows in `report --usage`. Every value is resolved
# against the real scripts/ and hooks/ trees by basename.
def discover_repo_scripts():
    """Walk the real scripts/ and hooks/ trees (this repo's two script-bar
    directories, see SCRIPT_RE above) and return (by_basename,
    canonical_paths): by_basename maps a bare filename ("foo.sh") to the
    list of its current repo-relative locations ("scripts/api/foo.sh"),
    usually one entry; canonical_paths is the set of every current
    repo-relative *.sh/*.py path under either tree. Computed once at
    import time — this repo's own tree does not change mid-run."""
    repo_root = os.path.dirname(HERE)
    by_basename = {}
    canonical_paths = set()
    for top in ("scripts", "hooks"):
        top_dir = os.path.join(repo_root, top)
        if not os.path.isdir(top_dir):
            continue
        for dirpath, dirnames, filenames in os.walk(top_dir):
            dirnames.sort()
            for fn in sorted(filenames):
                if not (fn.endswith(".sh") or fn.endswith(".py")):
                    continue
                rel = os.path.relpath(os.path.join(dirpath, fn), repo_root).replace(os.sep, "/")
                canonical_paths.add(rel)
                by_basename.setdefault(fn, []).append(rel)
    return by_basename, canonical_paths


SCRIPT_BASENAME_INDEX, SCRIPT_CANONICAL_PATHS = discover_repo_scripts()

# A selftest's own file is excluded from `report --usage`'s row set; applied
# in build_usage_rows(). Deliberately NOT extended to a blanket "must exist on
# disk" filter, which answers a different question than "is it a fixture".
USAGE_SELFTEST_FILE_RE = re.compile(r"[-.]selftest\.(?:sh|py)$")


def normalize_script_path(path):
    """Resolve `path` (a scripts/*.sh, scripts/*.py, hooks/*.sh, or
    hooks/*.py string, possibly a bare basename or a stale subdirectory
    left over from before the script moved) to its CURRENT repo-relative
    location, by basename lookup against the real tree. Returns `path`
    unchanged if it is already canonical, if its basename is not found
    anywhere in the tree (a retired/deleted script — an unresolved name is
    safer than a wrong guess), or if the basename is AMBIGUOUS (matches
    more than one current file)."""
    if not path or path == "-":
        return path
    if path in SCRIPT_CANONICAL_PATHS:
        return path
    candidates = SCRIPT_BASENAME_INDEX.get(os.path.basename(path))
    if candidates and len(candidates) == 1:
        return candidates[0]
    return path


def extract_scripts(prompt, description):
    """Return (primary_script, scripts_sorted). After excluding an
    invoked lint command, (1) a candidate named in the description wins
    (first by prompt order among those); (2) otherwise, prefer a
    candidate that is NEITHER in REFERENCE_SCRIPTS NOR *selftest* — first
    by prompt order; (3) otherwise (every candidate is a
    reference-convention path and/or a selftest path — i.e. no other
    candidate was ever named), fall back to the first candidate by prompt
    order regardless. A reference-set path is therefore primary only when
    it is the only candidate, per rule (3). If nothing matches at all,
    primary is "-" and scripts is []."""
    if not prompt:
        return "-", []
    ordered_unique = []
    for m in SCRIPT_RE.findall(prompt):
        if m.endswith("lint.sh"):
            continue
        # Normalized before any dedup/ordering below, so a stale path lands on
        # the SAME row as every other event for that script.
        m = normalize_script_path(m)
        if m not in ordered_unique:
            ordered_unique.append(m)
    if not ordered_unique:
        return "-", []
    scripts_sorted = sorted(set(ordered_unique))

    in_desc = [m for m in ordered_unique if description and m in description]
    if in_desc:
        return in_desc[0], scripts_sorted

    non_reference = [
        m for m in ordered_unique
        if m not in REFERENCE_SCRIPTS and "selftest" not in m
    ]
    primary = non_reference[0] if non_reference else ordered_unique[0]
    return primary, scripts_sorted


def extract_ticket(prompt):
    if not prompt:
        return "-"
    m = TICKET_RE.search(prompt)
    return m.group(0) if m else "-"


def infer_cause(prompt):
    if not prompt:
        return "unknown"
    if REVIEW_CAUSE_RE.search(prompt):
        return "review"
    if LINT_CAUSE_RE.search(prompt):
        return "lint"
    if USAGE_CAUSE_RE.search(prompt):
        return "usage"
    return "unknown"


def line_is_finding_shaped(line, severity_start):
    """True if `line` is shaped like an actual finding line for the
    severity token starting at severity_start, not a prose mention (e.g.
    "the HIGH finding" or "already sent ... HIGH" must NOT count). One of
    three shapes qualifies:
      - a path or path:line token appears BEFORE the severity token on the
        line (PATH_TOKEN_RE) — the "path:line — SEVERITY — ..." shape;
      - the line begins with an optional list marker/bold, then the
        severity token (LIST_SEVERITY_RE) — a bare bullet-style finding;
      - an explicit stated count immediately precedes the token ("2
        HIGH") — COUNT_PREFIX_RE, same signal parse_findings_in_block
        already uses to read the count itself."""
    prefix = line[:severity_start]
    if PATH_TOKEN_RE.search(prefix):
        return True
    if LIST_SEVERITY_RE.match(line):
        return True
    preceding = line[max(0, severity_start - 12):severity_start]
    if COUNT_PREFIX_RE.search(preceding):
        return True
    return False


def parse_findings_in_block(text):
    """Count CRITICAL/HIGH/MEDIUM/LOW findings in ONE text block. EVERY
    severity token on a line is evaluated for its own negation
    independently (taking only the first token per line would undercount
    a summary line naming several severities). A token preceded within 12
    chars by a WHOLE-WORD negation (no/0/zero/none) is skipped entirely —
    see NEGATION_RE. A token whose line is not finding-shaped (see
    line_is_finding_shaped) is also skipped — a prose mention of a
    severity word is not a finding. Otherwise, a stated NUMBER
    immediately before the token is read as that many findings (e.g. "2
    HIGH" -> +2, not +1); with no such number, a bare occurrence counts
    as 1."""
    counts = zero_findings()
    if not text:
        return counts
    for line in text.splitlines():
        for m in FINDING_RE.finditer(line):
            start = m.start()
            preceding = line[max(0, start - 12):start]
            if NEGATION_RE.search(preceding):
                continue
            if not line_is_finding_shaped(line, start):
                continue
            count_m = COUNT_PREFIX_RE.search(preceding)
            counts[m.group(1).lower()] += int(count_m.group(1)) if count_m else 1
    return counts


def parse_findings(folded_turns):
    """Count CRITICAL/HIGH/MEDIUM/LOW findings across an ENTIRE subagent
    transcript, not just its last text block (a reviewer resumed via
    SendMessage for a re-verify may end with a "PASS/PASS" block carrying
    no severity tokens at all — taking only the last block would silently
    lose the original report's real findings). Every {"type":"text"}
    block across every folded turn is scored independently via
    parse_findings_in_block, and the PER-SEVERITY MAX across blocks is
    returned — not the sum, so a resumed agent's second reply (which
    often repeats or partially restates the same findings) never
    double-counts on top of the original report."""
    best = zero_findings()
    for t in folded_turns:
        for block in t["content"]:
            if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
                block_counts = parse_findings_in_block(block["text"])
                for key, value in block_counts.items():
                    if value > best[key]:
                        best[key] = value
    return best


def find_agent_tool_calls(folded_turns):
    """Return a list of (tool_use_id, input_dict, ts) for every tool_use
    block named "Agent" across folded_turns, in turn order."""
    out = []
    for t in folded_turns:
        for block in t["content"]:
            if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == "Agent":
                out.append((block.get("id"), block.get("input") or {}, t["ts"]))
    return out


def find_lint_selftest_calls(folded_turns):
    """Return a list of (tool_use_id, command, ts, turn) for every Bash
    tool_use block whose command matches the lint/selftest detection
    regex."""
    out = []
    for t in folded_turns:
        for block in t["content"]:
            if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == "Bash":
                command = (block.get("input") or {}).get("command") or ""
                if LINT_CMD_RE.search(command) or SELFTEST_CMD_RE.search(command):
                    out.append((block.get("id"), command, t["ts"], t))
    return out


# Detection is constrained to an EXECUTABLE POSITION — the start of a shell
# segment (split on &&, ||, ; and |), optionally preceded by `./`, or as an
# interpreter's first argument. A bare findall() over the whole command would
# count a grep/find target or a heredoc body as an invocation.
SEGMENT_SPLIT_RE = re.compile(r"&&|\|\||[;|]")
# Consumes any number of `VAR=val`, `sudo` and `timeout <duration>` prefix
# tokens, in any order, before the executable-position check — without this
# those real invocations are undercounted.
INVOKE_PREFIX = r"(?:(?:[A-Za-z_][A-Za-z0-9_]*=\S+|sudo|timeout\s+\S+)\s+)*"
INVOKE_POSITION_RE = re.compile(
    r"^\s*" + INVOKE_PREFIX + r"(?:\./)?((?:scripts|hooks)/[A-Za-z0-9_./-]+\.(?:sh|py))\b"
    r"|^\s*" + INVOKE_PREFIX + r"(?:python3?|bash|sh)\s+((?:scripts|hooks)/[A-Za-z0-9_./-]+\.(?:sh|py))\b"
)

# Checks the shape of the INVOKED PATH, not the raw command text:
# SELFTEST_CMD_RE's bare substring would mark "git diff x-selftest.sh &&
# ./y.sh" as a selftest run when the segment executed is y.sh.
INVOKE_SELFTEST_PATH_RE = re.compile(r"-selftest\.(?:sh|py)$")


def find_script_invocations(folded_turns):
    """Return (tool_use_id, command, ts, call_turn, primary_script,
    scripts_sorted) for every Bash tool_use block that actually RUNS at
    least one scripts/hooks *.sh or *.py path in an executable position
    (see INVOKE_POSITION_RE above) of one of its shell segments.

    A command matching LINT_CMD_RE anywhere (the same predicate
    find_lint_selftest_calls already uses to detect a lint run) is
    skipped ENTIRELY — not just a literal "scripts/lint.sh" match — since
    a lint command's own arguments are files being LINTED, not RUN. The
    tradeoff: a single Bash call that BOTH lints and separately runs a
    real script in the same command (rare) loses that second call's
    invoke event too — accepted, since a lint-shaped command is not where
    a real invocation is expected to live.

    `primary_script` is the first remaining match in segment order;
    `scripts_sorted` is the sorted unique set of all remaining matches
    across every segment of that one command (the same "primary + scripts
    list" shape extract_scripts() returns for an Agent prompt)."""
    out = []
    for t in folded_turns:
        for block in t["content"]:
            if not (isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == "Bash"):
                continue
            command = (block.get("input") or {}).get("command") or ""
            if LINT_CMD_RE.search(command):
                continue
            ordered_unique = []
            for segment in SEGMENT_SPLIT_RE.split(command):
                m = INVOKE_POSITION_RE.match(segment)
                if not m:
                    continue
                path = normalize_script_path(m.group(1) or m.group(2))
                if path not in ordered_unique:
                    ordered_unique.append(path)
            if not ordered_unique:
                continue
            out.append((block.get("id"), command, t["ts"], t, ordered_unique[0], sorted(set(ordered_unique))))
    return out


def build_invoke_events(jsonl_path, session_id, agent_id, agent_type, warnings, prices, warned_models):
    """Return one `invoke` event per Bash tool_use block matched by
    find_script_invocations() in the transcript at jsonl_path — the SAME
    turn-fold/tool-result-outcome machinery find_lint_selftest_calls'
    caller already uses for `lint`/`selftest` (outcome pass/fail from the
    matching tool_result, "-" if the result is missing/unresolved), so a
    script invocation's pass/fail signal is read exactly the same way a
    lint run's is. Never raises — a missing/unreadable transcript surfaces
    only via `warnings`, same as every other read in this file.

    pass/fail outcome is still a keyword scan over arbitrary script stdout
    (FAIL_RESULT_RE, plus INVOKE_ERROR_CI_RE for a case-insensitive
    "error:" match — see that regex's own comment for why this is scoped
    to invoke only), which remains an imperfect heuristic for scripts with
    unpredictable output shapes; kept at this granularity because it is
    the SAME heuristic find_lint_selftest_calls already relies on for
    `lint`/`selftest` outcomes elsewhere in this file."""
    sub_warnings = []
    folded = fold_turns(jsonl_path, sub_warnings)
    warnings.extend(sub_warnings)
    tool_results = collect_tool_results(jsonl_path, warnings)

    events = []
    for call_id, command, call_ts, call_turn, primary_script, scripts_sorted in find_script_invocations(folded):
        result = tool_results.get(call_id)
        if result is None:
            outcome = "-"
            result_ts = call_ts
        else:
            is_error = bool(result.get("is_error"))
            result_text = tool_result_text(result.get("content"))
            outcome = "fail" if (
                is_error or FAIL_RESULT_RE.search(result_text) or INVOKE_ERROR_CI_RE.search(result_text)
            ) else "pass"
            result_ts = result.get("ts") or call_ts
        call_dur = (result_ts - call_ts).total_seconds() if (call_ts and result_ts) else 0
        tok = turn_tokens(call_turn["usage"])
        call_tokens = sum(tok.values())
        call_usd = usd_cost(call_turn["model"], tok, prices, warned_models)
        # cause reused as a selftest marker; a lint-shaped command is already
        # excluded by find_script_invocations, so no "lint" marker is needed.
        cause = "selftest" if INVOKE_SELFTEST_PATH_RE.search(primary_script) else "-"
        events.append(make_event(
            ts=call_ts, script=primary_script, scripts=scripts_sorted,
            event="invoke", cause=cause, outcome=outcome, round_="-",
            session=session_id, agent_id=agent_id, agent_type=agent_type or "-",
            model=call_turn["model"], turns=1, tokens=call_tokens,
            usd=call_usd, duration_s=call_dur, findings=zero_findings(),
            ticket="-", source="transcript",
            key="invoke:%s:%s:%s" % (session_id, agent_id, call_id), note="-",
        ))
    return events


def find_owner_wait_starts(folded_turns):
    """Return [(ts, note, tool_use_id_or_None), ...] in turn order for
    every detected owner-wait START in one transcript's folded turns —
    see module docstring "owner_wait events" section for what each `note`
    value means and why the heuristic path is best-effort/UNVERIFIED. A
    turn already carrying a configured trigger tool_use is never ALSO
    matched by the heuristic path, even if it also happens to be the
    transcript's last text-shaped turn — that would double-count one
    moment as two starts."""
    starts = []  # (ts, note, tool_use_id, order) — order drives the sort
    matched_orders = set()
    last_text_entry = None  # (order, ts, combined_text)
    for t in folded_turns:
        texts = []
        for block in t["content"]:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use":
                note = owner_wait_trigger_note(block.get("name") or "")
                if note is not None:
                    starts.append((t["ts"], note, block.get("id"), t["order"]))
                    matched_orders.add(t["order"])
            elif block.get("type") == "text" and isinstance(block.get("text"), str):
                texts.append(block["text"])
        if texts:
            last_text_entry = (t["order"], t["ts"], "\n".join(texts))

    if last_text_entry is not None:
        order, ts, text = last_text_entry
        if order not in matched_orders and HUMAN_STEP_RE.search(text):
            starts.append((ts, "human_step_heuristic", None, order))

    starts.sort(key=lambda s: s[3])
    return [(ts, note, tool_use_id) for ts, note, tool_use_id, _order in starts]


def extract_session_ticket(folded_turns):
    """Best-effort: the first ticket-shaped mention (see TICKET_RE) in any
    text-shaped assistant block across the transcript, in turn order —
    the same TICKET_RE extract_ticket() already applies to a subagent's
    dispatch prompt, used here for a transcript that has no such prompt
    to read (a main-thread owner_wait, or a non-author/reviewer
    subagent). None if no ticket is mentioned anywhere in the
    transcript's own text."""
    for t in folded_turns:
        for block in t["content"]:
            if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
                m = TICKET_RE.search(block["text"])
                if m:
                    return m.group(0)
    return None


def build_owner_wait_events(jsonl_path, session_id, agent_id, agent_type, warnings, ticket_hint=None):
    """Return one `owner_wait` event per (start, end) pair found in the
    transcript at jsonl_path — see module docstring "owner_wait events"
    section for the field reuse and the detection signals. `end` is the
    next "type":"user" line in the SAME file after a start; a start with
    no following user line yet (still open at extraction time) produces
    no event — it is picked up on a later extract run once it has one.
    Never raises — a missing/unreadable transcript surfaces only via
    `warnings`, same as every other read in this file."""
    sub_warnings = []
    folded = fold_turns(jsonl_path, sub_warnings)
    warnings.extend(sub_warnings)

    starts = find_owner_wait_starts(folded)
    if not starts:
        return []

    user_line_ts = []
    for _lineno, d in read_jsonl_lines(jsonl_path, warnings):
        if d.get("type") == "user":
            ts = line_timestamp(d)
            if ts is not None:
                user_line_ts.append(ts)
    user_line_ts.sort()

    ticket = ticket_hint if ticket_hint and ticket_hint != "-" else (extract_session_ticket(folded) or "-")

    events = []
    for idx, (start_ts, note, tool_use_id) in enumerate(starts):
        if start_ts is None:
            warnings.append("%s: an owner_wait start has no parseable timestamp, skipped" % jsonl_path)
            continue
        end_ts = next((u for u in user_line_ts if u > start_ts), None)
        if end_ts is None:
            continue
        seconds = (end_ts - start_ts).total_seconds()
        events.append(make_event(
            ts=start_ts, script="-", scripts=[], event="owner_wait",
            cause="-", outcome="-", round_="-", session=session_id,
            agent_id=agent_id, agent_type=agent_type or "-", model="-",
            turns=0, tokens=0, usd=0.0, duration_s=seconds,
            findings=zero_findings(), ticket=ticket, source="transcript",
            key="owner_wait:%s:%s:%s" % (session_id, agent_id, tool_use_id or ("heuristic-%d" % idx)),
            note=note,
        ))
    return events


def discover_sessions(projects_dir):
    """Return a list of (slug, session_id, session_path) for every parent
    session transcript directly under <projects_dir>/<slug>/ (i.e. NOT
    inside a "subagents" directory)."""
    sessions = []
    for entry in sorted(os.listdir(projects_dir)):
        slug_dir = os.path.join(projects_dir, entry)
        if not os.path.isdir(slug_dir):
            continue
        for fn in sorted(os.listdir(slug_dir)):
            if not fn.endswith(".jsonl"):
                continue
            path = os.path.join(slug_dir, fn)
            if not os.path.isfile(path):
                continue
            session_id = fn[: -len(".jsonl")]
            sessions.append((entry, session_id, path))
    return sessions


def discover_subagents(projects_dir, slug, session_id):
    """Return a list of (agent_id, jsonl_path, meta_path) for every
    subagent under <projects_dir>/<slug>/<session_id>/subagents/."""
    sub_dir = os.path.join(projects_dir, slug, session_id, "subagents")
    if not os.path.isdir(sub_dir):
        return []
    out = []
    for fn in sorted(os.listdir(sub_dir)):
        if not (fn.startswith("agent-") and fn.endswith(".jsonl")):
            continue
        agent_id = fn[len("agent-"): -len(".jsonl")]
        jsonl_path = os.path.join(sub_dir, fn)
        meta_path = os.path.join(sub_dir, "agent-%s.meta.json" % agent_id)
        out.append((agent_id, jsonl_path, meta_path))
    return out


def find_session_path(projects_dir, session_id):
    """Locate <projects_dir>/<slug>/<session_id>.jsonl by glob, without
    walking every session — for --session's targeted-scan path. Raises
    ValidationError if zero or more than one match is found."""
    matches = sorted(glob.glob(os.path.join(projects_dir, "*", session_id + ".jsonl")))
    if not matches:
        raise ValidationError(
            "--session %s: no matching session file found under %s" % (session_id, projects_dir)
        )
    if len(matches) > 1:
        raise ValidationError(
            "--session %s: matched more than one session file under %s: %s"
            % (session_id, projects_dir, ", ".join(matches))
        )
    path = matches[0]
    slug = os.path.basename(os.path.dirname(path))
    return slug, session_id, path


def find_subagent_paths(projects_dir, agent_id):
    """Locate every <projects_dir>/<slug>/<session_id>/subagents/agent-<agent_id>.jsonl
    by glob, without walking every session — for --agent-id's targeted-scan
    path (must stay under ~1s on a real store). Raises ValidationError only
    when ZERO matches are found (an unknown id — the hook has nothing to
    process). More than one match is a real but rare collision (the same
    agent_id string happening to exist under two different slugs) and must
    NOT fail the hook invocation: the caller processes every match — each
    carries its own session and therefore its own dedup key — and is
    responsible for naming the collision on stderr. Returns a list of
    (slug, session_id, session_path, agent_id, jsonl_path, meta_path)
    tuples, sorted for determinism; session_path may not exist for a
    given match (the caller warns, not errors, since the subagent
    transcript alone is still processable without the parent's Agent
    tool_use prompt)."""
    pattern = os.path.join(projects_dir, "*", "*", "subagents", "agent-%s.jsonl" % agent_id)
    matches = sorted(glob.glob(pattern))
    if not matches:
        raise ValidationError(
            "--agent-id %s: no matching subagent file found under %s" % (agent_id, projects_dir)
        )
    out = []
    for jsonl_path in matches:
        sub_dir = os.path.dirname(jsonl_path)
        session_dir = os.path.dirname(sub_dir)
        session_id = os.path.basename(session_dir)
        slug_dir = os.path.dirname(session_dir)
        slug = os.path.basename(slug_dir)
        session_path = os.path.join(slug_dir, session_id + ".jsonl")
        meta_path = os.path.join(sub_dir, "agent-%s.meta.json" % agent_id)
        out.append((slug, session_id, session_path, agent_id, jsonl_path, meta_path))
    return out


def load_meta(meta_path, warnings):
    if not os.path.isfile(meta_path):
        warnings.append("%s: missing meta.json" % meta_path)
        return None
    try:
        with open(meta_path, "r", encoding="utf-8", errors="replace") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        warnings.append("%s: ERROR reading meta.json: %s" % (meta_path, exc))
        return None
    if not isinstance(data, dict):
        warnings.append("%s: meta.json is not a JSON object" % meta_path)
        return None
    return data


def make_event(ts, script, scripts, event, cause, outcome, round_, session,
                agent_id, agent_type, model, turns, tokens, usd, duration_s,
                findings, ticket, source, key, note):
    return {
        "ts": fmt_ts(ts) if isinstance(ts, datetime) else (ts or "-"),
        "script": script or "-",
        "scripts": scripts or [],
        "event": event,
        "cause": cause,
        "outcome": outcome,
        "round": round_,
        "session": session,
        "agent_id": agent_id,
        "agent_type": agent_type,
        "model": model or "-",
        "turns": turns,
        "tokens": tokens,
        "usd": round(usd, 6),
        "duration_s": duration_s,
        "findings": findings,
        "ticket": ticket,
        "source": source,
        "key": key,
        "note": note or "-",
    }


def dump_event(ev):
    return json.dumps({k: ev[k] for k in EVENT_KEYS}, ensure_ascii=False, sort_keys=False)


def read_existing_events(events_path):
    """Return the list of event dicts already in events_path, in file
    order. A missing file is an empty list, not an error. A line that
    fails to parse, or parses without a "key" field, is skipped and named
    on stderr (never silent — a corrupt events file miscounting rounds is
    worse than one reported)."""
    events = []
    if not os.path.isfile(events_path):
        return events
    with open(events_path, "r", encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, start=1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                d = json.loads(raw)
            except json.JSONDecodeError:
                print("warning: %s:%d: not valid JSON, skipped" % (events_path, lineno), file=sys.stderr)
                continue
            if not isinstance(d, dict) or "key" not in d:
                print("warning: %s:%d: missing 'key' field, skipped" % (events_path, lineno), file=sys.stderr)
                continue
            events.append(d)
    return events


def existing_max_round(existing_events, session_id, script):
    """Highest "round" already recorded for an author event on (session_id,
    script) in the events file — the basis for round numbering that stays
    correct across incremental --agent-id/--session extractions run one
    subagent at a time by a hook, not just a single full-session scan."""
    best = 0
    for e in existing_events:
        if (
            e.get("event") == "author"
            and e.get("session") == session_id
            and e.get("script") == script
            and isinstance(e.get("round"), int)
            and e["round"] > best
        ):
            best = e["round"]
    return best


def next_round(round_state, existing_events, session_id, script):
    """Return the next 1-based round number for (session_id, script),
    seeding round_state from the events file's own recorded rounds the
    first time this key is seen in a run, then incrementing in memory for
    every subsequent author event processed in the same run."""
    key = (session_id, script)
    if key not in round_state:
        round_state[key] = existing_max_round(existing_events, session_id, script)
    round_state[key] += 1
    return round_state[key]


def process_subagent(slug, session_id, session_path, agent_id, jsonl_path,
                      meta_path, agent_type_map, prices, warned_models,
                      warnings, round_state, existing_events):
    """Return a list of event dicts (author/review plus any nested
    lint/selftest events) for one subagent transcript, or [] if its
    agentType is not in agent_type_map (including the case where meta.json
    is missing/unreadable — a hook that fires for every subagent must exit
    0 and write nothing for a non-script agent, not error)."""
    meta = load_meta(meta_path, warnings)

    # Collected for EVERY subagent transcript regardless of agentType, so this
    # must precede the agent_type_map early-return below.
    invoke_events = build_invoke_events(
        jsonl_path, session_id, agent_id, meta.get("agentType") if meta else None,
        warnings, prices, warned_models,
    )

    # Same reasoning as invoke_events above, so also before the early-return.
    # `ticket_hint` is None here; build_owner_wait_events() falls back to its
    # own best-effort scan of the transcript text.
    owner_wait_events = build_owner_wait_events(
        jsonl_path, session_id, agent_id, meta.get("agentType") if meta else None,
        warnings,
    )

    if meta is None:
        return invoke_events + owner_wait_events
    agent_type = meta.get("agentType")
    if agent_type not in agent_type_map:
        return invoke_events + owner_wait_events
    event_kind = agent_type_map[agent_type]

    tool_use_id = meta.get("toolUseId")
    prompt = ""
    description = meta.get("description") or ""
    requested_model = meta.get("model")
    if tool_use_id:
        if os.path.isfile(session_path):
            session_turns = fold_turns(session_path, warnings)
            for tuid, tinput, _ts in find_agent_tool_calls(session_turns):
                if tuid == tool_use_id:
                    prompt = tinput.get("prompt") or ""
                    description = tinput.get("description") or description
                    requested_model = tinput.get("model") or requested_model
                    break
        else:
            warnings.append(
                "%s: parent session file not found — prompt/ticket/script fields will be empty"
                % session_path
            )

    primary_script, scripts_sorted = extract_scripts(prompt, description)
    ticket = extract_ticket(prompt)
    if ticket and ticket != "-":
        # Re-derive owner_wait_events with the real ticket, replacing the "-"
        # fallback computed above before this attribution was known.
        owner_wait_events = build_owner_wait_events(
            jsonl_path, session_id, agent_id, agent_type, warnings, ticket_hint=ticket,
        )

    sub_warnings = []
    folded = fold_turns(jsonl_path, sub_warnings)
    warnings.extend(sub_warnings)

    first_ts, last_ts = file_timespan(jsonl_path, warnings)

    # Resume-as-rework: a SendMessage resume appends to the SAME transcript
    # rather than spawning a new one, so it never produced its own author
    # event. Each resume SLICES the transcript, so the author event covers
    # only up to the FIRST resume and the slices sum to the whole.
    resumes = []
    if event_kind == "author" and primary_script != "-":
        for resume_ts, resume_text in find_resume_prompts(jsonl_path, warnings):
            if resume_ts is None:
                warnings.append(
                    "%s: a resume prompt has no parseable timestamp, skipped" % jsonl_path
                )
                continue
            resumes.append((resume_ts, resume_text))

    boundary_ts = [r[0] for r in resumes]
    slice_starts = [first_ts] + boundary_ts
    slice_ends = boundary_ts + [None]

    def slice_stats(idx):
        window = turns_in_window(folded, slice_starts[idx], slice_ends[idx])
        w_turns, w_tokens, w_usd, w_model = sum_turns(window, prices, warned_models)
        end_ts = slice_ends[idx] if slice_ends[idx] is not None else last_ts
        start_ts = slice_starts[idx]
        w_duration = (end_ts - start_ts).total_seconds() if (start_ts and end_ts) else 0
        return w_turns, w_tokens, w_usd, (w_model or requested_model), w_duration

    turns, tokens, usd, model, duration_s = slice_stats(0)

    events = []

    round_ = "-"
    cause = "-"
    # Unattributed events (primary_script "-") must never seed or consume a
    # round counter, or they corrupt a real script's round numbering in the
    # same session. round_state is keyed by (session, script).
    if event_kind == "author" and primary_script != "-":
        round_ = next_round(round_state, existing_events, session_id, primary_script)
        if round_ > 1:
            cause = infer_cause(prompt)

    findings = zero_findings()
    if event_kind == "review":
        findings = parse_findings(folded)

    events.append(make_event(
        ts=first_ts, script=primary_script, scripts=scripts_sorted,
        event=event_kind, cause=cause, outcome="-", round_=round_,
        session=session_id, agent_id=agent_id, agent_type=agent_type,
        model=model, turns=turns, tokens=tokens, usd=usd,
        duration_s=duration_s, findings=findings, ticket=ticket,
        source="transcript", key=agent_id, note="-",
    ))

    for n, (resume_ts, resume_text) in enumerate(resumes, start=1):
        r_turns, r_tokens, r_usd, r_model, r_duration = slice_stats(n)
        r_round = next_round(round_state, existing_events, session_id, primary_script)
        r_cause = infer_cause(resume_text)
        events.append(make_event(
            ts=resume_ts, script=primary_script, scripts=scripts_sorted,
            event="rework", cause=r_cause, outcome="-", round_=r_round,
            session=session_id, agent_id=agent_id, agent_type=agent_type,
            model=r_model, turns=r_turns, tokens=r_tokens, usd=r_usd,
            duration_s=r_duration, findings=zero_findings(), ticket=ticket,
            source="transcript", key="%s:resume:%d" % (agent_id, n), note="-",
        ))

    if event_kind == "author":
        tool_results = collect_tool_results(jsonl_path, warnings)
        for call_id, command, call_ts, call_turn in find_lint_selftest_calls(folded):
            is_selftest = bool(SELFTEST_CMD_RE.search(command))
            sub_event = "selftest" if is_selftest else "lint"
            result = tool_results.get(call_id)
            if result is None:
                outcome = "-"
                result_ts = call_ts
            else:
                is_error = bool(result.get("is_error"))
                result_text = tool_result_text(result.get("content"))
                outcome = "fail" if (is_error or FAIL_RESULT_RE.search(result_text)) else "pass"
                result_ts = result.get("ts") or call_ts
            call_dur = (result_ts - call_ts).total_seconds() if (call_ts and result_ts) else 0
            tok = turn_tokens(call_turn["usage"])
            call_tokens = sum(tok.values())
            call_usd = usd_cost(call_turn["model"], tok, prices, warned_models)
            events.append(make_event(
                ts=call_ts, script=primary_script, scripts=scripts_sorted,
                event=sub_event, cause="-", outcome=outcome, round_="-",
                session=session_id, agent_id=agent_id, agent_type=agent_type,
                model=call_turn["model"], turns=1, tokens=call_tokens,
                usd=call_usd, duration_s=call_dur, findings=zero_findings(),
                ticket=ticket, source="transcript",
                key="%s:%s" % (agent_id, call_id), note="-",
            ))

    return events + invoke_events + owner_wait_events


# Derives `status_duration` events from the Jira changelog, read-only via
# `jira-api.sh raw GET`. One event per status occupied; an "open" row (end =
# `--until`) is REWRITTEN in place on re-run, or its duration would freeze at
# whatever `--until` was first observed.

# Jira REST timestamps use a colon-less UTC offset ("...+0000"), which
# datetime.fromisoformat only accepts from Python 3.11; this repo's floor is
# 3.9, so the colon is inserted before handing off to parse_iso.
JIRA_TZ_OFFSET_RE = re.compile(r"([+-]\d{2})(\d{2})$")


def parse_jira_ts(s, label):
    m = JIRA_TZ_OFFSET_RE.search(s)
    text = s[: m.start()] + m.group(1) + ":" + m.group(2) if m else s
    return parse_iso(text, label)


def redact_diag_text(text):
    """Best-effort redaction of jira-api.sh's own stderr before it lands
    in `warnings` (source review round 2, MEDIUM) — the same two signals
    note_is_credential_shaped uses above, applied as a substitution
    instead of a boolean check."""
    if not text:
        return text
    text = LONG_TOKEN_RE.sub("<redacted>", text)

    def _kv(m):
        key = m.group(1)
        if any(word and word in key.lower() for word in SECRET_WORDS):
            return "%s=<redacted>" % key
        return m.group(0)

    return KEYVALUE_RE.sub(_kv, text)


def run_jira_raw(jira_api, method, path, warnings):
    """Call `jira_api raw <method> <path>` and return the parsed JSON
    response, or None on any failure (bad exit, timeout, unparseable
    stdout) — never raises. Failures are named on `warnings`, redacted.

    NW_DRY_RUN=1 (this script's own convention, matching provider.sh)
    passes --dry-run through to jira-api.sh instead: no credential is
    resolved, jira-api.sh prints the exact request it WOULD issue to
    stderr and exits 0, which this prints straight through rather than
    treating as a failure — the caller sees [] transitions and status-
    durations still exits 0."""
    dry = os.environ.get("NW_DRY_RUN") == "1"
    argv = [jira_api]
    if dry:
        argv.append("--dry-run")
    argv += ["raw", method, path]
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        warnings.append("%s %s: failed to invoke jira-api.sh: %s" % (method, path, exc))
        return None
    if dry:
        if proc.stderr:
            print(redact_diag_text(proc.stderr.strip()), file=sys.stderr)
        return None
    if proc.returncode != 0:
        warnings.append(
            "%s %s: jira-api.sh exited %d: %s"
            % (method, path, proc.returncode, redact_diag_text(proc.stderr.strip()))
        )
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        warnings.append("%s %s: response was not valid JSON: %s" % (method, path, exc))
        return None


def fetch_status_changelog(jira_api, ticket, warnings):
    """Return a list of (ts, from_status, to_status) tuples, SORTED by
    parsed timestamp ascending (source review round 2, HIGH: entries are
    not guaranteed to arrive in chronological order, and walking them
    out-of-order silently produced a negative duration and a duplicated
    status under two different keys). [] on any failure or on a ticket
    with no status changes. Does not paginate: a response reporting
    isLast=false, OR carrying a "total" greater than the number of values
    actually returned (source review round 2, MEDIUM — isLast is
    sometimes absent entirely), is named on `warnings`; only the one page
    returned is read either way."""
    data = run_jira_raw(jira_api, "GET", "/issue/%s/changelog" % ticket, warnings)
    if data is None:
        return []
    values = data.get("values")
    if not isinstance(values, list):
        warnings.append("%s: changelog response has no \"values\" list" % ticket)
        return []
    total = data.get("total")
    if data.get("isLast") is False or (isinstance(total, int) and total > len(values)):
        warnings.append(
            "%s: changelog has more than one page (isLast=false or total=%s > "
            "%d returned) — only the returned page was read, status-durations "
            "does not paginate" % (ticket, total, len(values))
        )
    transitions = []
    for entry in values:
        if not isinstance(entry, dict):
            continue
        ts_str = entry.get("created")
        items = entry.get("items")
        if not ts_str or not isinstance(items, list):
            continue
        for item in items:
            if isinstance(item, dict) and item.get("field") == "status":
                from_status = item.get("fromString")
                to_status = item.get("toString")
                if to_status:
                    transitions.append((ts_str, from_status, to_status))
    transitions.sort(key=lambda t: parse_jira_ts(t[0], "ts"))
    return transitions


def fetch_created(jira_api, ticket, warnings):
    """Return the ticket's `created` timestamp string, or None on any
    failure or missing field — never raises."""
    data = run_jira_raw(jira_api, "GET", "/issue/%s?fields=created" % ticket, warnings)
    if data is None:
        return None
    fields = data.get("fields")
    return fields.get("created") if isinstance(fields, dict) else None


def build_status_duration_events(ticket, transitions, created_str, until_dt, warnings):
    """Return one `status_duration` event per status the ticket occupied,
    per the module comment above. `transitions` is
    fetch_status_changelog()'s (ts, from_status, to_status) list, already
    sorted ascending. The ticket's FIRST status (before the first
    changelog entry) is timed from `created_str` to the first transition's
    own timestamp, using that transition's `from_status` as the status
    name — skipped, named on `warnings`, when `created_str` is unavailable
    (never guessed). Every later status runs from its own transition's
    timestamp to the NEXT transition's timestamp, or to `until_dt` for the
    ticket's current (last) status.

    `outcome` is reused (source review round 2, HIGH) to mark a row's
    finality: "closed" for a status whose end came from a REAL transition
    (never changes again once written), "open" for the still-current
    status whose end is `until_dt` — inherently provisional, since the
    ticket may move on or a later run may pass a later `until_dt`. See
    reconcile_status_duration_events() for how "open" rows get corrected.

    A negative computed duration_s (a mis-ordered or duplicate changelog
    entry that survived the sort above, or an `until_dt` earlier than the
    ticket's last transition) is refused for THAT row only — named on
    `warnings`, not written, never silently negative."""
    if not transitions:
        return []

    parsed = [
        (parse_jira_ts(ts, "ts"), from_status, to_status)
        for ts, from_status, to_status in transitions
    ]

    events = []

    first_ts, first_from, _first_to = parsed[0]
    if created_str and first_from:
        created_ts = parse_jira_ts(created_str, "created")
        duration_s = (first_ts - created_ts).total_seconds()
        if duration_s < 0:
            warnings.append(
                "%s: skipped initial status '%s' — created timestamp is AFTER "
                "the first changelog entry (negative duration), not written"
                % (ticket, first_from)
            )
        else:
            events.append(make_event(
                ts=created_ts, script="-", scripts=[], event="status_duration",
                cause="-", outcome="closed", round_=None, session="-", agent_id="-",
                agent_type="-", model="-", turns=0, tokens=0, usd=0.0,
                duration_s=duration_s,
                findings=zero_findings(), ticket=ticket, source="jira_changelog",
                key="status_duration:%s:%s:%s" % (ticket, first_from, fmt_ts(created_ts)),
                note=first_from,
            ))
    else:
        warnings.append(
            "%s: initial status (before the first changelog entry) cannot be "
            "timed without a 'created' timestamp — skipped, not guessed" % ticket
        )

    for idx, (ts, _from_status, to_status) in enumerate(parsed):
        is_open = idx + 1 >= len(parsed)
        end_ts = parsed[idx + 1][0] if not is_open else until_dt
        duration_s = (end_ts - ts).total_seconds()
        if duration_s < 0:
            warnings.append(
                "%s: skipped status '%s' at %s — computed a negative duration "
                "(%s), not written" % (ticket, to_status, fmt_ts(ts), duration_s)
            )
            continue
        events.append(make_event(
            ts=ts, script="-", scripts=[], event="status_duration",
            cause="-", outcome=("open" if is_open else "closed"), round_=None,
            session="-", agent_id="-", agent_type="-", model="-",
            turns=0, tokens=0, usd=0.0, duration_s=duration_s,
            findings=zero_findings(), ticket=ticket, source="jira_changelog",
            key="status_duration:%s:%s:%s" % (ticket, to_status, fmt_ts(ts)),
            note=to_status,
        ))

    return events


def reconcile_status_duration_events(events_path, computed_events, existing_events, dry_run):
    """Merge freshly computed status_duration events against the file's
    existing ones (source review round 2, HIGH). Plain idempotent-by-key
    append silently protected a STALE duration for the ticket's still-open
    status: its duration_s is frozen at whatever --until was when first
    observed, and a later run (the ticket having since transitioned, or
    --until having moved forward) never corrected it — the key alone
    doesn't change, so it was never treated as new. `outcome` (see
    build_status_duration_events) distinguishes the two cases: a "closed"
    row is immutable once written; an "open" row is REWRITTEN IN PLACE
    whenever its recomputed duration_s or outcome differs from what's on
    file. Returns (appended, updated) event lists; writes to `events_path`
    only when dry_run is False, and never touches a non-status_duration
    line."""
    existing_by_key = {
        e["key"]: e for e in existing_events if e.get("event") == "status_duration"
    }

    appended = []
    updates = {}
    for ev in computed_events:
        key = ev["key"]
        prev = existing_by_key.get(key)
        if prev is None:
            appended.append(ev)
        elif prev.get("outcome") == "open" and (
            prev.get("duration_s") != ev.get("duration_s") or prev.get("outcome") != ev.get("outcome")
        ):
            updates[key] = ev
        # else: prev is "closed" (immutable) or unchanged — no-op.

    if dry_run:
        return appended, list(updates.values())

    if updates and os.path.isfile(events_path):
        with open(events_path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
        rewritten = []
        for line in lines:
            stripped = line.strip()
            if not stripped:
                rewritten.append(line)
                continue
            try:
                d = json.loads(stripped)
            except json.JSONDecodeError:
                rewritten.append(line)
                continue
            key = d.get("key")
            rewritten.append(dump_event(updates[key]) + "\n" if key in updates else line)
        # Atomic replace, not truncate-in-place: open(..., "w") truncates
        # before writing, so an interruption loses the WHOLE file. The temp
        # file must be in the SAME directory for os.replace to be atomic.
        dir_name = os.path.dirname(os.path.abspath(events_path)) or "."
        fd, tmp_path = tempfile.mkstemp(prefix=".script-events-", suffix=".tmp", dir=dir_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.writelines(rewritten)
            os.replace(tmp_path, events_path)
        except BaseException:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise

    if appended:
        with open(events_path, "a", encoding="utf-8") as fh:
            for ev in appended:
                fh.write(dump_event(ev) + "\n")

    return appended, list(updates.values())


def cmd_status_durations(args):
    if not os.path.isfile(args.jira_api):
        raise ValidationError("--jira-api: cannot find jira-api.sh at %s" % args.jira_api)

    for ticket in args.ticket:
        if not TICKET_RE.fullmatch(ticket):
            raise ValidationError("ticket must look like PROJECT-123, got %s" % ticket)

    until_dt = parse_jira_ts(args.until, "--until") if args.until else datetime.now(timezone.utc)

    existing_events = read_existing_events(args.events)

    warnings = []
    computed_by_key = {}

    # One bad ticket must not abort a multi-ticket run.
    for ticket in args.ticket:
        try:
            transitions = fetch_status_changelog(args.jira_api, ticket, warnings)
            created_str = fetch_created(args.jira_api, ticket, warnings) if transitions else None
            for ev in build_status_duration_events(ticket, transitions, created_str, until_dt, warnings):
                computed_by_key[ev["key"]] = ev
        except ValidationError as exc:
            warnings.append("%s: skipped entirely — %s" % (ticket, exc))
            continue

    computed_events = list(computed_by_key.values())
    appended, updated = reconcile_status_duration_events(
        args.events, computed_events, existing_events, args.dry_run
    )

    # "already present" counts only rows this run left untouched; the raw
    # pre-run count would double-count a row corrected in place.
    prior_status_durations = sum(1 for e in existing_events if e.get("event") == "status_duration")
    unchanged = prior_status_durations - len(updated)

    if args.dry_run:
        for ev in sorted(appended + updated, key=lambda ev: ev["ts"]):
            print(dump_event(ev))
        print(
            "# status-durations (dry-run): %d new, %d updated, %d already present"
            % (len(appended), len(updated), unchanged)
        )
    else:
        print(
            "# status-durations: %d new, %d updated, %d already present"
            % (len(appended), len(updated), unchanged)
        )

    if warnings:
        print("warning: %d issue(s) while fetching/processing changelogs:" % len(warnings), file=sys.stderr)
        for w in warnings:
            print("  " + w, file=sys.stderr)


def cmd_extract(args):
    if args.agent_id and args.session:
        raise ValidationError("--agent-id and --session are mutually exclusive")
    if not os.path.isdir(args.projects_dir):
        raise ValidationError("--projects-dir does not exist: %s" % args.projects_dir)

    since = parse_iso(args.since, "--since") if args.since else None
    until = parse_iso(args.until, "--until") if args.until else None

    agent_type_map = dict(DEFAULT_AGENT_TYPE_MAP)
    if args.agent_types:
        for name in args.agent_types.split(","):
            name = name.strip()
            if not name:
                continue
            agent_type_map[name] = "review" if "review" in name.lower() else "author"

    prices = load_prices(args.prices)
    warned_models = set()
    existing_events = read_existing_events(args.events)
    existing_keys = {e["key"] for e in existing_events}

    warnings = []
    new_events = []
    seen_keys_this_run = set()
    round_state = {}

    if args.agent_id:
        # Resolve by glob only, never walking every session under
        # --projects-dir. An agent_id collision across slugs is processed as
        # multiple batches, not a failure.
        matches = find_subagent_paths(args.projects_dir, args.agent_id)
        if len(matches) > 1:
            print(
                "warning: --agent-id %s matched %d subagent files across different "
                "sessions (collision) — processing all of them: %s"
                % (args.agent_id, len(matches), ", ".join(m[4] for m in matches)),
                file=sys.stderr,
            )
        subagent_batches = [
            (slug, session_id, session_path, [(agent_id, jsonl_path, meta_path)])
            for slug, session_id, session_path, agent_id, jsonl_path, meta_path in matches
        ]
    elif args.session:
        slug, session_id, session_path = find_session_path(args.projects_dir, args.session)
        subagent_batches = [(slug, session_id, session_path, discover_subagents(args.projects_dir, slug, session_id))]
    else:
        subagent_batches = [
            (slug, session_id, session_path, discover_subagents(args.projects_dir, slug, session_id))
            for slug, session_id, session_path in discover_sessions(args.projects_dir)
        ]

    def add_events(evs):
        for ev in evs:
            if ev["key"] in existing_keys or ev["key"] in seen_keys_this_run:
                continue
            if since and ev["ts"] != "-" and parse_iso(ev["ts"], "ts") < since:
                continue
            if until and ev["ts"] != "-" and parse_iso(ev["ts"], "ts") >= until:
                continue
            seen_keys_this_run.add(ev["key"])
            new_events.append(ev)

    for slug, session_id, session_path, subagents in subagent_batches:
        # The top-level session transcript is never seen by process_subagent(),
        # so a main-thread Bash tool_use needs its own pass. isfile() guards a
        # targeted scan whose parent session file is missing.
        if os.path.isfile(session_path):
            add_events(build_invoke_events(session_path, session_id, "-", "main", warnings, prices, warned_models))
            # Main-thread owner_wait scan — same rationale as the invoke scan.
            add_events(build_owner_wait_events(session_path, session_id, "-", "main", warnings))

        # Chronological order matters for round assignment: sort subagents
        # by their own transcript's first timestamp before processing.
        ordered = []
        for agent_id, jsonl_path, meta_path in subagents:
            first_ts, _last_ts = file_timespan(jsonl_path, warnings)
            ordered.append((first_ts or datetime.min.replace(tzinfo=timezone.utc), agent_id, jsonl_path, meta_path))
        ordered.sort(key=lambda t: t[0])

        for _first_ts, agent_id, jsonl_path, meta_path in ordered:
            evs = process_subagent(
                slug, session_id, session_path, agent_id, jsonl_path,
                meta_path, agent_type_map, prices, warned_models, warnings,
                round_state, existing_events,
            )
            add_events(evs)

    new_events.sort(key=lambda ev: ev["ts"])

    if args.dry_run:
        if new_events or not args.quiet:
            for ev in new_events:
                print(dump_event(ev))
            print("# extract (dry-run): %d new, %d already present" % (len(new_events), len(existing_keys)))
    else:
        if new_events:
            with open(args.events, "a", encoding="utf-8") as fh:
                for ev in new_events:
                    fh.write(dump_event(ev) + "\n")
        if new_events or not args.quiet:
            print("# extract: %d new, %d already present" % (len(new_events), len(existing_keys)))

    if warnings:
        print("warning: %d issue(s) while scanning transcripts:" % len(warnings), file=sys.stderr)
        for w in warnings:
            print("  " + w, file=sys.stderr)


RECORDABLE_EVENTS = ("live-run", "accepted")


def cmd_record(args):
    if args.event not in RECORDABLE_EVENTS:
        raise ValidationError(
            "--event must be one of %s (manual recording is restricted to these)"
            % ", ".join(RECORDABLE_EVENTS)
        )
    if not args.events.endswith(".jsonl"):
        raise ValidationError("--events must end in .jsonl")
    if args.ticket is not None and not TICKET_RE.match(args.ticket):
        raise ValidationError("--ticket must look like PROJECT-123")

    ts = parse_iso(args.ts, "--ts") if args.ts else datetime.now(timezone.utc)
    ts_str = fmt_ts(ts)
    note = args.note if args.note else "-"
    if "\t" in note or "\n" in note:
        raise ValidationError("--note must not contain a tab or newline")
    if note != "-" and note_is_credential_shaped(note):
        raise ValidationError(
            "--note looks credential-shaped (a long token, or a key=value pair "
            "whose key matches a known secret word) — refusing to write it into "
            "a git-committed events file"
        )

    # Normalize the same way extract does: a manually `record`ed event is
    # where a stale or bare path shows up in practice.
    script = normalize_script_path(args.script)

    ev = make_event(
        ts=ts, script=script, scripts=[script] if script != "-" else [],
        event=args.event, cause="-", outcome=args.outcome, round_="-",
        session="-", agent_id="-", agent_type="-", model="-",
        turns=0, tokens=0, usd=0.0, duration_s=0,
        findings=zero_findings(), ticket=args.ticket or "-", source="manual",
        key="manual:%s:%s:%s" % (ts_str, script, args.event), note=note,
    )

    with open(args.events, "a", encoding="utf-8") as fh:
        fh.write(dump_event(ev) + "\n")
    print("# record: appended %s %s for %s" % (args.event, args.outcome, script))


def cmd_backfill_script_paths(args):
    """One-time (but re-runnable — a future script move needs this again)
    normalization of every already-written `script`/`scripts` value in
    args.events to its CURRENT repo-relative path, via
    normalize_script_path() — the same resolution extract/record now
    apply going forward. Rewrites the file IN PLACE (unless --dry-run),
    preserving every line's original key order and every OTHER field
    verbatim; a line that isn't valid JSON, or carries no "script" field
    at all, is copied through unchanged. Never touches an owner_wait line
    (script is already "-" there, so normalize_script_path leaves it
    alone)."""
    if not os.path.isfile(args.events):
        raise ValidationError("--events file does not exist: %s" % args.events)

    with open(args.events, "r", encoding="utf-8") as fh:
        raw_lines = fh.readlines()

    out_lines = []
    changed = 0
    skipped = 0
    for lineno, raw in enumerate(raw_lines, start=1):
        stripped = raw.strip()
        if not stripped:
            out_lines.append(raw)
            continue
        try:
            d = json.loads(stripped)
        except json.JSONDecodeError:
            print("warning: %s:%d: not valid JSON, left unchanged" % (args.events, lineno), file=sys.stderr)
            skipped += 1
            out_lines.append(raw)
            continue
        if not isinstance(d, dict):
            skipped += 1
            out_lines.append(raw)
            continue

        line_changed = False
        script = d.get("script")
        if script and script != "-":
            new_script = normalize_script_path(script)
            if new_script != script:
                d["script"] = new_script
                line_changed = True
        scripts = d.get("scripts")
        if isinstance(scripts, list) and scripts:
            new_scripts = sorted({normalize_script_path(s) for s in scripts})
            if new_scripts != scripts:
                d["scripts"] = new_scripts
                line_changed = True

        if line_changed:
            changed += 1
            out_lines.append(json.dumps(d, ensure_ascii=False) + "\n")
        else:
            out_lines.append(raw)

    if args.dry_run:
        print(
            "# backfill-script-paths (dry-run): %d line(s) would change, %d unparsable "
            "line(s) left as-is, %d total" % (changed, skipped, len(raw_lines))
        )
        return

    if changed:
        with open(args.events, "w", encoding="utf-8") as fh:
            fh.writelines(out_lines)
    print(
        "# backfill-script-paths: %d line(s) changed, %d unparsable line(s) left as-is, "
        "%d total" % (changed, skipped, len(raw_lines))
    )


def load_events(events_path, script_filter, since, until, warnings):
    if not os.path.isfile(events_path):
        raise ValidationError("--events file does not exist: %s" % events_path)
    events = []
    with open(events_path, "r", encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, start=1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                d = json.loads(raw)
            except json.JSONDecodeError:
                warnings.append("%s:%d: not valid JSON, skipped" % (events_path, lineno))
                continue
            if not isinstance(d, dict):
                warnings.append("%s:%d: not a JSON object, skipped" % (events_path, lineno))
                continue
            if script_filter and d.get("script") != script_filter:
                continue
            ts = d.get("ts")
            if since and ts and ts != "-" and parse_iso(ts, "ts") < since:
                continue
            if until and ts and ts != "-" and parse_iso(ts, "ts") >= until:
                continue
            events.append(d)
    return events


# Whether a script is actually being RUN, as opposed to cheap to author. A
# separate code path so `report`'s default table stays untouched.
def usage_flag(non_test_invokes, landing_ts, until_ts):
    """One of "keep" | "retire?" | "flag" | "-", by the following
    PRECEDENCE (there is no combining of these three independent
    thresholds — this is a fixed order):
      1. >=10 lifetime non-test invocations wins outright as "keep",
         regardless of how recently the script landed.
      2. Otherwise, once >=15 days have elapsed since landing: "retire?"
         if fewer than 5 non-test invocations landed within those first
         15 days, else "-" (elapsed long enough, cleared the bar — no
         flag from the 7-day check is layered on top).
      3. Otherwise, once >=7 days have elapsed since landing: "flag" if
         fewer than 3 non-test invocations landed within those first 7
         days, else "-".
      4. Otherwise (fewer than 7 days elapsed): "-" — not enough time has
         passed to judge usage at all.
    landing_ts is None (no author/accepted event on record for this
    script within the queried window) always returns "-"."""
    if landing_ts is None:
        return "-"
    elapsed_days = (until_ts - landing_ts).total_seconds() / 86400.0

    def count_within(days):
        cutoff = landing_ts + timedelta(days=days)
        n = 0
        for e in non_test_invokes:
            ts = e.get("ts")
            if not ts or ts == "-":
                continue
            ev_ts = parse_iso(ts, "ts")
            if landing_ts <= ev_ts < cutoff:
                n += 1
        return n

    if len(non_test_invokes) >= 10:
        return "keep"
    if elapsed_days >= 15:
        return "retire?" if count_within(15) < 5 else "-"
    if elapsed_days >= 7:
        return "flag" if count_within(7) < 3 else "-"
    return "-"


def build_usage_rows(full_events, until_ts, row_since=None, row_until=None):
    """Return (rows, window_rework_ratio) for `report --usage`.

    `full_events` MUST be the events file's FULL contents, unfiltered by
    --since/--until. The `flag` column and the landing date it depends on
    are always LIFETIME figures, computed from a script's entire history,
    regardless of `row_since`/`row_until` — this is the retirement-verdict
    use case, and it must never move just because a wave's window
    changed. Truncating the INPUT events by --since/--until would let
    changing --until silently change a script's own "lifetime" invocation
    count and its keep/retire verdict — e.g. narrowing --until past a
    script's `author` event would drop that event out of the window
    entirely, voiding BOTH the authoring-session exclusion (its session no
    longer excludes anything) and the landing date (falling back to None,
    silently printing flag "-" with no signal the window had caused it).

    Every OTHER displayed column (invocations, sessions, pass/fail,
    first/last-used, lint/selftest/rework counts, lint wall clock,
    author_usd, rework_ratio) IS windowed by `row_since`/`row_until` when
    either is given: only events whose own `ts`
    falls inside [row_since, row_until) feed those numbers, so a wave's
    `--usage` call reports this-wave activity, not the script's whole
    history. With no window given, every event qualifies and these
    columns keep lifetime behaviour (unwindowed output stays
    byte-identical to before this ticket).

    A script ROW is included if it has at least one event anywhere in
    [row_since, row_until) — same gate as before this ticket — even
    though the row's OTHER numbers (not `flag`) are now computed from
    that windowed event subset, not from the script's whole history.

    The "non-test invocations" definition (see module docstring) is
    applied HERE, not at extraction: an `invoke` event with cause
    "selftest", agent_type "script-author"/"script-reviewer", or a
    session matching one of the script's own `author` events (the
    authoring session) is excluded from every column below, so a
    script's own build/review/selftest traffic never inflates its usage
    number. The authoring-session exclusion SET itself is always derived
    from a script's LIFETIME `author` events, window or no window — a
    wave whose window happens to exclude the original `author` event must
    not stop excluding that session's own dogfood invocations."""
    by_script = {}
    for ev in full_events:
        script = ev.get("script") or "-"
        if script == "-":
            continue
        # A selftest file is never a real usage signal — see
        # USAGE_SELFTEST_FILE_RE.
        if USAGE_SELFTEST_FILE_RE.search(script):
            continue
        by_script.setdefault(script, []).append(ev)

    authoring_sessions = {}
    for script, evs in by_script.items():
        authoring_sessions[script] = {
            e.get("session") for e in evs
            if e.get("event") == "author" and e.get("session") and e.get("session") != "-"
        }

    rows = []
    total_rework_cost = 0.0
    total_author_usd = 0.0

    def in_row_window(e):
        if row_since is None and row_until is None:
            return True
        ts = e.get("ts")
        if not ts or ts == "-":
            return False
        ev_ts = parse_iso(ts, "ts")
        if row_since is not None and ev_ts < row_since:
            return False
        if row_until is not None and ev_ts >= row_until:
            return False
        return True

    for script in sorted(by_script.keys()):
        evs = by_script[script]

        if row_since is not None or row_until is not None:
            if not any(in_row_window(e) for e in evs):
                continue

        # `evs` stays lifetime and feeds the landing date and flag; `w_evs`
        # is windowed and feeds every OTHER column.
        w_evs = [e for e in evs if in_row_window(e)]

        authors = [e for e in evs if e.get("event") == "author"]
        accepted = sorted(
            (e for e in evs if e.get("event") == "accepted" and e.get("outcome") == "pass"),
            key=lambda e: e.get("ts") or "",
        )
        lifetime_invokes = [e for e in evs if e.get("event") == "invoke"]

        w_invokes = [e for e in w_evs if e.get("event") == "invoke"]
        w_authors = [e for e in w_evs if e.get("event") == "author"]
        w_reviews = [e for e in w_evs if e.get("event") == "review"]
        w_reworks = [e for e in w_evs if e.get("event") == "rework"]
        w_lints = [e for e in w_evs if e.get("event") == "lint"]
        w_selftests = [e for e in w_evs if e.get("event") == "selftest"]

        my_sessions = authoring_sessions.get(script, set())

        def is_non_test(e):
            return (
                e.get("cause") != "selftest"
                and e.get("agent_type") not in ("script-author", "script-reviewer")
                and e.get("session") not in my_sessions
            )

        # `flag` reads the LIFETIME non-test invocations, window or no
        # window (see docstring) — every other column below reads the
        # WINDOWED subset.
        lifetime_non_test_invokes = [e for e in lifetime_invokes if is_non_test(e)]
        non_test_invokes = [e for e in w_invokes if is_non_test(e)]

        invocations = len(non_test_invokes)
        sessions = len({e.get("session") for e in non_test_invokes if e.get("session") and e.get("session") != "-"})
        passes = sum(1 for e in non_test_invokes if e.get("outcome") == "pass")
        fails = sum(1 for e in non_test_invokes if e.get("outcome") == "fail")
        used_ts = sorted(e.get("ts") for e in non_test_invokes if e.get("ts") and e.get("ts") != "-")
        first_used = used_ts[0] if used_ts else "-"
        last_used = used_ts[-1] if used_ts else "-"

        lint_runs = len(w_lints)
        selftest_runs = len(w_selftests)
        rework_rounds = len(w_reworks)
        lint_wall_clock = sum(e.get("duration_s", 0) or 0 for e in w_lints)

        # rework_ratio = usd(rework+lint+review+selftest) / usd(author).
        # Windowed, so a wave's ratio reflects that wave's spend.
        author_usd = sum(e.get("usd", 0.0) or 0.0 for e in w_authors)
        rework_cost = sum(e.get("usd", 0.0) or 0.0 for e in (w_reworks + w_lints + w_reviews + w_selftests))
        rework_ratio = (rework_cost / author_usd) if author_usd else None
        total_rework_cost += rework_cost
        total_author_usd += author_usd

        # Earliest `accepted`, falling back to earliest `author`. Always
        # LIFETIME: the retirement verdict must not move with the window.
        landing_ts_str = accepted[0].get("ts") if accepted else None
        if not landing_ts_str:
            author_ts_list = sorted(e.get("ts") for e in authors if e.get("ts") and e.get("ts") != "-")
            landing_ts_str = author_ts_list[0] if author_ts_list else None
        landing_ts = parse_iso(landing_ts_str, "ts") if landing_ts_str else None

        flag = usage_flag(lifetime_non_test_invokes, landing_ts, until_ts)

        rows.append([
            script, invocations, sessions, passes, fails, first_used, last_used,
            lint_runs, selftest_runs, rework_rounds,
            "%.1f" % lint_wall_clock, "%.4f" % author_usd,
            ("%.2f" % rework_ratio if rework_ratio is not None else "-"),
            flag,
        ])

    window_ratio = (total_rework_cost / total_author_usd) if total_author_usd else None
    return rows, window_ratio


def build_owner_wait_rows(full_events, row_since, row_until):
    """Return (rows, total_seconds) for `report --usage`'s owner_wait
    summary: `full_events` MUST be the events file's FULL contents, same
    reason as build_usage_rows() — an owner_wait event's own `ts` is what
    row_since/row_until gate against here, mirroring how a script ROW is
    gated there. `rows` is one [ticket, seconds] pair per distinct ticket
    seen in the window (sorted by seconds, descending), plus a final
    ["total", seconds] row — the wave total, alongside the per-ticket
    breakdown."""
    by_ticket = {}
    total = 0.0
    for ev in full_events:
        if ev.get("event") != "owner_wait":
            continue
        ts = ev.get("ts")
        if not ts or ts == "-":
            continue
        ev_ts = parse_iso(ts, "ts")
        if row_since is not None and ev_ts < row_since:
            continue
        if row_until is not None and ev_ts >= row_until:
            continue
        seconds = ev.get("duration_s", 0) or 0
        ticket = ev.get("ticket") or "-"
        by_ticket[ticket] = by_ticket.get(ticket, 0.0) + seconds
        total += seconds

    rows = sorted(
        ([ticket, "%.1f" % seconds] for ticket, seconds in by_ticket.items()),
        key=lambda r: -float(r[1]),
    )
    rows.append(["total", "%.1f" % total])
    return rows, total


def count_tickets_landed(full_events, since, until):
    """Return the count of distinct tickets with an `accepted`/pass event
    in [since, until) — the numerator for
    "tickets landed per owner-attended hour" (see docs/cost.md). Windowed
    on its own input the same way build_ticket_cost_rows() is: with no
    since/until, every accepted/pass event ever recorded counts
    (lifetime), matching --usage's own no-window default elsewhere in
    this file."""
    tickets = set()
    for ev in full_events:
        if ev.get("event") != "accepted" or ev.get("outcome") != "pass":
            continue
        ticket = ev.get("ticket")
        if not ticket or ticket == "-":
            continue
        ts = ev.get("ts")
        if since and ts and ts != "-" and parse_iso(ts, "ts") < since:
            continue
        if until and ts and ts != "-" and parse_iso(ts, "ts") >= until:
            continue
        tickets.add(ticket)
    return len(tickets)


# "What did THIS TICKET cost", grouped by (ticket, session, agent_type) across
# author/review/rework only. Windowed, unlike build_usage_rows() above.
def build_ticket_cost_rows(full_events, since, until):
    groups = {}
    for ev in full_events:
        if ev.get("event") not in ("author", "review", "rework"):
            continue
        ticket = ev.get("ticket")
        if not ticket or ticket == "-":
            continue
        ts = ev.get("ts")
        if since and ts and ts != "-" and parse_iso(ts, "ts") < since:
            continue
        if until and ts and ts != "-" and parse_iso(ts, "ts") >= until:
            continue
        key = (ticket, ev.get("session") or "-", ev.get("agent_type") or "-")
        groups[key] = groups.get(key, 0.0) + (ev.get("usd", 0.0) or 0.0)

    rows = [
        [ticket, session, agent_type, "%.4f" % usd]
        for (ticket, session, agent_type), usd in groups.items()
    ]
    rows.sort(key=lambda r: (r[0], -float(r[3])))
    return rows


def cmd_report(args):
    since = parse_iso(args.since, "--since") if args.since else None
    until = parse_iso(args.until, "--until") if args.until else None
    warnings = []

    if args.usage:
        # Deliberately NOT load_events(..., since, until, ...): --usage needs
        # the FULL file for lifetime counts, so the window is a row filter only.
        full_events = load_events(args.events, args.script, None, None, warnings)
        until_ts = until or datetime.now(timezone.utc)
        rows, window_ratio = build_usage_rows(full_events, until_ts, since, until)
        headers = [
            "script", "invocations", "sessions", "pass", "fail",
            "first_used", "last_used", "lint_runs", "selftest_runs",
            "rework_rounds", "lint_wall_clock_s", "author_usd",
            "rework_ratio", "flag",
        ]
        renderer = RENDERERS[args.format]
        print(renderer(headers, rows))
        print("")

        # Owner-attended seconds per ticket in this window, plus a wave total.
        # Computed here so the wave-summary line below can read that total.
        wait_rows, wait_total = build_owner_wait_rows(full_events, since, until)

        # `window rework_ratio` prints unconditionally; `owner_wait_s` and
        # `tickets_per_owner_hour` are wave-scoped with no lifetime
        # equivalent, so they are gated on a window actually being given.
        print("# window rework_ratio: %s" % ("%.2f" % window_ratio if window_ratio is not None else "-"))
        if since is not None or until is not None:
            owner_hours = wait_total / 3600.0
            tickets_landed = count_tickets_landed(full_events, since, until)
            tickets_per_hour = (tickets_landed / owner_hours) if owner_hours > 0 else None
            print("# window owner_wait_s: %.1f" % wait_total)
            print(
                "# window tickets_per_owner_hour: %s"
                % ("%.2f" % tickets_per_hour if tickets_per_hour is not None else "-")
            )

        print("")
        print("# owner_wait summary (window, seconds by ticket)")
        print(renderer(["ticket", "owner_wait_seconds"], wait_rows))

        ticket_rows = build_ticket_cost_rows(full_events, since, until)
        print("")
        print("# per-ticket cost")
        print(renderer(["ticket", "session", "agent_type", "cost_usd"], ticket_rows))

        if warnings:
            print("warning: %d issue(s) while reading events file:" % len(warnings), file=sys.stderr)
            for w in warnings:
                print("  " + w, file=sys.stderr)
        return

    events = load_events(args.events, args.script, since, until, warnings)

    # `invoke` and `status_duration` carry script="-" like `owner_wait`, so
    # grouping them here produces a bogus all-zero `script: -` row.
    by_script = {}
    for ev in events:
        if ev.get("event") in ("invoke", "status_duration"):
            continue
        by_script.setdefault(ev.get("script") or "-", []).append(ev)

    rows = []
    for script, evs in by_script.items():
        authors = [e for e in evs if e.get("event") == "author"]
        reworks = [e for e in evs if e.get("event") == "rework"]
        reviews = [e for e in evs if e.get("event") == "review"]
        lints = [e for e in evs if e.get("event") == "lint"]
        selftests = [e for e in evs if e.get("event") == "selftest"]
        accepted = sorted(
            [e for e in evs if e.get("event") == "accepted" and e.get("outcome") == "pass"],
            key=lambda e: e.get("ts") or "",
        )

        # A resumed subagent's extra rounds spawn a `rework` event, never a new
        # `author` one, so counting authors alone reports rounds=1.
        round_pool = authors + reworks
        rounds = max([e.get("round") for e in round_pool if isinstance(e.get("round"), int)], default=0)
        rework_review = sum(1 for e in round_pool if e.get("cause") == "review")
        rework_lint = sum(1 for e in round_pool if e.get("cause") == "lint")
        rework_usage = sum(1 for e in round_pool if e.get("cause") == "usage")
        lint_fails = sum(1 for e in lints if e.get("outcome") == "fail")
        selftest_fails = sum(1 for e in selftests if e.get("outcome") == "fail")

        crit = sum(e.get("findings", {}).get("critical", 0) for e in reviews)
        high = sum(e.get("findings", {}).get("high", 0) for e in reviews)
        med = sum(e.get("findings", {}).get("medium", 0) for e in reviews)
        low = sum(e.get("findings", {}).get("low", 0) for e in reviews)

        # The author event covers only the slice up to the first resume and
        # each rework its own, so the three together sum to the whole.
        countable = authors + reviews + reworks
        turns = sum(e.get("turns", 0) or 0 for e in countable)
        tokens = sum(e.get("tokens", 0) or 0 for e in countable)
        usd = sum(e.get("usd", 0.0) or 0.0 for e in countable)

        author_ts = sorted(e.get("ts") for e in authors if e.get("ts") and e.get("ts") != "-")
        first_author = author_ts[0] if author_ts else "-"
        accepted_ts = accepted[0].get("ts") if accepted else None

        minutes_to_accept = "-"
        if first_author != "-" and accepted_ts:
            delta = parse_iso(accepted_ts, "ts") - parse_iso(first_author, "ts")
            minutes_to_accept = "%.1f" % (delta.total_seconds() / 60.0)

        sessions = sorted({e.get("session") for e in evs if e.get("session") and e.get("session") != "-"})

        rows.append([
            script, rounds, rework_review, rework_lint, rework_usage,
            lint_fails, selftest_fails, len(reviews), crit, high, med, low,
            turns, tokens, "%.4f" % usd, first_author,
            (accepted_ts or "-"), minutes_to_accept, len(sessions),
        ])
        rows[-1] = (rows[-1], usd)

    rows.sort(key=lambda pair: -pair[1])
    rows = [r for r, _usd in rows]

    headers = [
        "script", "rounds", "rework_review", "rework_lint", "rework_usage",
        "lint_fails", "selftest_fails", "reviews", "crit", "high", "med",
        "low", "turns", "tokens", "usd", "first_author", "accepted",
        "minutes_to_accept", "sessions",
    ]

    by_agent = {}
    for ev in events:
        if ev.get("event") not in ("author", "review", "rework"):
            continue
        agent_type = ev.get("agent_type") or "-"
        g = by_agent.setdefault(agent_type, {"invocations": 0, "turns": 0, "tokens": 0, "usd": 0.0})
        g["invocations"] += 1
        g["turns"] += ev.get("turns", 0) or 0
        g["tokens"] += ev.get("tokens", 0) or 0
        g["usd"] += ev.get("usd", 0.0) or 0.0

    agent_headers = ["agent_type", "invocations", "turns", "tokens", "usd", "mean_turns_per_invocation"]
    agent_rows = []
    for agent_type, g in sorted(by_agent.items(), key=lambda kv: -kv[1]["usd"]):
        mean_turns = (g["turns"] / g["invocations"]) if g["invocations"] else 0.0
        agent_rows.append([
            agent_type, g["invocations"], g["turns"], g["tokens"],
            "%.4f" % g["usd"], "%.2f" % mean_turns,
        ])

    renderer = RENDERERS[args.format]
    print(renderer(headers, rows))
    print("")
    print("# per-agent-type summary")
    print(renderer(agent_headers, agent_rows))

    if warnings:
        print("warning: %d issue(s) while reading events file:" % len(warnings), file=sys.stderr)
        for w in warnings:
            print("  " + w, file=sys.stderr)


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="script-analytics.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_extract = sub.add_parser("extract", help="scan transcripts and append new events")
    p_extract.add_argument("--projects-dir", default=os.path.expanduser("~/.claude/projects"))
    p_extract.add_argument("--since", default=None)
    p_extract.add_argument("--until", default=None)
    p_extract.add_argument("--events", required=True)
    p_extract.add_argument("--prices", default=None, help="price table TSV (default: templates/claude-prices.tsv)")
    p_extract.add_argument("--dry-run", action="store_true", dest="dry_run")
    p_extract.add_argument("--agent-types", default=None,
                            help="comma-separated extra agentType names to include, mapped to "
                                 "review if the name contains 'review', else author")
    p_extract.add_argument("--session", default=None,
                            help="restrict the scan to one session id (found by locating "
                                 "<projects-dir>/*/<ID>.jsonl), instead of walking every session")
    p_extract.add_argument("--agent-id", default=None,
                            help="restrict the scan to one subagent id (found by locating "
                                 "<projects-dir>/*/*/subagents/agent-<ID>.jsonl); mutually "
                                 "exclusive with --session; for a SubagentStop hook invocation")
    p_extract.add_argument("--quiet", action="store_true",
                            help="print nothing on stdout when 0 new events are found; the "
                                 "summary line still prints when new events are found")

    p_record = sub.add_parser("record", help="append one manual live-run/accepted event")
    p_record.add_argument("--events", required=True)
    p_record.add_argument("--script", required=True)
    p_record.add_argument("--event", required=True, choices=RECORDABLE_EVENTS)
    p_record.add_argument("--outcome", required=True, choices=("pass", "fail"))
    p_record.add_argument("--note", default=None)
    p_record.add_argument("--ticket", default=None)
    p_record.add_argument("--ts", default=None)

    p_report = sub.add_parser("report", help="summarise events by script and agent type")
    p_report.add_argument("--events", required=True)
    p_report.add_argument("--script", default=None)
    p_report.add_argument("--since", default=None)
    p_report.add_argument("--until", default=None)
    p_report.add_argument("--format", choices=sorted(RENDERERS.keys()), default="table")
    p_report.add_argument("--usage", action="store_true",
                           help="print the per-script usage table (invocations, pass/fail, "
                                "lint/selftest/rework counts, rework_ratio, retirement flag) "
                                "instead of the default author/review/lint report")

    p_status = sub.add_parser("status-durations",
                               help="derive status_duration events from the tracker's changelog")
    p_status.add_argument("ticket", nargs="+",
                           help="ticket key (e.g. PROJ-123); one or more")
    p_status.add_argument("--events", default=os.path.join(HERE, "..", "docs", "script-events.jsonl"),
                           help="default: docs/script-events.jsonl")
    p_status.add_argument("--jira-api",
                           default=os.path.join(HERE, "..", "providers", "tracker", "jira", "jira-api.sh"),
                           dest="jira_api",
                           help="path to jira-api.sh (default: providers/tracker/jira/jira-api.sh)")
    p_status.add_argument("--until", default=None,
                           help="ISO timestamp bounding the ticket's current/last status "
                                "duration; defaults to now")
    p_status.add_argument("--dry-run", action="store_true", dest="dry_run",
                           help="print what would be appended/updated, write nothing")

    p_backfill = sub.add_parser(
        "backfill-script-paths",
        help="normalize every recorded script/scripts value to its current repo-relative "
             "path (basename lookup against the real scripts/hooks tree) — rerun after a "
             "script moves directories, not just once",
    )
    p_backfill.add_argument("--events", required=True)
    p_backfill.add_argument("--dry-run", action="store_true", dest="dry_run")

    return parser.parse_args(argv)


def validate_events_path(path):
    if not path.endswith(".jsonl"):
        raise ValidationError("--events path must end in .jsonl")


def main(argv):
    try:
        args = parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code not in (0, None) else 0

    try:
        validate_events_path(args.events)
        if args.cmd == "extract":
            cmd_extract(args)
        elif args.cmd == "record":
            cmd_record(args)
        elif args.cmd == "report":
            cmd_report(args)
        elif args.cmd == "status-durations":
            cmd_status_durations(args)
        elif args.cmd == "backfill-script-paths":
            cmd_backfill_script_paths(args)
        else:
            raise ValidationError("unknown subcommand: %s" % args.cmd)
    except ValidationError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 2
    except Exception as exc:  # noqa: BLE001 - deliberate catch-all boundary
        print("unexpected error: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
