# CLAUDE.md

Context for Claude Code sessions opened in this repository.

## What this repo is

`moneymikeMD/ai-toolkit` is **public**: shared tooling that a *repository*
consumes, as opposed to config a *machine* applies. Public on purpose — a
GitHub Action can only be consumed from a repo the caller can read, so keeping
this public is what lets a private consumer use it with no credential.

It has **no tracker of its own**. Work is filed against the repo that will
consume the change and says in the ticket body that it lands here, which is why
commit subjects here carry another project's prefixes: `NWM-140`, `NWM-141`,
`WO-029`, `WO-047`, `WO-045`. There is no handoff-doc convention here either.

## Two surfaces, two opposite propagation rules

This is the one thing not to confuse; getting it backwards means either
assuming an unreleased fix is live everywhere, or assuming a landed one is
inert until a tag moves, and both are wrong for half the repo.

| Surface | What | Consumed as | Propagation |
| --- | --- | --- | --- |
| **CI** | `actions/` (4) + their reusable workflow wrappers | `uses: moneymikeMD/ai-toolkit/actions/<name>@v1` | Pinned to the floating major. Landing on `main` changes nothing until `v1` moves. |
| **Operator scripts** | `scripts/` (7), each with its own `<name>-selftest.sh` | Invoked by **absolute path** out of the caller's working checkout | None. Not pinned, not versioned, not released — a save to disk is live to every caller immediately. |

Verified live: `git ls-remote origin refs/tags/v1` and `git rev-parse
v1.6.0`/`main` all resolve to `641f38b`, and `git ls-tree v1 actions/` lists
all four actions — no gap right now. There *was* one: `v1` sat behind `main`
until 2026-09-21 and silently starved every `@v1` consumer of `skill-routing`
and `bar-check` for the day between their landing and the tag move. Don't
trust a stale reading of `v1` — re-run those three checks rather than citing
this paragraph's SHA next week.

## CI (`.github/workflows/ci.yml`)

Six jobs, all on push to `main` and every PR: `selftest` (globs
`scripts/*-selftest.sh` and `actions/*/*-selftest.sh`, so a new script's
selftest runs the moment it lands, no workflow edit needed), `no-personal-paths`
(dogfooded via `uses: ./actions/no-personal-paths` so a break fails this
repo's own build before an `@v1` consumer ever sees it), `shellcheck -S
warning`, `self-lint` (comment-lint, also dogfooded), `bar-check`
(`report-only: "true"` — graduated adoption, matching comment-lint's own
history), and `no-major`.

**Only `selftest` and `self-lint` are required status checks** on the `main`
ruleset (`gh api repos/moneymikeMD/ai-toolkit/rulesets/23685819`). The other
four jobs run and report but don't gate a merge — including `no-major`, which
carries the version cap. Repository admins are ruleset bypass actors, so
nothing mechanical stops a maintainer's merge even with `no-major` red; the
cap holds by rule, not by gate.

Dependabot (`.github/dependabot.yml`) watches only the `github-actions`
ecosystem, weekly, and auto-merges non-major bumps
(`dependabot-auto-merge.yml`) — no `pip` entry, since nothing here is a Python
package.

## Releases and the version cap

`release-please-action@v5`, `release-type: simple`, current release `1.6.0`
(`.release-please-manifest.json` — re-verify with `gh api
repos/moneymikeMD/ai-toolkit/releases/latest --jq .tag_name` rather than
trusting this line). A `major-tag` job in `release-please.yml` re-points the
floating `v1` onto every release's exact tag automatically, the moment
release-please cuts one. **Consuming repos generally do not automate this in
their own CI** — an operator cuts their releases by running
`scripts/release-publish.sh <major|minor|patch>` from *inside*
that checkout (it reads `./.release-please-manifest.json` in the cwd), which
merges the release PR via `pr-land.sh`, waits on CI, then moves the tag via
`tag-major.sh`. `tag-major.sh` refuses to move any name matching `vX.Y.Z` —
only the floating major — and moves it through the GitHub Git Data API with a
read-back check, because a push's own exit code has reported success for a
tag move that didn't land.

**The version cap**: no repo in this ecosystem moves past `v1.x` until the
owner lifts it (owner decision, 2026-09-20). Banned is the *marker*
release-please reads as a major bump — a commit or PR-title subject matching
`^[A-Za-z]+(\([^)]*\))?!:`, or a `BREAKING CHANGE:`/`BREAKING-CHANGE:` footer —
not the change itself: ship it as a plain `feat:` and describe the
incompatibility in prose. `release-publish.sh` also enforces the owner-only
half of this in code, not just in CI: it refuses to publish a major release
without `--i-am-the-owner`. Confirmed present here as CI job `no-major`
(commit `1725a11`). Not every consuming repo runs it — don't assume a repo is
covered without checking its own workflows.

## `scripts/`

`pr-land.sh` (merge behind a required-check gate, deriving any admin bypass
from observed state rather than trusting a caller's flag), `land-queue.sh`
(serialize several PRs through `pr-land.sh`, refreshing each before it merges),
`verify-run.sh` (run a ticket's `verify` frontmatter block against a real
worktree, gating on every line — not just the last one, and not a hardcoded
`cd`), `git-retry.sh` (retry only transient push/fetch/clone/pull failures;
everything else, e.g. a rejected ref or conflict, fails immediately),
`release-publish.sh` and `tag-major.sh` (above), and `workspace.sh` (operates on
every repo a `repos.yaml` manifest names, invoked by path rather than by
`cd`-ing into a repo first).

**`scripts/` is not yet the complete set it is meant to be.** Five more are
assigned here and none have arrived — `land-branch.sh`, `claude-cost.py`,
`script-analytics.py`, `script-retire.sh`, `known-issue.sh` — so each still
lives duplicated in the consuming repos, diverging. Do not read the current
contents as the intended set.

## `actions/`

Four: `comment-lint` (caps a file-header comment at 80 lines, any other
comment run at 4 — length only, not a judgment of usefulness),
`no-personal-paths` (fails a build when a tracked file names a home
directory — wrong in a public repo, and silently broken on every other
machine regardless), `skill-routing` (ranks `SKILL.md` descriptions against
prompt fixtures, fails on a collision), and `bar-check` (fails a diff that
adds a suppression, deletes or skips a test, or edits a threshold down). Every
one defaults `report-only` somewhere in its input surface for graduated
adoption, and every one ships **both** a composite action
(`actions/<name>/action.yml`) and a same-named reusable workflow
(`.github/workflows/<name>.yml`) that wraps it — the wrapper exists because a
reusable workflow's `uses: ./path` resolves against the *caller's* checkout,
not this repo, so it references the action by full `@v1` ref instead of a
local path. Full option lists are in each `action.yml` and in `README.md`;
don't re-derive them here.

NWM-128 wants a `known-issue` action published here and is still blocked on
it — `actions/` has grown from one to four since that ticket was filed, but a
known-issue check isn't among them yet. Separately, work-order's
`conformance/README.md` names `ai-toolkit/scripts/verify-run.sh --against` as
supplying the half of its `[MUST-9]` check the validator can't do itself —
that division of labor is recorded only in prose in another repo; nothing
pins it, and nothing fails here if `verify-run.sh` is renamed or moved.

## The registered-but-dead `release` MCP server

`.mcp.json` registers a `release` MCP server. This repo owns the
*registration* only; the server itself is installed elsewhere. It was fixed
2026-09-21 to read `${HOME}` rather than a literal path — a
`no-personal-paths`-shaped bug in this repo's own config. It has **never
actually connected**: a newly registered MCP server stays at *pending
approval* until a human runs `claude` once, by hand, in the checkout, and an
agent cannot approve one for itself. Don't assume it is live because
`.mcp.json` declares it.
