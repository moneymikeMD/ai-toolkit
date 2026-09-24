#!/bin/bash
#
# Selftest for script-analytics.py. Builds a scratch fixture transcript
# tree (parent session + two subagents + meta.json files, one
# script-author with a mid-flight SendMessage resume, one
# script-reviewer, one non-matching agent type) under a tmpdir and runs
# extract/record/report against it — never reads a real
# ~/.claude/projects tree.
#
# Usage: scripts/script-analytics-selftest.sh [path-to-script-analytics.py]
# Defaults to the sibling scripts/script-analytics.py. Pass an older revision
# to run the NWM-156 cases red against it.
#
# claude-cost.py and claude-cost-scan.py are OPTIONAL here (NWM-156): the
# script under test no longer loads them, and only the drift-parity section
# needs them. When they are absent that section is skipped, not failed.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ANALYTICS="${1:-$HERE/script-analytics.py}"

# A selftest that asserts dollar amounts must pin its own prices rather than
# float on whatever table the host repo ships, or a price edit reddens it.
# Every standalone case below strips this again with `env -u`.
export CLAUDE_PRICES_TSV="${CLAUDE_PRICES_TSV:-$HERE/fixtures/claude-prices.tsv}"
[ -r "$ANALYTICS" ] || { echo "cannot read $ANALYTICS" >&2; exit 2; }

CC_PY="$HERE/claude-cost.py"
CS_PY="$HERE/claude-cost-scan.py"
PARITY=1
if [ ! -r "$CC_PY" ] || [ ! -r "$CS_PY" ]; then
  PARITY=0
fi

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

# ---- NWM-160: the sentinel a consumer greps for before invoking --------
# night-watchman's script-events-hook.sh refuses to run a resolved
# script-analytics.py that lacks this line, so removing it darkens the hook.
if grep -q '^# script-analytics-extractor-sentinel: v1' "$ANALYTICS"; then
  ok "sentinel line is present for consumers to verify the extractor by"
else
  bad "sentinel line missing: script-events-hook.sh would refuse this extractor"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PROJECTS_DIR="$WORK/projects"
EVENTS="$WORK/script-events.jsonl"

run() { python3 "$ANALYTICS" "$@"; }

# ---- Build the fixture transcript tree ---------------------------------
python3 - "$PROJECTS_DIR" << 'PYEOF'
import json
import os
import sys

projects_dir = sys.argv[1]
slug = "-fixture-repo"
session_id = "sess1"
slug_dir = os.path.join(projects_dir, slug)
sub_dir = os.path.join(slug_dir, session_id, "subagents")
os.makedirs(sub_dir, exist_ok=True)

def w(path, lines):
    with open(path, "a", encoding="utf-8") as fh:
        for d in lines:
            fh.write(json.dumps(d) + "\n")

def assistant(ts, msg_id, output_tokens, content):
    return {
        "type": "assistant",
        "timestamp": ts,
        "message": {
            "id": msg_id,
            "model": "claude-sonnet-5",
            "usage": {"input_tokens": 50, "output_tokens": output_tokens,
                      "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
            "content": content,
        },
    }

def user_text(ts, text):
    return {"type": "user", "timestamp": ts, "message": {"content": [{"type": "text", "text": text}]}}

def user_tool_result(ts, tool_use_id, is_error, text):
    return {
        "type": "user", "timestamp": ts,
        "message": {"content": [{"type": "tool_result", "tool_use_id": tool_use_id,
                                  "is_error": is_error, "content": text}]},
    }

# --- Parent session: two Agent tool_use blocks (author + reviewer) -----
author_prompt = ("PROJ-42: port scripts/script-analytics.py, following the "
                  "convention in scripts/lib/kit.sh")
review_prompt = "PROJ-42: review scripts/script-analytics.py"
session_path = os.path.join(slug_dir, session_id + ".jsonl")
w(session_path, [
    assistant("2026-09-13T10:00:00Z", "parent-m1", 10, [
        {"type": "tool_use", "id": "toolu_1", "name": "Agent",
         "input": {"prompt": author_prompt, "description": "port script-analytics.py",
                    "model": "claude-sonnet-5"}},
    ]),
    assistant("2026-09-13T10:05:00Z", "parent-m2", 10, [
        {"type": "tool_use", "id": "toolu_2", "name": "Agent",
         "input": {"prompt": review_prompt, "description": "review script-analytics.py",
                    "model": "claude-sonnet-5"}},
    ]),
])

# --- Author subagent: dedup (2 lines, 1 message.id), a Bash selftest
# call, and a SendMessage resume that becomes a rework event. -----------
author_id = "author1"
author_meta = os.path.join(sub_dir, "agent-%s.meta.json" % author_id)
with open(author_meta, "w", encoding="utf-8") as fh:
    json.dump({"agentType": "script-author", "description": "port script-analytics.py",
               "toolUseId": "toolu_1", "spawnDepth": 1, "model": "claude-sonnet-5"}, fh)

author_path = os.path.join(sub_dir, "agent-%s.jsonl" % author_id)
w(author_path, [
    user_text("2026-09-13T10:00:01Z", author_prompt),  # the dispatch brief (excluded from resumes)
    # Same message.id "m1" on two lines: a two-tool_use turn split across
    # lines, plus the dedup-by-message.id proof (one turn, not two).
    assistant("2026-09-13T10:00:10Z", "m1", 100, [{"type": "text", "text": "working"}]),
    assistant("2026-09-13T10:00:12Z", "m1", 150, [
        {"type": "tool_use", "id": "toolu_bash1", "name": "Bash",
         "input": {"command": "scripts/script-analytics-selftest.sh"}},
    ]),
    user_tool_result("2026-09-13T10:00:20Z", "toolu_bash1", False, "15 passed, 0 failed"),
    # Resume: SendMessage appends to the SAME transcript. Cause heuristic
    # should read "review" before "lint" (REVIEW_CAUSE_RE checked first).
    user_text("2026-09-13T10:01:00Z", "PROJ-42: review flagged 2 HIGH issues, please fix (lint)."),
    assistant("2026-09-13T10:01:30Z", "m2", 80, [{"type": "text", "text": "fixed"}]),
])

# --- Reviewer subagent: findings heuristics (path-prefixed CRITICAL,
# negated HIGH, counted MEDIUM) in one text block. ------------------------
review_id = "review1"
review_meta = os.path.join(sub_dir, "agent-%s.meta.json" % review_id)
with open(review_meta, "w", encoding="utf-8") as fh:
    json.dump({"agentType": "script-reviewer", "description": "review script-analytics.py",
               "toolUseId": "toolu_2", "spawnDepth": 1, "model": "claude-sonnet-5"}, fh)

review_path = os.path.join(sub_dir, "agent-%s.jsonl" % review_id)
w(review_path, [
    user_text("2026-09-13T10:05:01Z", review_prompt),
    assistant("2026-09-13T10:05:30Z", "r1", 200, [
        {"type": "text", "text": (
            "scripts/script-analytics.py:42 - CRITICAL - missing validation\n"
            "no HIGH severity issues found\n"
            "2 MEDIUM findings noted"
        )},
    ]),
])

# --- Non-matching agent type: extract must skip it entirely. ------------
triage_id = "triage1"
triage_meta = os.path.join(sub_dir, "agent-%s.meta.json" % triage_id)
with open(triage_meta, "w", encoding="utf-8") as fh:
    json.dump({"agentType": "triage", "description": "unrelated", "toolUseId": "toolu_3"}, fh)
triage_path = os.path.join(sub_dir, "agent-%s.jsonl" % triage_id)
w(triage_path, [assistant("2026-09-13T10:06:00Z", "t1", 5, [{"type": "text", "text": "n/a"}])])

# --- NWM-164: a Workflow-tool subagent lives TWO LEVELS DEEPER, under
# subagents/workflows/wf_<id>/, and a journal.jsonl sits beside it that is
# not a transcript and must never be counted as one.
wf_dir = os.path.join(sub_dir, "workflows", "wf_fixture1")
os.makedirs(wf_dir, exist_ok=True)
wf_id = "wfagent1"
with open(os.path.join(wf_dir, "agent-%s.meta.json" % wf_id), "w", encoding="utf-8") as fh:
    json.dump({"agentType": "script-author", "description": "authored inside a Workflow run",
               "toolUseId": "toolu_wf1", "spawnDepth": 1, "model": "claude-sonnet-5"}, fh)
wf_path = os.path.join(wf_dir, "agent-%s.jsonl" % wf_id)
w(wf_path, [
    assistant("2026-09-13T10:07:00Z", "wf1", 100, [
        {"type": "tool_use", "id": "toolu_wfbash", "name": "Bash",
         "input": {"command": "scripts/workflow-only-widget.sh --check"}},
    ]),
    user_tool_result("2026-09-13T10:07:05Z", "toolu_wfbash", False, "ok"),
])

# Same directory, same .jsonl suffix, not a transcript. Given content that
# WOULD register if it were ever scanned, so the assertion that it is absent
# can fail rather than merely being untested.
w(os.path.join(wf_dir, "journal.jsonl"), [
    assistant("2026-09-13T10:07:30Z", "journal1", 999, [
        {"type": "tool_use", "id": "toolu_journal", "name": "Bash",
         "input": {"command": "scripts/journal-must-not-appear.sh"}},
    ]),
])
PYEOF

# extract: full-session scan

run extract --projects-dir "$PROJECTS_DIR" --events "$EVENTS" >/dev/null
if [ -s "$EVENTS" ]; then
  ok "extract: writes events to $EVENTS"
else
  bad "extract: expected events to be written to $EVENTS"
fi

N_EVENTS=$(wc -l < "$EVENTS" | tr -d ' ')
# author + rework + lint/selftest + review = 4, plus that same Bash call's own
# `invoke` event = 5; triage contributes 0. The Workflow-tool subagent adds an
# author and an invoke of its own (NWM-164) = 7 — those two were the missing
# population, so the count going up is the fix, not a fixture accident.
if [ "$N_EVENTS" = "7" ]; then
  ok "extract: exactly 7 events (5 flat + the Workflow-tool subagent's 2); triage skipped"
else
  bad "extract: expected 7 events, got $N_EVENTS ($(cat "$EVENTS"))"
fi

if python3 -c "
import json
events = [json.loads(l) for l in open('$EVENTS')]
inv = [e for e in events if e['event'] == 'invoke']
assert len(inv) == 2, 'expected 2 invoke events (author + workflow), got %d' % len(inv)
e = [x for x in inv if x['agent_id'] == 'author1'][0]
assert e['script'] == 'scripts/script-analytics-selftest.sh', e['script']
assert e['cause'] == 'selftest', e['cause']
assert e['outcome'] == 'pass', e['outcome']
assert e['agent_type'] == 'script-author', e['agent_type']
assert e['key'] == 'invoke:sess1:author1:toolu_bash1', e['key']
"; then
  ok "extract: the author's own selftest Bash call also produces its own invoke event, cause=selftest"
else
  bad "extract: selftest-call invoke event assertion failed"
fi

if python3 -c "
import json, sys
found = False
for line in open('$EVENTS'):
    d = json.loads(line)
    if d['event'] == 'author' and d['script'] == 'scripts/script-analytics.py':
        found = True
sys.exit(0 if found else 1)
"; then
  ok "extract: primary script excludes the reference path (scripts/lib/kit.sh)"
else
  bad "extract: reference-script exclusion failed"
fi

if python3 -c "
import json
events = [json.loads(l) for l in open('$EVENTS')]
rework = [e for e in events if e['event'] == 'rework']
assert len(rework) == 1, 'expected exactly 1 rework event, got %d' % len(rework)
r = rework[0]
assert r['round'] == 2, 'expected rework round=2, got %r' % r['round']
assert r['cause'] == 'review', 'expected rework cause=review, got %r' % r['cause']
"; then
  ok "extract: SendMessage resume becomes a round-2 rework event, cause=review"
else
  bad "extract: resume-as-rework assertion failed"
fi

if python3 -c "
import json
events = [json.loads(l) for l in open('$EVENTS')]
author = [e for e in events if e['event'] == 'author'][0]
assert author['turns'] == 1, 'author turn count should be 1 (dedup by message.id), got %r' % author['turns']
"; then
  ok "extract: two lines sharing message.id fold into one turn (dedup)"
else
  bad "extract: message.id dedup assertion failed"
fi

if python3 -c "
import json
events = [json.loads(l) for l in open('$EVENTS')]
selftest = [e for e in events if e['event'] == 'selftest'][0]
assert selftest['outcome'] == 'pass', 'expected selftest outcome=pass, got %r' % selftest['outcome']
"; then
  ok "extract: Bash selftest call outcome read from its tool_result"
else
  bad "extract: selftest outcome assertion failed"
fi

if python3 -c "
import json
events = [json.loads(l) for l in open('$EVENTS')]
review = [e for e in events if e['event'] == 'review'][0]
f = review['findings']
assert f['critical'] == 1, 'expected critical=1 (path-prefixed), got %r' % f['critical']
assert f['high'] == 0, 'expected high=0 (negated by \"no\"), got %r' % f['high']
assert f['medium'] == 2, 'expected medium=2 (count-prefixed \"2 MEDIUM\"), got %r' % f['medium']
"; then
  ok "extract: findings heuristics (path-prefix, negation, count-prefix) all correct"
else
  bad "extract: findings heuristics assertion failed"
fi

# extract: idempotent re-run, --quiet

OUT2="$(run extract --projects-dir "$PROJECTS_DIR" --events "$EVENTS" --quiet)"
if [ -z "$OUT2" ]; then
  ok "extract: --quiet prints nothing when 0 new events are found"
else
  bad "extract: --quiet should have printed nothing on re-run (got: $OUT2)"
fi
N_EVENTS2=$(wc -l < "$EVENTS" | tr -d ' ')
if [ "$N_EVENTS2" = "$N_EVENTS" ]; then
  ok "extract: idempotent re-run appends nothing new"
else
  bad "extract: idempotent re-run should not have grown the events file ($N_EVENTS -> $N_EVENTS2)"
fi

# extract: --agent-id targets one subagent only

AGENT_EVENTS="$WORK/agent-only.jsonl"
run extract --projects-dir "$PROJECTS_DIR" --events "$AGENT_EVENTS" --agent-id review1 >/dev/null
if python3 -c "
import json
events = [json.loads(l) for l in open('$AGENT_EVENTS')]
assert len(events) == 1 and events[0]['event'] == 'review', 'expected exactly 1 review event, got %r' % events
"; then
  ok "extract: --agent-id restricts the scan to one subagent"
else
  bad "extract: --agent-id targeting assertion failed"
fi

# extract: an unknown --agent-id is a loud refusal

if run extract --projects-dir "$PROJECTS_DIR" --events "$WORK/nope.jsonl" --agent-id does-not-exist \
    >/dev/null 2>"$WORK/err"; then
  bad "extract: unknown --agent-id should have been refused"
else
  if grep -q "no matching subagent file found" "$WORK/err"; then
    ok "extract: unknown --agent-id is refused with a clear message"
  else
    bad "extract: unknown-agent-id refusal message missing expected text"
  fi
fi

# extract: --agent-id and --session are mutually exclusive

if run extract --projects-dir "$PROJECTS_DIR" --events "$WORK/nope2.jsonl" \
    --agent-id author1 --session sess1 >/dev/null 2>"$WORK/err"; then
  bad "extract: --agent-id + --session together should have been refused"
else
  if grep -q "mutually exclusive" "$WORK/err"; then
    ok "extract: --agent-id/--session mutual exclusivity enforced"
  else
    bad "extract: mutual-exclusivity refusal message missing expected text"
  fi
fi

# extract: a missing --projects-dir is a loud refusal

if run extract --projects-dir "$WORK/does-not-exist" --events "$WORK/nope3.jsonl" \
    >/dev/null 2>"$WORK/err"; then
  bad "extract: missing --projects-dir should have been refused"
else
  if grep -q "does not exist" "$WORK/err"; then
    ok "extract: missing --projects-dir is refused with a clear message"
  else
    bad "extract: missing-projects-dir refusal message missing expected text"
  fi
fi

# record: accepted event, ticket/note validation

run record --events "$EVENTS" --script scripts/script-analytics.py \
  --event accepted --outcome pass --ticket PROJ-42 --note "owner accepted it" >/dev/null
if python3 -c "
import json
events = [json.loads(l) for l in open('$EVENTS')]
assert any(e['event'] == 'accepted' and e['ticket'] == 'PROJ-42' for e in events)
"; then
  ok "record: a valid accepted event is appended"
else
  bad "record: accepted event not found after record"
fi

if run record --events "$EVENTS" --script scripts/script-analytics.py \
    --event accepted --outcome pass --ticket not-a-ticket >/dev/null 2>"$WORK/err"; then
  bad "record: a malformed --ticket should have been refused"
else
  if grep -q "must look like" "$WORK/err"; then
    ok "record: malformed --ticket is refused"
  else
    bad "record: malformed-ticket refusal message missing expected text"
  fi
fi

if run record --events "$EVENTS" --script scripts/script-analytics.py \
    --event accepted --outcome pass --note "$(printf 'line1\tline2')" >/dev/null 2>"$WORK/err"; then
  bad "record: a --note containing a tab should have been refused"
else
  if grep -q "must not contain a tab or newline" "$WORK/err"; then
    ok "record: --note with a tab is refused"
  else
    bad "record: tab-in-note refusal message missing expected text"
  fi
fi

if run record --events "$EVENTS" --script scripts/script-analytics.py \
    --event accepted --outcome pass \
    --note "leaked AKIAABCDEFGHIJKLMNOPQR23456789token" >/dev/null 2>"$WORK/err"; then
  bad "record: a credential-shaped --note should have been refused"
else
  if grep -q "credential-shaped" "$WORK/err"; then
    ok "record: a long-token --note is refused as credential-shaped"
  else
    bad "record: credential-shaped-note refusal message missing expected text"
  fi
fi

# report: rounds/rework/findings/usd surface for the ported script

REPORT_OUT="$(run report --events "$EVENTS" --format tsv)"
if printf '%s\n' "$REPORT_OUT" | awk -F'\t' '$1 == "scripts/script-analytics.py" { print }' | grep -qE $'^scripts/script-analytics.py\t2\t1\t0\t0\t0\t0\t1\t1\t0\t2\t0'; then
  ok "report: rounds=2, rework_review=1, findings crit=1/high=0/med=2 for the ported script"
else
  bad "report: unexpected per-script row (got: $REPORT_OUT)"
fi

if printf '%s\n' "$REPORT_OUT" | grep -q "per-agent-type summary"; then
  ok "report: prints a per-agent-type summary section"
else
  bad "report: per-agent-type summary section missing"
fi

SLUGDIR="$PROJECTS_DIR/-fixture-repo"

# invoke events: main-thread scan, lint.sh exclusion, non-author/reviewer
# subagents, and false-positive guards (grep/wc targets, a heredoc body)

SESS_INV="sess-invoke"
SESS_INV_DIR="$SLUGDIR/$SESS_INV"
SUB_INV_DIR="$SESS_INV_DIR/subagents"
mkdir -p "$SUB_INV_DIR"
cat > "$SLUGDIR/$SESS_INV.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-09-14T09:00:00Z","message":{"id":"i1","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","id":"toolu_main_run","name":"Bash","input":{"command":"./scripts/claude-cost.py list --ledger docs/cost-ledger.tsv"}}]}}
{"type":"user","timestamp":"2026-09-14T09:00:02Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_main_run","is_error":false,"content":"ok"}]}}
{"type":"assistant","timestamp":"2026-09-14T09:01:00Z","message":{"id":"i2","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","id":"toolu_main_lint","name":"Bash","input":{"command":"./scripts/lint.sh"}}]}}
{"type":"user","timestamp":"2026-09-14T09:01:02Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_main_lint","is_error":false,"content":"lint OK"}]}}
{"type":"assistant","timestamp":"2026-09-14T09:02:00Z","message":{"id":"i3","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","id":"toolu_grep","name":"Bash","input":{"command":"grep -c claude-cost.py docs/cost.md"}}]}}
{"type":"user","timestamp":"2026-09-14T09:02:02Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_grep","is_error":false,"content":"3"}]}}
{"type":"assistant","timestamp":"2026-09-14T09:03:00Z","message":{"id":"i4","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","id":"toolu_heredoc","name":"Bash","input":{"command":"cat > /tmp/fixture.jsonl <<'INNEREOF'\n{\"command\":\"scripts/claude-cost.py\"}\nINNEREOF"}}]}}
{"type":"user","timestamp":"2026-09-14T09:03:02Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_heredoc","is_error":false,"content":"ok"}]}}
{"type":"assistant","timestamp":"2026-09-14T09:04:00Z","message":{"id":"i5","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","id":"toolu_prefixed","name":"Bash","input":{"command":"FOO=bar sudo timeout 30 ./scripts/claude-cost-scan.py --repo ."}}]}}
{"type":"user","timestamp":"2026-09-14T09:04:02Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_prefixed","is_error":false,"content":"ok"}]}}
{"type":"assistant","timestamp":"2026-09-14T09:05:00Z","message":{"id":"i6","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","id":"toolu_investigator","name":"Agent","input":{"subagent_type":"triage","description":"check a hook","prompt":"Run hooks/bash-result-shunt.sh and report"}}]}}
EOF
cat > "$SUB_INV_DIR/agent-inv1.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-09-14T09:05:05Z","message":{"id":"q1","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","id":"toolu_sub_bash","name":"Bash","input":{"command":"./hooks/bash-result-shunt.sh --dry-run"}}]}}
{"type":"user","timestamp":"2026-09-14T09:05:07Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_sub_bash","is_error":false,"content":"dry-run ok"}]}}
EOF
cat > "$SUB_INV_DIR/agent-inv1.meta.json" <<'EOF'
{"agentType":"triage","description":"check a hook","toolUseId":"toolu_investigator","spawnDepth":1,"model":"claude-sonnet-5"}
EOF

INVOKE_EVENTS="$WORK/events-invoke.jsonl"
INVOKE_OUT=$(run extract --projects-dir "$PROJECTS_DIR" --session "$SESS_INV" --events "$INVOKE_EVENTS") \
  || { echo "extract --session $SESS_INV failed unexpectedly:" >&2; echo "$INVOKE_OUT" >&2; exit 1; }
INVOKE_CONTENT=$(cat "$INVOKE_EVENTS")
INVOKE_COUNT=$(printf '%s\n' "$INVOKE_CONTENT" | grep -c '"event": "invoke"' || true)

if [ "$INVOKE_COUNT" = "3" ]; then
  ok "invoke: exactly 3 invoke events (main-thread real run, prefixed run, non-author/reviewer subagent run); lint.sh/grep/wc/heredoc produced none"
else
  bad "invoke: expected exactly 3 invoke events, got $INVOKE_COUNT ($INVOKE_CONTENT)"
fi

if printf '%s\n' "$INVOKE_CONTENT" | grep -q '"script": "scripts/claude-cost.py", "scripts": \["scripts/claude-cost.py"\], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "sess-invoke", "agent_id": "-", "agent_type": "main"'; then
  ok "invoke: main-thread Bash call produces its own invoke event, agent_id='-' agent_type='main'"
else
  bad "invoke: main-thread invoke event assertion failed (got: $INVOKE_CONTENT)"
fi

if printf '%s\n' "$INVOKE_CONTENT" | grep -q '"script": "scripts/lint.sh"'; then
  bad "invoke: scripts/lint.sh must never produce its own invoke event"
else
  ok "invoke: scripts/lint.sh never produces an invoke event"
fi

if printf '%s\n' "$INVOKE_CONTENT" | grep -q '"script": "scripts/claude-cost-scan.py".*"agent_id": "-"'; then
  ok "invoke: a VAR=val/sudo/timeout-prefixed command is still detected in executable position"
else
  bad "invoke: prefixed-invocation detection failed (got: $INVOKE_CONTENT)"
fi

if printf '%s\n' "$INVOKE_CONTENT" | grep -q '"script": "hooks/bash-result-shunt.sh".*"agent_id": "inv1", "agent_type": "triage"'; then
  ok "invoke: a non-author/reviewer subagent (agentType=triage) still produces an invoke event"
else
  bad "invoke: non-author/reviewer subagent invoke assertion failed (got: $INVOKE_CONTENT)"
fi

# grep target, wc target, and heredoc-body false positives never fire.
if printf '%s\n' "$INVOKE_CONTENT" | grep -q '"key": "invoke:sess-invoke:-:toolu_grep"' \
  || printf '%s\n' "$INVOKE_CONTENT" | grep -q '"key": "invoke:sess-invoke:-:toolu_heredoc"'; then
  bad "invoke: a grep-target or heredoc-body path must never produce an invoke event"
else
  ok "invoke: a grep TARGET path and a heredoc BODY path never produce invoke events"
fi

# owner_wait events: AskUserQuestion and a configured mcp__spokenly__*
# trigger both start a wait, ending at the next "type":"user" line

SESS_WAIT="sess-wait"
mkdir -p "$SLUGDIR/$SESS_WAIT"
cat > "$SLUGDIR/$SESS_WAIT.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-09-14T10:00:00Z","message":{"id":"w1","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","id":"toolu_ask1","name":"AskUserQuestion","input":{"question":"proceed?"}}]}}
{"type":"user","timestamp":"2026-09-14T10:05:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_ask1","is_error":false,"content":"yes"}]}}
{"type":"assistant","timestamp":"2026-09-14T10:05:10Z","message":{"id":"w2","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","id":"toolu_spoke1","name":"mcp__spokenly__ask_user_dictation","input":{"question":"which option?"}}]}}
{"type":"user","timestamp":"2026-09-14T10:05:40Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_spoke1","is_error":false,"content":"option b"}]}}
EOF

WAIT_EVENTS="$WORK/events-wait.jsonl"
WAIT_OUT=$(run extract --projects-dir "$PROJECTS_DIR" --session "$SESS_WAIT" --events "$WAIT_EVENTS") \
  || { echo "extract --session $SESS_WAIT failed unexpectedly:" >&2; echo "$WAIT_OUT" >&2; exit 1; }
WAIT_CONTENT=$(cat "$WAIT_EVENTS")

if python3 -c "
import json
events = [json.loads(l) for l in open('$WAIT_EVENTS')]
waits = sorted((e for e in events if e['event'] == 'owner_wait'), key=lambda e: e['ts'])
assert len(waits) == 2, 'expected exactly 2 owner_wait events, got %d: %r' % (len(waits), waits)
a, s = waits
assert a['note'] == 'askuser', a
assert a['duration_s'] == 300.0, a
assert s['note'] == 'spokenly', s
assert s['duration_s'] == 30.0, s
for e in waits:
    assert e['script'] == '-' and e['scripts'] == [], e
    assert e['agent_type'] == 'main', e
"; then
  ok "owner_wait: AskUserQuestion (note=askuser, 300s) and a configured mcp__spokenly__* trigger (note=spokenly, 30s) both start/end correctly"
else
  bad "owner_wait: trigger/duration assertion failed (got: $WAIT_CONTENT)"
fi

# path normalization: a bare basename resolves to its current
# repo-relative location, both via `record` and via `backfill-script-paths`

NORM_EVENTS="$WORK/events-norm.jsonl"
NORM_BASE="$(basename "$ANALYTICS")"
run record --events "$NORM_EVENTS" --script "$NORM_BASE" \
  --event accepted --outcome pass --ticket PROJ-42 >/dev/null

if python3 -c "
import json
e = json.loads(open('$NORM_EVENTS').read().strip())
assert e['script'] == 'scripts/$NORM_BASE', e['script']
assert e['scripts'] == ['scripts/$NORM_BASE'], e['scripts']
"; then
  ok "record: a bare basename ($NORM_BASE) is normalized to scripts/$NORM_BASE"
else
  bad "record: bare-basename normalization assertion failed"
fi

BACKFILL_EVENTS="$WORK/events-backfill.jsonl"
BACKFILL_BASE="$(basename "$0")"
cat > "$BACKFILL_EVENTS" <<EOF
{"ts": "2026-09-14T00:00:00Z", "script": "$BACKFILL_BASE", "scripts": ["$BACKFILL_BASE"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "s1", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "backfill-1", "note": "-"}
{"ts": "2026-09-14T00:01:00Z", "script": "-", "scripts": [], "event": "owner_wait", "cause": "-", "outcome": "-", "round": "-", "session": "s1", "agent_id": "-", "agent_type": "main", "model": "-", "turns": 0, "tokens": 0, "usd": 0.0, "duration_s": 5, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "backfill-2", "note": "askuser"}
EOF
BACKFILL_DRY=$(run backfill-script-paths --events "$BACKFILL_EVENTS" --dry-run)
if printf '%s\n' "$BACKFILL_DRY" | grep -q "1 line(s) would change"; then
  ok "backfill-script-paths: --dry-run reports exactly 1 line would change, writes nothing"
else
  bad "backfill-script-paths: --dry-run summary line unexpected (got: $BACKFILL_DRY)"
fi
if grep -q "\"script\": \"$BACKFILL_BASE\"" "$BACKFILL_EVENTS"; then
  ok "backfill-script-paths: --dry-run leaves the events file on disk unchanged"
else
  bad "backfill-script-paths: --dry-run must not have written to the events file"
fi

run backfill-script-paths --events "$BACKFILL_EVENTS" >/dev/null
if python3 -c "
import json
lines = [json.loads(l) for l in open('$BACKFILL_EVENTS')]
inv = [e for e in lines if e['event'] == 'invoke'][0]
wait = [e for e in lines if e['event'] == 'owner_wait'][0]
assert inv['script'] == 'scripts/$BACKFILL_BASE', inv['script']
assert inv['scripts'] == ['scripts/$BACKFILL_BASE'], inv['scripts']
assert inv['key'] == 'backfill-1', 'other fields must be preserved verbatim'
assert wait['script'] == '-', 'an owner_wait line (script already -) must be left alone'
"; then
  ok "backfill-script-paths: rewrites script/scripts in place, preserving every other field, leaving owner_wait alone"
else
  bad "backfill-script-paths: in-place rewrite assertion failed"
fi

# report --usage: selftest-fixture exclusion, authoring-session/agent-type/
# selftest-cause exclusions, and the keep/flag/retire? threshold precedence

USAGE_EVENTS="$WORK/events-usage.jsonl"
cat > "$USAGE_EVENTS" <<'EOF'
{"ts": "2026-09-01T00:00:00Z", "script": "scripts/fixture-a.sh", "scripts": ["scripts/fixture-a.sh"], "event": "author", "cause": "-", "outcome": "-", "round": 1, "session": "auth-a", "agent_id": "a-a", "agent_type": "script-author", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "a-author", "note": "-"}
{"ts": "2026-09-01T00:05:00Z", "script": "scripts/fixture-a.sh", "scripts": ["scripts/fixture-a.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "auth-a", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "a-invoke-excluded-authsess", "note": "-"}
{"ts": "2026-09-02T00:00:00Z", "script": "scripts/fixture-a.sh", "scripts": ["scripts/fixture-a.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "author-agent-sess", "agent_id": "a-a2", "agent_type": "script-author", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "a-invoke-excluded-agenttype", "note": "-"}
{"ts": "2026-09-03T00:00:00Z", "script": "scripts/fixture-a.sh", "scripts": ["scripts/fixture-a.sh"], "event": "invoke", "cause": "selftest", "outcome": "pass", "round": "-", "session": "user-a-selftest", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "a-invoke-excluded-selftest", "note": "-"}
{"ts": "2026-09-04T00:00:00Z", "script": "scripts/fixture-a.sh", "scripts": ["scripts/fixture-a.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "user-a-1", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "a-invoke-1", "note": "-"}
{"ts": "2026-09-05T00:00:00Z", "script": "scripts/fixture-b-selftest.sh", "scripts": ["scripts/fixture-b-selftest.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "user-b-1", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "b-invoke-1", "note": "-"}
{"ts": "2026-09-01T00:00:00Z", "script": "-", "scripts": [], "event": "owner_wait", "cause": "-", "outcome": "-", "round": "-", "session": "user-a-1", "agent_id": "-", "agent_type": "main", "model": "-", "turns": 0, "tokens": 0, "usd": 0.0, "duration_s": 42, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "PROJ-42", "source": "transcript", "key": "wait-1", "note": "askuser"}
EOF

USAGE_OUT=$(run report --events "$USAGE_EVENTS" --usage --until 2026-09-06T00:00:00Z --format tsv) \
  || { echo "report --usage failed unexpectedly:" >&2; echo "$USAGE_OUT" >&2; exit 1; }

if printf '%s\n' "$USAGE_OUT" | grep -q "script	invocations	sessions	pass	fail	first_used	last_used	lint_runs	selftest_runs	rework_rounds	lint_wall_clock_s	author_usd	rework_ratio	flag"; then
  ok "report --usage: prints the expected column headers"
else
  bad "report --usage: column headers missing or wrong (got: $USAGE_OUT)"
fi

if printf '%s\n' "$USAGE_OUT" | grep -qE $'^scripts/fixture-a\\.sh\t1\t1\t1\t0'; then
  ok "report --usage: fixture-a.sh invocations=1 (authoring-session, script-author-agent_type, and selftest-cause invokes all excluded)"
else
  bad "report --usage: fixture-a.sh row unexpected (got: $USAGE_OUT)"
fi

if printf '%s\n' "$USAGE_OUT" | grep -q "scripts/fixture-b-selftest.sh"; then
  bad "report --usage: a *-selftest.sh script must never get its own row"
else
  ok "report --usage: a *-selftest.sh script is excluded from the usage table entirely"
fi

if printf '%s\n' "$USAGE_OUT" | grep -q "owner_wait summary"; then
  ok "report --usage: prints an owner_wait summary section"
else
  bad "report --usage: owner_wait summary section missing"
fi

if printf '%s\n' "$USAGE_OUT" | grep -qE $'^PROJ-42\t42\\.0'; then
  ok "report --usage: owner_wait summary attributes the wait's seconds to its ticket"
else
  bad "report --usage: owner_wait per-ticket row unexpected (got: $USAGE_OUT)"
fi

# Per-ticket cost table in `report --usage`

# NWM-100 carries an author (0.001) + review (0.0005) pair in different
# sessions, NWM-200 a single author (0.002), plus one `invoke` event with
# ticket "-" that must NOT appear in the per-ticket table at all.
TICKETCOST_EVENTS="$WORK/events-ticketcost.jsonl"
cat > "$TICKETCOST_EVENTS" <<'EOF'
{"ts": "2026-09-10T00:00:00Z", "script": "scripts/foo.sh", "scripts": ["scripts/foo.sh"], "event": "author", "cause": "-", "outcome": "-", "round": 1, "session": "sess-a", "agent_id": "a1", "agent_type": "script-author", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "NWM-100", "source": "transcript", "key": "tc-author", "note": "-"}
{"ts": "2026-09-10T00:05:00Z", "script": "scripts/foo.sh", "scripts": ["scripts/foo.sh"], "event": "review", "cause": "-", "outcome": "-", "round": "-", "session": "sess-b", "agent_id": "r1", "agent_type": "script-reviewer", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.0005, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "NWM-100", "source": "transcript", "key": "tc-review", "note": "-"}
{"ts": "2026-09-10T00:06:00Z", "script": "scripts/foo.sh", "scripts": ["scripts/foo.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "sess-c", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "tc-invoke-no-ticket", "note": "-"}
{"ts": "2026-09-11T00:00:00Z", "script": "scripts/bar.sh", "scripts": ["scripts/bar.sh"], "event": "author", "cause": "-", "outcome": "-", "round": 1, "session": "sess-d", "agent_id": "a2", "agent_type": "script-author", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.002, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "NWM-200", "source": "transcript", "key": "tc-author2", "note": "-"}
EOF

TICKETCOST_OUT=$(run report --events "$TICKETCOST_EVENTS" --usage --format tsv) \
  || { echo "report --usage on the ticket-cost fixture failed unexpectedly:" >&2; echo "$TICKETCOST_OUT" >&2; exit 1; }

if printf '%s\n' "$TICKETCOST_OUT" | grep -q "# per-ticket cost"; then
  ok "per-ticket cost: section header present"
else
  bad "per-ticket cost: section header missing (got: $TICKETCOST_OUT)"
fi

if printf '%s\n' "$TICKETCOST_OUT" | grep -q "ticket	session	agent_type	cost_usd"; then
  ok "per-ticket cost: column headers present"
else
  bad "per-ticket cost: column headers missing (got: $TICKETCOST_OUT)"
fi

if printf '%s\n' "$TICKETCOST_OUT" | grep -qE $'^NWM-100\tsess-a\tscript-author\t0\\.0010$'; then
  ok "per-ticket cost: NWM-100 author row (sess-a, script-author, 0.0010)"
else
  bad "per-ticket cost: NWM-100 author row unexpected (got: $TICKETCOST_OUT)"
fi

if printf '%s\n' "$TICKETCOST_OUT" | grep -qE $'^NWM-100\tsess-b\tscript-reviewer\t0\\.0005$'; then
  ok "per-ticket cost: NWM-100 review row (sess-b, script-reviewer, 0.0005)"
else
  bad "per-ticket cost: NWM-100 review row unexpected (got: $TICKETCOST_OUT)"
fi

if printf '%s\n' "$TICKETCOST_OUT" | grep -qE $'^NWM-200\tsess-d\tscript-author\t0\\.0020$'; then
  ok "per-ticket cost: NWM-200 author row (sess-d, script-author, 0.0020)"
else
  bad "per-ticket cost: NWM-200 author row unexpected (got: $TICKETCOST_OUT)"
fi

if printf '%s\n' "$TICKETCOST_OUT" | grep -q -- '-	sess-c	main'; then
  bad "per-ticket cost: the invoke event's ticket '-' must never produce a row"
else
  ok "per-ticket cost: the invoke event's ticket '-' never produces a row"
fi

# --usage's per-script COLUMNS are windowed by --since/--until, and
# owner_wait_s / tickets_per_owner_hour print only when a window is given.

# Lifetime invocations pinned at exactly 10 (8 outside the window, 2 inside)
# so `flag` is deterministically "keep" regardless of wall-clock "now".
WINDOWSPLIT_EVENTS="$WORK/events-windowsplit.jsonl"
cat > "$WINDOWSPLIT_EVENTS" <<'EOF'
{"ts": "2020-01-01T00:00:00Z", "script": "scripts/windowsplit.sh", "scripts": ["scripts/windowsplit.sh"], "event": "author", "cause": "-", "outcome": "-", "round": 1, "session": "ws-auth", "agent_id": "ws-a", "agent_type": "script-author", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.01, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "ws-author", "note": "-"}
{"ts": "2020-01-01T00:10:00Z", "script": "scripts/windowsplit.sh", "scripts": ["scripts/windowsplit.sh"], "event": "lint", "cause": "-", "outcome": "pass", "round": "-", "session": "ws-auth", "agent_id": "ws-a", "agent_type": "script-author", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.002, "duration_s": 5, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "ws-lint-pre", "note": "-"}
{"ts": "2020-01-02T00:00:00Z", "script": "scripts/windowsplit.sh", "scripts": ["scripts/windowsplit.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "ws-out-1", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "ws-out-1", "note": "-"}
{"ts": "2020-01-03T00:00:00Z", "script": "scripts/windowsplit.sh", "scripts": ["scripts/windowsplit.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "ws-out-2", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "ws-out-2", "note": "-"}
{"ts": "2020-01-04T00:00:00Z", "script": "scripts/windowsplit.sh", "scripts": ["scripts/windowsplit.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "ws-out-3", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "ws-out-3", "note": "-"}
{"ts": "2020-01-05T00:00:00Z", "script": "scripts/windowsplit.sh", "scripts": ["scripts/windowsplit.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "ws-out-4", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "ws-out-4", "note": "-"}
{"ts": "2020-01-06T00:00:00Z", "script": "scripts/windowsplit.sh", "scripts": ["scripts/windowsplit.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "ws-out-5", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "ws-out-5", "note": "-"}
{"ts": "2020-01-07T00:00:00Z", "script": "scripts/windowsplit.sh", "scripts": ["scripts/windowsplit.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "ws-out-6", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "ws-out-6", "note": "-"}
{"ts": "2020-01-08T00:00:00Z", "script": "scripts/windowsplit.sh", "scripts": ["scripts/windowsplit.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "ws-out-7", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "ws-out-7", "note": "-"}
{"ts": "2020-01-09T00:00:00Z", "script": "scripts/windowsplit.sh", "scripts": ["scripts/windowsplit.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "ws-out-8", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "ws-out-8", "note": "-"}
{"ts": "2023-06-01T00:00:00Z", "script": "scripts/windowsplit.sh", "scripts": ["scripts/windowsplit.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "ws-in-1", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "ws-in-1", "note": "-"}
{"ts": "2023-06-02T00:00:00Z", "script": "scripts/windowsplit.sh", "scripts": ["scripts/windowsplit.sh"], "event": "invoke", "cause": "-", "outcome": "pass", "round": "-", "session": "ws-in-2", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.00001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "ws-in-2", "note": "-"}
{"ts": "2023-06-01T00:05:00Z", "script": "scripts/windowsplit.sh", "scripts": ["scripts/windowsplit.sh"], "event": "lint", "cause": "-", "outcome": "pass", "round": "-", "session": "ws-in-1", "agent_id": "-", "agent_type": "main", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.001, "duration_s": 3, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "-", "source": "transcript", "key": "ws-lint-in", "note": "-"}
EOF

WINDOWSPLIT_UNWINDOWED=$(run report --events "$WINDOWSPLIT_EVENTS" --usage --format tsv) \
  || { echo "report --usage on the windowsplit fixture (unwindowed) failed unexpectedly:" >&2; echo "$WINDOWSPLIT_UNWINDOWED" >&2; exit 1; }

if printf '%s\n' "$WINDOWSPLIT_UNWINDOWED" | grep -qE $'^scripts/windowsplit\\.sh\t10\t10\t10\t0\t2020-01-02T00:00:00Z\t2023-06-02T00:00:00Z\t2\t0\t0\t8\\.0\t0\\.0100\t0\\.30\tkeep$'; then
  ok "windowsplit.sh unwindowed: invocations=10 (lifetime), author_usd=0.0100, rework_ratio=0.30 ((0.002+0.001)/0.01), flag=keep (>=10 lifetime)"
else
  bad "windowsplit.sh unwindowed row unexpected (got: $WINDOWSPLIT_UNWINDOWED)"
fi

if printf '%s\n' "$WINDOWSPLIT_UNWINDOWED" | grep -q "# window rework_ratio: 0.30"; then
  ok "windowsplit.sh unwindowed: '# window rework_ratio' line still prints (pre-existing behavior, unchanged)"
else
  bad "windowsplit.sh unwindowed: '# window rework_ratio' line missing or wrong (got: $WINDOWSPLIT_UNWINDOWED)"
fi

if printf '%s\n' "$WINDOWSPLIT_UNWINDOWED" | grep -q "# window owner_wait_s:"; then
  bad "windowsplit.sh unwindowed: '# window owner_wait_s' must be suppressed with no --since/--until (new line, must not grow unwindowed output)"
else
  ok "windowsplit.sh unwindowed: '# window owner_wait_s' line is suppressed"
fi

if printf '%s\n' "$WINDOWSPLIT_UNWINDOWED" | grep -q "# window tickets_per_owner_hour:"; then
  bad "windowsplit.sh unwindowed: '# window tickets_per_owner_hour' must be suppressed with no --since/--until (new line, must not grow unwindowed output)"
else
  ok "windowsplit.sh unwindowed: '# window tickets_per_owner_hour' line is suppressed"
fi

WINDOWSPLIT_WINDOWED=$(run report --events "$WINDOWSPLIT_EVENTS" --usage \
    --since 2023-01-01T00:00:00Z --until 2024-01-01T00:00:00Z --format tsv) \
  || { echo "report --usage on the windowsplit fixture (windowed) failed unexpectedly:" >&2; echo "$WINDOWSPLIT_WINDOWED" >&2; exit 1; }

# invocations=2 (in-window only, vs lifetime 10), author_usd=0.0000 (author
# is outside the window), rework_ratio='-' (nothing to divide by),
# flag=keep (lifetime >=10, unmoved by the window).
if printf '%s\n' "$WINDOWSPLIT_WINDOWED" | grep -qE $'^scripts/windowsplit\\.sh\t2\t2\t2\t0\t2023-06-01T00:00:00Z\t2023-06-02T00:00:00Z\t1\t0\t0\t3\\.0\t0\\.0000\t-\tkeep$'; then
  ok "windowsplit.sh windowed: columns are windowed (invocations=2, author_usd=0.0000, rework_ratio=-) while flag stays lifetime (keep)"
else
  bad "windowsplit.sh windowed row unexpected — columns must be windowed, not just row presence (got: $WINDOWSPLIT_WINDOWED)"
fi

# All three wave-summary figures come out as real numbers:
# rework_ratio = 0.0005/0.001 = 0.50, owner_wait_s = 1800.0,
# tickets_per_owner_hour = 1 / 0.5 = 2.00.
WAVELINE_EVENTS="$WORK/events-waveline.jsonl"
cat > "$WAVELINE_EVENTS" <<'EOF'
{"ts": "2026-09-13T22:10:00Z", "script": "scripts/waveline.sh", "scripts": ["scripts/waveline.sh"], "event": "author", "cause": "-", "outcome": "-", "round": 1, "session": "wl-auth", "agent_id": "wl-a", "agent_type": "script-author", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.001, "duration_s": 1, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "NWM-900", "source": "transcript", "key": "wl-author", "note": "-"}
{"ts": "2026-09-13T22:15:00Z", "script": "scripts/waveline.sh", "scripts": ["scripts/waveline.sh"], "event": "lint", "cause": "-", "outcome": "pass", "round": "-", "session": "wl-auth", "agent_id": "wl-a", "agent_type": "script-author", "model": "claude-sonnet-5", "turns": 1, "tokens": 1, "usd": 0.0005, "duration_s": 2, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "NWM-900", "source": "transcript", "key": "wl-lint", "note": "-"}
{"ts": "2026-09-13T22:20:00Z", "script": "-", "scripts": [], "event": "owner_wait", "cause": "-", "outcome": "-", "round": "-", "session": "wl-main", "agent_id": "-", "agent_type": "main", "model": "-", "turns": 0, "tokens": 0, "usd": 0.0, "duration_s": 1800.0, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "NWM-900", "source": "transcript", "key": "wl-ownerwait", "note": "askuser"}
{"ts": "2026-09-13T23:00:00Z", "script": "scripts/waveline.sh", "scripts": ["scripts/waveline.sh"], "event": "accepted", "cause": "-", "outcome": "pass", "round": "-", "session": "-", "agent_id": "-", "agent_type": "-", "model": "-", "turns": 0, "tokens": 0, "usd": 0.0, "duration_s": 0, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "NWM-900", "source": "manual", "key": "wl-accepted", "note": "-"}
EOF

WAVELINE_OUT=$(run report --events "$WAVELINE_EVENTS" --usage \
    --since 2026-09-13T22:00:00Z --until 2026-09-14T00:00:00Z --format tsv) \
  || { echo "report --usage on the waveline fixture failed unexpectedly:" >&2; echo "$WAVELINE_OUT" >&2; exit 1; }

if printf '%s\n' "$WAVELINE_OUT" | grep -q "# window rework_ratio: 0.50"; then
  ok "waveline: window rework_ratio = 0.50 (0.0005 lint / 0.001 author)"
else
  bad "waveline: window rework_ratio wrong (got: $WAVELINE_OUT)"
fi

if printf '%s\n' "$WAVELINE_OUT" | grep -q "# window owner_wait_s: 1800.0"; then
  ok "waveline: window owner_wait_s = 1800.0 (the one 30-minute owner_wait event)"
else
  bad "waveline: window owner_wait_s wrong (got: $WAVELINE_OUT)"
fi

if printf '%s\n' "$WAVELINE_OUT" | grep -q "# window tickets_per_owner_hour: 2.00"; then
  ok "waveline: window tickets_per_owner_hour = 2.00 (1 ticket landed / 0.5 owner-attended hours)"
else
  bad "waveline: window tickets_per_owner_hour wrong (got: $WAVELINE_OUT)"
fi

# One owner_wait entirely BEFORE the window (must NOT count), one accepted
# ticket inside it. Correct result: owner_wait_s=0.0 and
# tickets_per_owner_hour='-' (undividable, not an error) — not a bug to fix.
ZEROWAIT_EVENTS="$WORK/events-zerowait.jsonl"
cat > "$ZEROWAIT_EVENTS" <<'EOF'
{"ts": "2026-09-13T19:47:39Z", "script": "-", "scripts": [], "event": "owner_wait", "cause": "-", "outcome": "-", "round": "-", "session": "zw-main", "agent_id": "-", "agent_type": "main", "model": "-", "turns": 0, "tokens": 0, "usd": 0.0, "duration_s": 602.661, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "NWM-065", "source": "transcript", "key": "zw-ownerwait-before-window", "note": "askuser"}
{"ts": "2026-09-14T02:01:36Z", "script": "scripts/zerowait.sh", "scripts": ["scripts/zerowait.sh"], "event": "accepted", "cause": "-", "outcome": "pass", "round": "-", "session": "-", "agent_id": "-", "agent_type": "-", "model": "-", "turns": 0, "tokens": 0, "usd": 0.0, "duration_s": 0, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "NWM-217", "source": "manual", "key": "zw-accepted", "note": "-"}
EOF

ZEROWAIT_OUT=$(run report --events "$ZEROWAIT_EVENTS" --usage \
    --since 2026-09-13T22:00:00Z --until 2026-09-14T03:01:53Z --format tsv) \
  || { echo "report --usage on the zerowait fixture failed unexpectedly:" >&2; echo "$ZEROWAIT_OUT" >&2; exit 1; }

if printf '%s\n' "$ZEROWAIT_OUT" | grep -q "# window owner_wait_s: 0.0"; then
  ok "zerowait: window owner_wait_s = 0.0 (the only owner_wait event's ts is well before the window, correctly excluded)"
else
  bad "zerowait: window owner_wait_s wrong (got: $ZEROWAIT_OUT)"
fi

if printf '%s\n' "$ZEROWAIT_OUT" | grep -q "# window tickets_per_owner_hour: -"; then
  ok "zerowait: window tickets_per_owner_hour = '-' (0 owner-attended hours — undividable, not an error)"
else
  bad "zerowait: window tickets_per_owner_hour wrong (got: $ZEROWAIT_OUT)"
fi

if printf '%s\n' "$ZEROWAIT_OUT" | grep -q $'total\t0\\.0'; then
  ok "zerowait: owner_wait summary total row is still 0.0 even though a ticket landed in-window"
else
  bad "zerowait: owner_wait summary total row wrong (got: $ZEROWAIT_OUT)"
fi

# status-durations

# night-watchman's Jira provider, which does not exist in this repo: the
# tracker seam stays on the consuming side of the boundary rule. Overridable
# so a consumer that has one still gets the two dry-run assertions below.
JIRA_API_REAL="${SCRIPT_ANALYTICS_JIRA_API:-$HERE/../providers/tracker/jira/jira-api.sh}"

# Offline GET-only fake jira-api.sh for NWM-500, using Jira's colon-less
# "+0000" offset on purpose. Expected, computed by hand: Open 09-01 -> 09-02
# = 86400s closed / In Progress 09-02 -> 09-04T12 = 216000s closed / Done
# 09-04T12 -> --until 09-05 = 43200s open.
FAKE_JIRA="$WORK/fake-jira-api.sh"
cat > "$FAKE_JIRA" <<'EOF'
#!/bin/bash
if [ "$1" = "raw" ] && [ "$2" = "GET" ]; then
    case "$3" in
        /issue/NWM-500/changelog)
            echo '{"values":[{"created":"2026-09-02T00:00:00.000+0000","items":[{"field":"status","fromString":"Open","toString":"In Progress"}]},{"created":"2026-09-04T12:00:00.000+0000","items":[{"field":"status","fromString":"In Progress","toString":"Done"}]}],"isLast":true}'
            exit 0
            ;;
        "/issue/NWM-500?fields=created")
            echo '{"fields":{"created":"2026-09-01T00:00:00.000+0000"}}'
            exit 0
            ;;
    esac
fi
echo "fake-jira-api.sh: unhandled call: $*" >&2
exit 1
EOF
chmod +x "$FAKE_JIRA"

STATUSDUR_EVENTS="$WORK/events-statusdur.jsonl"
STATUSDUR_OUT=$(run status-durations --events "$STATUSDUR_EVENTS" \
    NWM-500 --jira-api "$FAKE_JIRA" --until 2026-09-05T00:00:00Z --dry-run) \
    || { echo "status-durations --dry-run failed unexpectedly:" >&2; echo "$STATUSDUR_OUT" >&2; exit 1; }

if printf '%s\n' "$STATUSDUR_OUT" | grep -q "3 new, 0 updated, 0 already present"; then
  ok "status-durations dry-run: 3 new, 0 updated, 0 already present"
else
  bad "status-durations dry-run: unexpected summary line (got: $STATUSDUR_OUT)"
fi

if printf '%s\n' "$STATUSDUR_OUT" | grep -q '"outcome": "closed", "round": null, "session": "-", "agent_id": "-", "agent_type": "-", "model": "-", "turns": 0, "tokens": 0, "usd": 0.0, "duration_s": 86400.0, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "NWM-500", "source": "jira_changelog", "key": "status_duration:NWM-500:Open:2026-09-01T00:00:00Z", "note": "Open"'; then
  ok "status-durations: Open closed, duration_s=86400.0 (created -> first transition)"
else
  bad "status-durations: Open row unexpected (got: $STATUSDUR_OUT)"
fi

if printf '%s\n' "$STATUSDUR_OUT" | grep -q '"duration_s": 216000.0, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "NWM-500", "source": "jira_changelog", "key": "status_duration:NWM-500:In Progress:2026-09-02T00:00:00Z", "note": "In Progress"'; then
  ok "status-durations: In Progress closed, duration_s=216000.0"
else
  bad "status-durations: In Progress row unexpected (got: $STATUSDUR_OUT)"
fi

if printf '%s\n' "$STATUSDUR_OUT" | grep -q '"outcome": "open", "round": null, "session": "-", "agent_id": "-", "agent_type": "-", "model": "-", "turns": 0, "tokens": 0, "usd": 0.0, "duration_s": 43200.0, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "NWM-500", "source": "jira_changelog", "key": "status_duration:NWM-500:Done:2026-09-04T12:00:00Z", "note": "Done"'; then
  ok "status-durations: Done open, duration_s=43200.0 (second transition -> --until)"
else
  bad "status-durations: Done row unexpected (got: $STATUSDUR_OUT)"
fi

# Idempotency: a second run must add 0 new / 0 updated — closed rows are
# immutable and the open row is unchanged (same --until, same transitions).
run status-durations --events "$STATUSDUR_EVENTS" \
    NWM-500 --jira-api "$FAKE_JIRA" --until 2026-09-05T00:00:00Z >/dev/null \
    || { echo "status-durations (real append) failed unexpectedly:" >&2; exit 1; }
STATUSDUR_REEXTRACT=$(run status-durations --events "$STATUSDUR_EVENTS" \
    NWM-500 --jira-api "$FAKE_JIRA" --until 2026-09-05T00:00:00Z) \
    || { echo "status-durations (idempotent re-run) failed unexpectedly:" >&2; exit 1; }
if printf '%s\n' "$STATUSDUR_REEXTRACT" | grep -q "0 new, 0 updated, 3 already present"; then
  ok "status-durations: idempotent by key when nothing changed"
else
  bad "status-durations: idempotent re-run unexpected (got: $STATUSDUR_REEXTRACT)"
fi

# Open-status reconciliation: with a LATER --until and no new transition, the
# "Done" row's duration_s must be REWRITTEN IN PLACE (129600s), not skipped,
# and the two CLOSED rows must remain byte-identical.
LATER_OUT=$(run status-durations --events "$STATUSDUR_EVENTS" \
    NWM-500 --jira-api "$FAKE_JIRA" --until 2026-09-06T00:00:00Z) \
    || { echo "status-durations (later --until) failed unexpectedly:" >&2; exit 1; }
if printf '%s\n' "$LATER_OUT" | grep -q "0 new, 1 updated, 2 already present"; then
  ok "status-durations: a later --until with no new transition updates only the open row"
else
  bad "status-durations: later --until summary unexpected (got: $LATER_OUT)"
fi
LATER_CONTENT=$(cat "$STATUSDUR_EVENTS")
if printf '%s\n' "$LATER_CONTENT" | grep -q '"key": "status_duration:NWM-500:Done:2026-09-04T12:00:00Z", "note": "Done"}' \
    && printf '%s\n' "$LATER_CONTENT" | grep -q '"duration_s": 129600.0'; then
  ok "status-durations: the Done row's duration_s is corrected to 129600.0 in the file itself"
else
  bad "status-durations: Done row not corrected as expected (got: $LATER_CONTENT)"
fi
if printf '%s\n' "$LATER_CONTENT" | grep -q '"duration_s": 86400.0' \
    && printf '%s\n' "$LATER_CONTENT" | grep -q '"duration_s": 216000.0'; then
  ok "status-durations: the two CLOSED rows (Open, In Progress) are untouched"
else
  bad "status-durations: a closed row was unexpectedly rewritten (got: $LATER_CONTENT)"
fi

# The ticket transitions again ("Done" -> "Closed"). Re-running must CORRECT
# the now-stale "Done" row (216000s, outcome=closed) and APPEND a "Closed" one.
FAKE_JIRA_V2="$WORK/fake-jira-api-v2.sh"
cat > "$FAKE_JIRA_V2" <<'EOF'
#!/bin/bash
if [ "$1" = "raw" ] && [ "$2" = "GET" ]; then
    case "$3" in
        /issue/NWM-500/changelog)
            echo '{"values":[{"created":"2026-09-02T00:00:00.000+0000","items":[{"field":"status","fromString":"Open","toString":"In Progress"}]},{"created":"2026-09-04T12:00:00.000+0000","items":[{"field":"status","fromString":"In Progress","toString":"Done"}]},{"created":"2026-09-07T00:00:00.000+0000","items":[{"field":"status","fromString":"Done","toString":"Closed"}]}],"isLast":true}'
            exit 0
            ;;
        "/issue/NWM-500?fields=created")
            echo '{"fields":{"created":"2026-09-01T00:00:00.000+0000"}}'
            exit 0
            ;;
    esac
fi
echo "fake-jira-api-v2.sh: unhandled call: $*" >&2
exit 1
EOF
chmod +x "$FAKE_JIRA_V2"
TRANSITIONED_OUT=$(run status-durations --events "$STATUSDUR_EVENTS" \
    NWM-500 --jira-api "$FAKE_JIRA_V2" --until 2026-09-08T00:00:00Z) \
    || { echo "status-durations (ticket transitioned) failed unexpectedly:" >&2; exit 1; }
if printf '%s\n' "$TRANSITIONED_OUT" | grep -q "1 new, 1 updated, 2 already present"; then
  ok "status-durations: ticket transitioned — 1 new (Closed), 1 updated (Done corrected)"
else
  bad "status-durations: ticket-transitioned summary unexpected (got: $TRANSITIONED_OUT)"
fi
TRANSITIONED_CONTENT=$(cat "$STATUSDUR_EVENTS")
if printf '%s\n' "$TRANSITIONED_CONTENT" | grep -q '"key": "status_duration:NWM-500:Done:2026-09-04T12:00:00Z", "note": "Done"}' \
    && printf '%s\n' "$TRANSITIONED_CONTENT" | grep -q '"duration_s": 216000.0'; then
  ok "status-durations: the Done row is corrected to the real 216000.0 and now outcome=closed"
else
  bad "status-durations: Done row not corrected on transition (got: $TRANSITIONED_CONTENT)"
fi
if printf '%s\n' "$TRANSITIONED_CONTENT" | grep -q '"duration_s": 129600.0'; then
  bad "status-durations: the stale duration_s=129600.0 must not survive the transition"
else
  ok "status-durations: the stale duration_s=129600.0 no longer appears anywhere"
fi
if printf '%s\n' "$TRANSITIONED_CONTENT" | grep -q '"outcome": "open", "round": null, "session": "-", "agent_id": "-", "agent_type": "-", "model": "-", "turns": 0, "tokens": 0, "usd": 0.0, "duration_s": 86400.0, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "NWM-500", "source": "jira_changelog", "key": "status_duration:NWM-500:Closed:2026-09-07T00:00:00Z", "note": "Closed"'; then
  ok "status-durations: a new 'Closed' row was appended, outcome=open, duration_s=86400.0"
else
  bad "status-durations: new Closed row unexpected (got: $TRANSITIONED_CONTENT)"
fi

# Out-of-order changelog entries: the SAME two transitions fed newest-first
# must give a result IDENTICAL to the forward-order case.
FAKE_JIRA_REVERSED="$WORK/fake-jira-api-reversed.sh"
cat > "$FAKE_JIRA_REVERSED" <<'EOF'
#!/bin/bash
if [ "$1" = "raw" ] && [ "$2" = "GET" ]; then
    case "$3" in
        /issue/NWM-502/changelog)
            echo '{"values":[{"created":"2026-09-04T12:00:00.000+0000","items":[{"field":"status","fromString":"In Progress","toString":"Done"}]},{"created":"2026-09-02T00:00:00.000+0000","items":[{"field":"status","fromString":"Open","toString":"In Progress"}]}],"isLast":true}'
            exit 0
            ;;
        "/issue/NWM-502?fields=created")
            exit 1
            ;;
    esac
fi
echo "fake-jira-api-reversed.sh: unhandled call: $*" >&2
exit 1
EOF
chmod +x "$FAKE_JIRA_REVERSED"
REVERSED_EVENTS="$WORK/events-reversed.jsonl"
REVERSED_OUT=$(run status-durations --events "$REVERSED_EVENTS" \
    NWM-502 --jira-api "$FAKE_JIRA_REVERSED" --until 2026-09-05T00:00:00Z --dry-run) \
    || { echo "status-durations (reversed changelog) failed unexpectedly:" >&2; echo "$REVERSED_OUT" >&2; exit 1; }
if printf '%s\n' "$REVERSED_OUT" | grep -q "2 new, 0 updated, 0 already present"; then
  ok "status-durations: reversed changelog input still yields exactly 2 events"
else
  bad "status-durations: reversed-input summary unexpected (got: $REVERSED_OUT)"
fi
if printf '%s\n' "$REVERSED_OUT" | grep -q '"duration_s": -'; then
  bad "status-durations: a negative duration_s appeared in the reversed-input output"
else
  ok "status-durations: no negative duration_s anywhere in the reversed-input output"
fi
if printf '%s\n' "$REVERSED_OUT" | grep -q '"key": "status_duration:NWM-502:In Progress:2026-09-02T00:00:00Z", "note": "In Progress"'; then
  ok "status-durations: reversed input still computes In Progress duration_s correctly (216000.0)"
else
  bad "status-durations: reversed-input In Progress row unexpected (got: $REVERSED_OUT)"
fi

# --until earlier than the last transition
# must be refused for that row (warned, skipped), never a negative duration.
UNTILEARLY_OUT=$(run status-durations --events "$WORK/events-untilearly.jsonl" \
    NWM-500 --jira-api "$FAKE_JIRA" --until 2026-09-03T00:00:00Z --dry-run 2>&1) \
    || { echo "status-durations (--until before last transition) failed unexpectedly:" >&2; echo "$UNTILEARLY_OUT" >&2; exit 1; }
if printf '%s\n' "$UNTILEARLY_OUT" | grep -q "computed a negative duration"; then
  ok "status-durations: an --until before the last transition is refused for that row"
else
  bad "status-durations: --until-before-transition refusal message missing (got: $UNTILEARLY_OUT)"
fi
if printf '%s\n' "$UNTILEARLY_OUT" | grep -q '"duration_s": -'; then
  bad "status-durations: a negative duration_s was written for an early --until"
else
  ok "status-durations: no negative duration_s is ever written when --until precedes the last transition"
fi

# Pagination guard fires on total>len(values)
# even with no isLast key at all.
PAGED_JIRA="$WORK/fake-jira-api-paged.sh"
cat > "$PAGED_JIRA" <<'EOF'
#!/bin/bash
if [ "$1" = "raw" ] && [ "$2" = "GET" ]; then
    case "$3" in
        /issue/NWM-503/changelog)
            echo '{"values":[{"created":"2026-09-02T00:00:00.000+0000","items":[{"field":"status","fromString":"Open","toString":"In Progress"}]}],"total":5}'
            exit 0
            ;;
        "/issue/NWM-503?fields=created")
            exit 1
            ;;
    esac
fi
echo "fake-jira-api-paged.sh: unhandled call: $*" >&2
exit 1
EOF
chmod +x "$PAGED_JIRA"
PAGED_OUT=$(run status-durations --events "$WORK/events-paged.jsonl" \
    NWM-503 --jira-api "$PAGED_JIRA" --until 2026-09-05T00:00:00Z --dry-run 2>&1) \
    || { echo "status-durations (paged, no isLast) failed unexpectedly:" >&2; echo "$PAGED_OUT" >&2; exit 1; }
if printf '%s\n' "$PAGED_OUT" | grep -q "changelog has more than one page"; then
  ok "status-durations: pagination guard fires on total>len(values) even with no isLast key"
else
  bad "status-durations: pagination guard did not fire (got: $PAGED_OUT)"
fi

# One bad ticket does not abort the rest: NWM-504 has an unparseable
# timestamp, NWM-500 is good, and the same run must exit 0, emit NWM-500's
# events, and name NWM-504 as skipped.
BADTS_JIRA="$WORK/fake-jira-api-badts.sh"
cat > "$BADTS_JIRA" <<'EOF'
#!/bin/bash
if [ "$1" = "raw" ] && [ "$2" = "GET" ]; then
    case "$3" in
        /issue/NWM-504/changelog)
            echo '{"values":[{"created":"not-a-timestamp","items":[{"field":"status","fromString":"Open","toString":"In Progress"}]}],"isLast":true}'
            exit 0
            ;;
        /issue/NWM-500/changelog)
            echo '{"values":[{"created":"2026-09-02T00:00:00.000+0000","items":[{"field":"status","fromString":"Open","toString":"In Progress"}]},{"created":"2026-09-04T12:00:00.000+0000","items":[{"field":"status","fromString":"In Progress","toString":"Done"}]}],"isLast":true}'
            exit 0
            ;;
        "/issue/NWM-500?fields=created")
            echo '{"fields":{"created":"2026-09-01T00:00:00.000+0000"}}'
            exit 0
            ;;
    esac
fi
echo "fake-jira-api-badts.sh: unhandled call: $*" >&2
exit 1
EOF
chmod +x "$BADTS_JIRA"
BADTS_OUT=$(run status-durations --events "$WORK/events-badts.jsonl" \
    NWM-504 NWM-500 --jira-api "$BADTS_JIRA" --until 2026-09-05T00:00:00Z --dry-run 2>&1) \
    || { echo "status-durations (one bad ticket) unexpectedly aborted the whole run:" >&2; echo "$BADTS_OUT" >&2; exit 1; }
if printf '%s\n' "$BADTS_OUT" | grep -q "NWM-504: skipped entirely"; then
  ok "status-durations: a bad timestamp in one ticket is named as skipped, not a crash"
else
  bad "status-durations: bad-ticket skip message missing (got: $BADTS_OUT)"
fi
if printf '%s\n' "$BADTS_OUT" | grep -q '"ticket": "NWM-500"'; then
  ok "status-durations: the other ticket in the same run still produced its events"
else
  bad "status-durations: NWM-500 events missing from a mixed-ticket run (got: $BADTS_OUT)"
fi

# Recorded-fixture replay: only ONE of PROJ-63's six changelog entries carries
# field=="status", proving that filter is load-bearing. Expected, by hand, with
# --until pinned to 2026-09-15 so both stay deterministic: To Do 1414.968s
# closed (created 11:45:11.813Z) / Completed 42673.219s open (12:08:46.781Z).

# Recorded API text, so it travels with this selftest rather than with
# whichever repo owns the Jira provider.
FIXTURES_DIR="$HERE/fixtures"
[ -d "$FIXTURES_DIR" ] || FIXTURES_DIR="$HERE/../providers/tracker/jira/fixtures"
CHANGELOG_FIXTURE="$FIXTURES_DIR/raw.changelog.PROJ-63.txt"
CREATED_FIXTURE="$FIXTURES_DIR/raw.issue-created.PROJ-63.txt"
[ -f "$CHANGELOG_FIXTURE" ] || { echo "missing recorded fixture: $CHANGELOG_FIXTURE" >&2; exit 2; }
[ -f "$CREATED_FIXTURE" ] || { echo "missing recorded fixture: $CREATED_FIXTURE" >&2; exit 2; }

# Strip the '#'-prefixed provenance header lines to recover the exact JSON
# body jira-api.sh itself would print.
CHANGELOG_JSON="$WORK/proj63-changelog.json"
CREATED_JSON="$WORK/proj63-created.json"
grep -v '^#' "$CHANGELOG_FIXTURE" > "$CHANGELOG_JSON"
grep -v '^#' "$CREATED_FIXTURE" > "$CREATED_JSON"

REAL_FIXTURE_JIRA="$WORK/fake-jira-api-real-proj63.sh"
cat > "$REAL_FIXTURE_JIRA" <<EOF
#!/bin/bash
if [ "\$1" = "raw" ] && [ "\$2" = "GET" ]; then
    case "\$3" in
        /issue/PROJ-63/changelog)
            cat "$CHANGELOG_JSON"
            exit 0
            ;;
        "/issue/PROJ-63?fields=created")
            cat "$CREATED_JSON"
            exit 0
            ;;
    esac
fi
echo "fake-jira-api-real-proj63.sh: unhandled call: \$*" >&2
exit 1
EOF
chmod +x "$REAL_FIXTURE_JIRA"

REAL_FIXTURE_OUT=$(run status-durations --events "$WORK/events-real-proj63.jsonl" \
    PROJ-63 --jira-api "$REAL_FIXTURE_JIRA" --until 2026-09-15T00:00:00Z --dry-run 2>&1) \
    || { echo "status-durations against the REAL recorded PROJ-63 fixture failed unexpectedly:" >&2; echo "$REAL_FIXTURE_OUT" >&2; exit 1; }

if printf '%s\n' "$REAL_FIXTURE_OUT" | grep -q "2 new, 0 updated, 0 already present"; then
  ok "real PROJ-63 fixture: exactly 2 new events (only 1 status-changing entry among 6 changelog items)"
else
  bad "real PROJ-63 fixture: unexpected summary line (got: $REAL_FIXTURE_OUT)"
fi
if printf '%s\n' "$REAL_FIXTURE_OUT" | grep -q '"outcome": "closed", "round": null, "session": "-", "agent_id": "-", "agent_type": "-", "model": "-", "turns": 0, "tokens": 0, "usd": 0.0, "duration_s": 1414.968, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "PROJ-63", "source": "jira_changelog", "key": "status_duration:PROJ-63:To Do:2026-09-14T11:45:11Z", "note": "To Do"'; then
  ok "real PROJ-63 fixture: 'To Do' closed, duration_s=1414.968 (created -> first transition)"
else
  bad "real PROJ-63 fixture: To Do row unexpected (got: $REAL_FIXTURE_OUT)"
fi
if printf '%s\n' "$REAL_FIXTURE_OUT" | grep -q '"outcome": "open", "round": null, "session": "-", "agent_id": "-", "agent_type": "-", "model": "-", "turns": 0, "tokens": 0, "usd": 0.0, "duration_s": 42673.219, "findings": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "ticket": "PROJ-63", "source": "jira_changelog", "key": "status_duration:PROJ-63:Completed:2026-09-14T12:08:46Z", "note": "Completed"'; then
  ok "real PROJ-63 fixture: 'Completed' open, duration_s=42673.219 (first transition -> pinned --until)"
else
  bad "real PROJ-63 fixture: Completed row unexpected (got: $REAL_FIXTURE_OUT)"
fi

# --ticket format is anchored, not just
# prefix-matched.
ANCHORED_ERR=$(run status-durations --events "$WORK/events-anchored.jsonl" \
    "NWM-500/comment?maxResults=1" --jira-api "$FAKE_JIRA" 2>&1 >/dev/null) && ANCHORED_STATUS=0 || ANCHORED_STATUS=$?
if [ "$ANCHORED_STATUS" -eq 2 ]; then
  ok "status-durations: a ticket value with a trailing path/query is refused, not prefix-matched"
else
  bad "status-durations: trailing path/query ticket should have been refused with exit 2 (got $ANCHORED_STATUS)"
fi
if printf '%s\n' "$ANCHORED_ERR" | grep -q "NWM-500/comment?maxResults=1"; then
  ok "status-durations: the anchored-ticket refusal names the offending value"
else
  bad "status-durations: anchored-ticket refusal message missing expected text (got: $ANCHORED_ERR)"
fi

# Missing 'created' field: initial status is skipped, named on stderr, and
# the run still succeeds (1 transition -> 1 event, not 2, no crash).
FAKE_JIRA_NOCREATED="$WORK/fake-jira-api-nocreated.sh"
cat > "$FAKE_JIRA_NOCREATED" <<'EOF'
#!/bin/bash
if [ "$1" = "raw" ] && [ "$2" = "GET" ]; then
    case "$3" in
        /issue/NWM-501/changelog)
            echo '{"values":[{"created":"2026-09-02T00:00:00.000+0000","items":[{"field":"status","fromString":"Open","toString":"In Progress"}]}],"isLast":true}'
            exit 0
            ;;
        "/issue/NWM-501?fields=created")
            exit 1
            ;;
    esac
fi
echo "fake-jira-api-nocreated.sh: unhandled call: $*" >&2
exit 1
EOF
chmod +x "$FAKE_JIRA_NOCREATED"
NOCREATED_OUT=$(run status-durations --events "$WORK/events-nocreated.jsonl" \
    NWM-501 --jira-api "$FAKE_JIRA_NOCREATED" --until 2026-09-05T00:00:00Z --dry-run 2>&1) \
    || { echo "status-durations (missing created) failed unexpectedly:" >&2; echo "$NOCREATED_OUT" >&2; exit 1; }
if printf '%s\n' "$NOCREATED_OUT" | grep -q "cannot be timed without a 'created' timestamp — skipped, not guessed"; then
  ok "status-durations: missing 'created' is named on stderr, not guessed"
else
  bad "status-durations: missing-created message missing (got: $NOCREATED_OUT)"
fi
if printf '%s\n' "$NOCREATED_OUT" | grep -q "1 new, 0 updated, 0 already present"; then
  ok "status-durations: missing 'created' still emits the one event it CAN compute"
else
  bad "status-durations: missing-created summary unexpected (got: $NOCREATED_OUT)"
fi
if printf '%s\n' "$NOCREATED_OUT" | grep -q '"note": "Open"'; then
  bad "status-durations: missing 'created' must never emit an 'Open' row"
else
  ok "status-durations: missing 'created' never emits an 'Open' row"
fi

# --ticket format validation.
BADTICKET_ERR=$(run status-durations --events "$WORK/events-badticket.jsonl" \
    not-a-ticket --jira-api "$FAKE_JIRA" 2>&1 >/dev/null) && BADTICKET_STATUS=0 || BADTICKET_STATUS=$?
if [ "$BADTICKET_STATUS" -eq 2 ]; then
  ok "status-durations: refuses a malformed ticket with exit 2"
else
  bad "status-durations: malformed ticket should have been refused with exit 2 (got $BADTICKET_STATUS)"
fi
if printf '%s\n' "$BADTICKET_ERR" | grep -q "not-a-ticket"; then
  ok "status-durations: malformed-ticket error names the bad value"
else
  bad "status-durations: malformed-ticket error missing expected text (got: $BADTICKET_ERR)"
fi

# A status_duration-only events file must NOT produce a bogus `script: -` row
# in `report`'s main table — the same exclusion `invoke` already gets.
STATUSONLY_REPORT=$(run report --events "$STATUSDUR_EVENTS" --format tsv) \
    || { echo "report on a status_duration-only events file failed unexpectedly:" >&2; echo "$STATUSONLY_REPORT" >&2; exit 1; }
if printf '%s\n' "$STATUSONLY_REPORT" | grep -qE $'^-\t'; then
  bad "status-durations: a status_duration-only events file produced a bogus 'script: -' row"
else
  ok "status-durations: a status_duration-only events file produces no 'script: -' row"
fi

# Jira-api.sh stderr is redacted before
# landing in a warning.
REDACT_JIRA="$WORK/fake-jira-api-redact.sh"
cat > "$REDACT_JIRA" <<'EOF'
#!/bin/bash
if [ "$1" = "raw" ] && [ "$2" = "GET" ]; then
    case "$3" in
        /issue/NWM-505/changelog)
            echo "jira-api: HTTP 401 GET /issue/NWM-505/changelog (token=abcdefghijklmnopqrstuvwxyz0123456789)" >&2
            exit 1
            ;;
    esac
fi
echo "fake-jira-api-redact.sh: unhandled call: $*" >&2
exit 1
EOF
chmod +x "$REDACT_JIRA"
REDACT_OUT=$(run status-durations --events "$WORK/events-redact.jsonl" \
    NWM-505 --jira-api "$REDACT_JIRA" --dry-run 2>&1) \
    || { echo "status-durations (redact test) failed unexpectedly:" >&2; echo "$REDACT_OUT" >&2; exit 1; }
if printf '%s\n' "$REDACT_OUT" | grep -q "<redacted>"; then
  ok "status-durations: jira-api.sh's stderr is redacted before landing in a warning"
else
  bad "status-durations: redaction did not fire (got: $REDACT_OUT)"
fi
if printf '%s\n' "$REDACT_OUT" | grep -q "abcdefghijklmnopqrstuvwxyz0123456789"; then
  bad "status-durations: the long token itself reached stdout/stderr unredacted"
else
  ok "status-durations: the long token never reaches stdout/stderr unredacted"
fi

# NW_DRY_RUN=1 must reach the REAL jira-api.sh as --dry-run: no credential
# resolved, the request printed to stderr, exit 0. A throwaway $NW_JIRA_HOST
# means no config file or real credential is needed.

# Skipped loudly, never silently: these two assert the CONSUMING repo's
# provider behaviour, and this repo has none. Point
# $SCRIPT_ANALYTICS_JIRA_API at one to get them back.
if [ ! -f "$JIRA_API_REAL" ]; then
  echo "skip - status-durations: NW_DRY_RUN=1 against a real jira-api.sh (none at $JIRA_API_REAL; set \$SCRIPT_ANALYTICS_JIRA_API)"
  echo "skip - status-durations: NW_DRY_RUN=1 prints the exact tracker read it WOULD issue (same reason)"
else
DRYRUN_ERR=$(NW_DRY_RUN=1 NW_JIRA_HOST=selftest.invalid \
    run status-durations --events "$WORK/events-nwdryrun.jsonl" \
    NWM-1 --jira-api "$JIRA_API_REAL" 2>&1) && DRYRUN_STATUS=0 || DRYRUN_STATUS=$?
if [ "$DRYRUN_STATUS" -eq 0 ]; then
  ok "status-durations: NW_DRY_RUN=1 against the real jira-api.sh exits 0"
else
  bad "status-durations: NW_DRY_RUN=1 against the real jira-api.sh should exit 0 (got $DRYRUN_STATUS; output: $DRYRUN_ERR)"
fi
if printf '%s\n' "$DRYRUN_ERR" | grep -q "would issue: GET https://selftest.invalid/rest/api/3/issue/NWM-1/changelog"; then
  ok "status-durations: NW_DRY_RUN=1 prints the exact tracker read it WOULD issue"
else
  bad "status-durations: NW_DRY_RUN=1 did not print the expected request (got: $DRYRUN_ERR)"
fi
fi

# ---- NWM-156: no claude-cost sibling, and no ../templates/ -------------
# The whole point of the ticket: script-analytics.py must run from another
# repo's scripts/ directory with neither claude-cost file beside it and no
# templates/ directory above it.
STANDALONE="$WORK/standalone"
mkdir -p "$STANDALONE"
cp "$ANALYTICS" "$STANDALONE/script-analytics.py"
SA_ALONE="$STANDALONE/script-analytics.py"
ALONE_PRICES="$STANDALONE/claude-prices.tsv"

if [ -e "$STANDALONE/claude-cost.py" ] || [ -e "$STANDALONE/claude-cost-scan.py" ] \
   || [ -d "$WORK/templates" ]; then
  bad "standalone: fixture is wrong — a sibling or ../templates/ exists"
else
  ok "standalone: neither claude-cost file nor ../templates/ exists beside the copy"
fi

# CLAUDE_PROJECT_DIR and CLAUDE_PRICES_TSV are stripped on every standalone
# run: an ambient value from the shell running this selftest would otherwise
# decide which price table resolves.
run_alone() { env -u CLAUDE_PROJECT_DIR -u CLAUDE_PRICES_TSV python3 "$SA_ALONE" "$@"; }

ALONE_NOPRICES_ERR=$(run_alone extract --agent-id author1 \
    --events "$WORK/alone-noprices.jsonl" --projects-dir "$PROJECTS_DIR" 2>&1 >/dev/null) \
    && ALONE_NOPRICES_RC=0 || ALONE_NOPRICES_RC=$?
if [ "$ALONE_NOPRICES_RC" -eq 2 ]; then
  ok "standalone: no price table anywhere is a validation failure, exit 2"
else
  bad "standalone: expected exit 2 with no price table (got $ALONE_NOPRICES_RC; output: $ALONE_NOPRICES_ERR)"
fi
if printf '%s\n' "$ALONE_NOPRICES_ERR" | grep -q "templates/claude-prices.tsv" \
   && printf '%s\n' "$ALONE_NOPRICES_ERR" | grep -q "standalone/claude-prices.tsv"; then
  ok "standalone: the not-found error names every candidate path it tried"
else
  bad "standalone: not-found error does not name both candidates (got: $ALONE_NOPRICES_ERR)"
fi

# A price table somewhere else entirely, reachable only through the env var.
ELSEWHERE_PRICES="$WORK/elsewhere/claude-prices.tsv"
mkdir -p "$WORK/elsewhere"
printf 'model\tinput_per_mtok\toutput_per_mtok\tcache_write_per_mtok\tcache_read_per_mtok\n' > "$ELSEWHERE_PRICES"
printf 'claude-sonnet-5\t3.00\t15.00\t3.75\t0.30\n' >> "$ELSEWHERE_PRICES"

ENVPRICES_OUT=$(env -u CLAUDE_PROJECT_DIR CLAUDE_PRICES_TSV="$ELSEWHERE_PRICES" \
    python3 "$SA_ALONE" extract --agent-id author1 \
    --events "$WORK/alone-envprices.jsonl" --projects-dir "$PROJECTS_DIR" 2>&1) \
    && ENVPRICES_RC=0 || ENVPRICES_RC=$?
if [ "$ENVPRICES_RC" -eq 0 ]; then
  ok "standalone: \$CLAUDE_PRICES_TSV supplies the price table when no layout candidate exists"
else
  bad "standalone: \$CLAUDE_PRICES_TSV run failed (rc=$ENVPRICES_RC; output: $ENVPRICES_OUT)"
fi

BADENV_ERR=$(env -u CLAUDE_PROJECT_DIR CLAUDE_PRICES_TSV="$WORK/nope/claude-prices.tsv" \
    python3 "$SA_ALONE" extract --agent-id author1 \
    --events "$WORK/alone-badenv.jsonl" --projects-dir "$PROJECTS_DIR" 2>&1 >/dev/null) \
    && BADENV_RC=0 || BADENV_RC=$?
if [ "$BADENV_RC" -eq 2 ] && printf '%s\n' "$BADENV_ERR" | grep -q 'CLAUDE_PRICES_TSV'; then
  ok "standalone: a \$CLAUDE_PRICES_TSV that names no file is refused, not silently ignored"
else
  bad "standalone: bad \$CLAUDE_PRICES_TSV not refused (rc=$BADENV_RC; output: $BADENV_ERR)"
fi

# Now the layout a receiving repo can actually satisfy: the table beside the
# script, with no templates/ directory anywhere above it.
cp "$ELSEWHERE_PRICES" "$ALONE_PRICES"

ALONE_EXTRACT=$(run_alone extract --agent-id author1 \
    --events "$WORK/alone-events.jsonl" --projects-dir "$PROJECTS_DIR" 2>&1) \
    && ALONE_RC=0 || ALONE_RC=$?
if [ "$ALONE_RC" -eq 0 ]; then
  ok "standalone: extract runs with no claude-cost sibling present"
else
  bad "standalone: extract failed with no claude-cost sibling (rc=$ALONE_RC; output: $ALONE_EXTRACT)"
fi

# Same fixture, same price table, run from this repo: the two events files
# must match byte for byte, so vendoring the helpers moved no number.
RESIDENT_EVENTS="$WORK/resident-events.jsonl"
RESIDENT_OUT=$(env -u CLAUDE_PROJECT_DIR -u CLAUDE_PRICES_TSV python3 "$ANALYTICS" extract \
    --agent-id author1 --events "$RESIDENT_EVENTS" \
    --prices "$ALONE_PRICES" --projects-dir "$PROJECTS_DIR" 2>&1) \
    && RESIDENT_RC=0 || RESIDENT_RC=$?
if [ "$RESIDENT_RC" -ne 0 ]; then
  bad "standalone: the repo-resident comparison run failed (rc=$RESIDENT_RC; output: $RESIDENT_OUT)"
elif diff -q "$RESIDENT_EVENTS" "$WORK/alone-events.jsonl" >/dev/null 2>&1; then
  ok "standalone: the standalone copy emits byte-identical events to the repo-resident run"
else
  bad "standalone: standalone and repo-resident events differ: $(diff "$RESIDENT_EVENTS" "$WORK/alone-events.jsonl" | head -5)"
fi

for fmt in table tsv md; do
  FMT_OUT=$(run_alone report --events "$WORK/alone-events.jsonl" --format "$fmt" 2>&1) \
      && FMT_RC=0 || FMT_RC=$?
  if [ "$FMT_RC" -eq 0 ] && [ -n "$FMT_OUT" ]; then
    ok "standalone: report --format $fmt works with the vendored renderer"
  else
    bad "standalone: report --format $fmt failed (rc=$FMT_RC; output: $FMT_OUT)"
  fi
done

USAGE_OUT=$(run_alone report --events "$WORK/alone-events.jsonl" --usage --format tsv 2>&1) \
    && USAGE_RC=0 || USAGE_RC=$?
if [ "$USAGE_RC" -eq 0 ] && [ -n "$USAGE_OUT" ]; then
  ok "standalone: report --usage works with the vendored renderer"
else
  bad "standalone: report --usage failed (rc=$USAGE_RC; output: $USAGE_OUT)"
fi

if grep -qE 'importlib|_load_module' "$SA_ALONE"; then
  bad "standalone: the script still carries the import-time sibling loader"
else
  ok "standalone: no importlib loader remains in the script"
fi

# ---- NWM-156 drift guard: vendored copies still match their originals --
# A guard, not the red-then-green proof: it compares two files that both
# live in this repo today and it leaves with them. Skipped, not failed, when
# claude-cost.py / claude-cost-scan.py are absent.
if [ "$PARITY" -eq 1 ]; then
  PARITY_PY="$WORK/parity-check.py"
  cat > "$PARITY_PY" << 'PARITYPY'
import importlib.util
import sys
import tempfile


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


SA = load(sys.argv[1], "sa_under_test")
CC = load(sys.argv[2], "cc_original")
CS = load(sys.argv[3], "cs_original")

problems = []

MATRICES = [
    (["a"], []),
    (["script", "usd"], [["x.sh", "0.1234"]]),
    (["h", "wider_header"], [["a", "b"], ["much-longer-cell", "c"]]),
    (["模型", "usd"], [["claude-opus-5", "1.0"]]),
    (["n"], [[0], [12345]]),
]
for fmt in ("table", "tsv", "md"):
    for headers, rows in MATRICES:
        got = SA.RENDERERS[fmt](headers, rows)
        want = CC.RENDERERS[fmt](headers, rows)
        if got != want:
            problems.append("renderer %s diverged on %r: %r != %r" % (fmt, headers, got, want))

if SA.TOKEN_CLASSES != CS.TOKEN_CLASSES:
    problems.append("TOKEN_CLASSES diverged: %r != %r" % (SA.TOKEN_CLASSES, CS.TOKEN_CLASSES))
if SA.PRICE_COLUMNS != CS.PRICE_COLUMNS:
    problems.append("PRICE_COLUMNS diverged: %r != %r" % (SA.PRICE_COLUMNS, CS.PRICE_COLUMNS))

for text in (None, "2026-09-13T10:00:00Z", "2026-09-13T10:00:00+02:00", "2026-09-13T10:00:00"):
    if SA.parse_timestamp(text) != CS.parse_timestamp(text):
        problems.append("parse_timestamp diverged on %r" % (text,))
for bad_text in ("not-a-time", ""):
    sa_err = cs_err = None
    try:
        SA.parse_timestamp(bad_text)
    except Exception as exc:
        sa_err = str(exc)
    try:
        CS.parse_timestamp(bad_text)
    except Exception as exc:
        cs_err = str(exc)
    if sa_err != cs_err or sa_err is None:
        problems.append("parse_timestamp error diverged on %r: %r != %r" % (bad_text, sa_err, cs_err))

prices_tsv = "\t".join(CS.PRICE_COLUMNS) + "\nclaude-sonnet-5\t3.0\t15.0\t3.75\t0.3\n"
with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False) as fh:
    fh.write(prices_tsv)
    prices_path = fh.name
sa_prices = SA.read_prices(prices_path)
cs_prices = CS.read_prices(prices_path)
if sa_prices != cs_prices:
    problems.append("read_prices diverged: %r != %r" % (sa_prices, cs_prices))

tokens = {"input": 1000, "output": 2000, "cache_write": 300, "cache_read": 40000}
for model in ("claude-sonnet-5", "model-with-no-price-row"):
    turn = {"model": model, "tokens": tokens}
    if SA.turn_cost(turn, sa_prices, set()) != CS.turn_cost(turn, cs_prices, set()):
        problems.append("turn_cost diverged for %r" % model)

if problems:
    for line in problems:
        print(line)
    sys.exit(1)
print("parity ok")
PARITYPY
  PARITY_OUT=$(python3 "$PARITY_PY" "$ANALYTICS" "$CC_PY" "$CS_PY" 2>&1) && PARITY_RC=0 || PARITY_RC=$?
  if [ "$PARITY_RC" -eq 0 ]; then
    ok "drift guard: every vendored helper still behaves like its claude-cost original"
  else
    bad "drift guard: a vendored copy has drifted from its original: $PARITY_OUT"
  fi
else
  echo "skip - drift guard: claude-cost.py / claude-cost-scan.py not beside the selftest"
fi

# --- NWM-164: Workflow-tool subagents are two levels deeper. --------------
# Before this, discover_subagents() listed subagents/ one level deep, so every
# Workflow-tool agent recorded nothing and "retire?" was computed from a
# partial population — a wrong answer rather than a missing one.
WF_EVENTS="$WORK/wf-events.jsonl"
run extract --projects-dir "$PROJECTS_DIR" --events "$WF_EVENTS" >/dev/null 2>&1
if grep -q "workflow-only-widget.sh" "$WF_EVENTS"; then
  ok "workflows: a Bash call made inside subagents/workflows/wf_*/ is recorded"
else
  bad "workflows: the Workflow-tool subagent's invoke event is missing entirely"
fi
if grep -q "journal-must-not-appear.sh" "$WF_EVENTS"; then
  bad "workflows: journal.jsonl beside the transcript was scanned as one"
else
  ok "workflows: the journal.jsonl beside it is not mistaken for a transcript"
fi

WF_ONE="$WORK/wf-one.jsonl"
if run extract --projects-dir "$PROJECTS_DIR" --events "$WF_ONE" --agent-id wfagent1 >/dev/null 2>&1 \
   && grep -q "workflow-only-widget.sh" "$WF_ONE"; then
  ok "workflows: --agent-id resolves a nested transcript, not only a flat one"
else
  bad "workflows: --agent-id could not find the Workflow-tool subagent"
fi

WF_COUNTS="$(ANALYTICS="$ANALYTICS" python3 - "$PROJECTS_DIR" <<'PYEOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("sa", os.environ["ANALYTICS"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
found = m.discover_subagents(sys.argv[1], "-fixture-repo", "sess1")
print("%d %s" % (len(found), ",".join(sorted(a for a, _p, _mp in found))))
PYEOF
)"
if [ "$WF_COUNTS" = "4 author1,review1,triage1,wfagent1" ]; then
  ok "workflows: discover_subagents returns both layouts, each exactly once"
else
  bad "workflows: discover_subagents returned [$WF_COUNTS], wanted [4 author1,review1,triage1,wfagent1]"
fi

# The meta.json must be read from beside the transcript, not from the flat
# subagents/ directory — otherwise a workflow agent has no agentType and is
# silently skipped as unmatched.
if grep -q '"agent_type": "script-author"' "$WF_ONE"; then
  ok "workflows: the nested agent's meta.json is read from its own wf_ directory"
else
  bad "workflows: the nested agent's meta.json was not found beside its transcript"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
