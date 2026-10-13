# script-analytics fixtures

`reports/*.md` are four script-reviewer reports recorded on 2026-10-13 from Claude Code transcripts (`~/.claude/projects/**/subagents/agent-<id>.jsonl`, the `input.message` of the
`SubagentHandback` tool_use block). Nothing was reworded. Replaced: a home-directory worktree path prefix became `<worktree>/` or `<scratch>/`, a branch name became `work-branch`, and
one ticket key in parentheses became `(TICKET)`. No hostname, domain, IP address or credential appears in the four reports (the addresses in them are loopback or documentation examples).

| Agent id | Shape | Counts by reading |
| --- | --- | --- |
| `ad18608b52f6f78cd` | numbered `path -- SEVERITY --` items, a "Checked and fine" list, a verdict | 0/1/1/1 |
| `ae1356d98dba29872` | eight numbered `path -- SEVERITY --` items, clean-check prose, blocking list in the verdict | 0/1/4/3 |
| `a47c6fad7bce052bf` | re-check: four FIXED items, "No CRITICAL/HIGH found", a residual "not HIGH" sentence | 0/0/0/0 |
| `aed4a791a7d18cc59` | re-check: a mutation table with no severity cell, a "New findings" list with `none` and one LOW | 0/0/0/1 |

Counts are crit/high/medium/low. `projects/` holds one transcript line per report in the same layout Claude Code writes: a single assistant turn whose content is the `SubagentHandback`
tool_use block, plus `meta.json` with `agentType: script-reviewer`. The line is rebuilt from the recording with only its message, id and usage fields kept; the session id is a placeholder.

Synthetic, and named as such: the events rows and the short tally, table, pair and summary messages the selftest writes inline.
