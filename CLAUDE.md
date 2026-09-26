# CLAUDE.md

Context for Claude Code sessions opened in this repository.

## What this repo is

`moneymikeMD/ai-toolkit` is **public**: shared tooling that a *repository*
consumes, as opposed to config a *machine* applies. Public on purpose — a
GitHub Action can only be consumed from a repo the caller can read, so keeping
this public is what lets a private consumer use it with no credential.

It has **no tracker of its own**. Work is filed against the repo that will
consume the change and says in the ticket body that it lands here, which is why
commit subjects here carry other projects' prefixes (`NWM-`, `LAB-`, `WO-`).
There is no handoff-doc convention here.

## Two surfaces, two opposite propagation rules

Getting this backwards means either assuming an unreleased fix is live
everywhere, or assuming a landed one is inert until a tag moves, and both are
wrong for half the repo.

| Surface | What | Consumed as | Propagation |
| --- | --- | --- | --- |
| **CI** | `actions/` (4) + their reusable workflow wrappers | `uses: moneymikeMD/ai-toolkit/actions/<name>@v1` | Pinned to the floating major. Landing on `main` changes nothing until `v1` moves. |
| **Operator scripts** | `scripts/` (12), each with its own `<name>-selftest.sh`, over `scripts/lib/kit.sh` and `scripts/lib/ghkit.sh` | Invoked by **absolute path** out of the caller's working checkout | None. Not pinned, not versioned, not released — a save to disk is live to every caller immediately. |

`v1` can sit behind `main`. To know whether an `@v1` consumer sees a landed
action change, run all three: `git ls-remote origin refs/tags/v1`,
`git rev-parse main`, and `git ls-tree v1 actions/`. Never cite a remembered
SHA.

## CI (`.github/workflows/ci.yml`)

Six jobs, all on push to `main` and every PR: `selftest` (globs
`scripts/*-selftest.sh` and `actions/*/*-selftest.sh`, so a new script's
selftest runs the moment it lands, no workflow edit needed), `no-personal-paths`
(dogfooded via `uses: ./actions/no-personal-paths` so a break fails this
repo's own build before an `@v1` consumer ever sees it), `shellcheck -S
warning` (over `scripts/*.sh`, `scripts/lib/*.sh` and `actions/*/*.sh`),
`self-lint` (comment-lint, also dogfooded), `bar-check` (`report-only: "true"`),
and `no-major`.

**Only `selftest` and `self-lint` are required status checks** on the `main`
ruleset (`gh api repos/moneymikeMD/ai-toolkit/rulesets/23685819`). No approving
review is required. The other four jobs run and report but do not gate a
merge — including `no-major`, which carries the version cap. Repository admins
are ruleset bypass actors, so nothing mechanical stops a maintainer's merge
even with `no-major` red; the cap holds by rule, not by gate.

Dependabot (`.github/dependabot.yml`) watches only the `github-actions`
ecosystem, weekly, and `dependabot-auto-merge.yml` auto-merges every bump that
is not a semver major.

## Releases and the version cap

`release-please-action@v5`, `release-type: simple`. Read the current version
from `.release-please-manifest.json` or `gh api
repos/moneymikeMD/ai-toolkit/releases/latest --jq .tag_name`; do not trust a
number written in prose. A `major-tag` job in `release-please.yml` re-points
the floating `v1` onto every release's exact tag the moment release-please
cuts one.

The release-please step runs on the `RELEASE_PLEASE_TOKEN` repo secret, a
fine-grained PAT (Contents + Pull requests, read/write), not the default
`GITHUB_TOKEN`. GitHub never runs workflows on a push made with
`GITHUB_TOKEN`, so a release PR pushed with it sits with no checks and
`pr-land.sh` can only reach it through the bot `--admin` path. With the PAT
the release branch push triggers CI like any other. The PAT expires before
2027-09-26 (one-year maximum); when it does, release PRs come back with no
checks, and the fix is to mint a new one and reset the secret, not to
close-and-reopen the PR each time.

Consuming repos generally do not automate this in their own CI. An operator
cuts their releases by running `scripts/release-publish.sh
<major|minor|patch> --repo OWNER/REPO` from any directory (it reads the
manifest from the named repo's default branch), which merges the release PR
via `pr-land.sh`, waits on CI, then moves the tag via `tag-major.sh`. A
component PR is compared against its own manifest key and moves no tag.
`tag-major.sh` refuses to move any name matching `vX.Y.Z` — only the floating
major — and moves it through the GitHub Git Data API with a read-back check,
because a push's exit code does not prove a tag moved.

**The version cap**: no repo in this ecosystem moves past `v1.x` until the
owner lifts it. Banned is the *marker* release-please reads as a major bump — a
commit or PR-title subject matching `^[A-Za-z]+(\([^)]*\))?!:`, or a
`BREAKING CHANGE:`/`BREAKING-CHANGE:` footer — not the change itself: ship it
as a plain `feat:` and describe the incompatibility in prose.
`release-publish.sh` enforces the owner-only half in code: it refuses a major
release without `--i-am-the-owner`. The `no-major` job here is not required,
and not every consuming repo runs one — check a repo's own workflows before
assuming it is covered.

## `scripts/`

`pr-land.sh` (merge behind a required-check gate, deriving any admin bypass
from observed state rather than trusting a caller's flag), `land-queue.sh`
(serialize several PRs through `pr-land.sh`, refreshing each before it merges),
`verify-run.sh` (run a ticket's `verify` frontmatter block against a real
worktree, gating on every line, not just the last one), `git-retry.sh` (retry
only transient push/fetch/clone/pull failures; a rejected ref or a conflict
fails immediately), `release-publish.sh` and `tag-major.sh` (above),
`workspace.sh` (operates on every repo a `repos.yaml` manifest names, by path
rather than by `cd`), `protections.sh`, `known-issue.sh`, `land-core.sh`,
`script-analytics.py` and `script-retire.sh`. `README.md` documents each one's
usage; this file records the constraints a session must not violate.

### `known-issue.sh`

Manages a repo's `docs/known-issues/` entries and the generated
`docs/known-issues.md` index. Subcommands: `add`, `lint`, `reindex`,
`remanifest`, `resolve`, `severity`, `migrate`. `lint` is the drift gate a
consumer runs in CI: it fails any entry whose sha256 no longer matches
`_manifest.json`. `remanifest <slug>...` re-records the named hashes and
`remanifest --drop <slug>...` removes the record of a file that is gone; both
refuse the other's case and write nothing unless every named slug is valid.
There is deliberately no `--all`: accepting a drifted entry is an act, not a
rubber stamp. Never hand-edit `_manifest.json`; that is the edit class `lint`
exists to catch.

The target repo defaults to `git rev-parse --show-toplevel` from cwd, so the
script works when invoked by absolute path from outside. `--root PATH` is
recognised anywhere in the argument list and names the target instead. cwd
stays the default deliberately: a plugin script runs from
`${CLAUDE_PLUGIN_ROOT}`, outside the target repo. Pass `--root` from anything
not already standing in the repo it means to write to; both live consumers
(night-watchman's CI and homelab's `lint.sh`) do.

**No `known-issue` composite action exists, deliberately.** The consuming side
resolves the ai-toolkit checkout by env var and path (night-watchman's
`scripts/ai-toolkit-root.sh`, on the shape of its `work-order-root.sh`) rather
than through a pinned `@v1` action. The general point stands: the `scripts/`
surface cannot serve a CI consumer on its own, because a GitHub runner has no
absolute-path checkout to invoke; a CI consumer needs its own checkout step or
an action.

### `land-core.sh`

Merges a local branch onto a target branch and pushes it, through a
`<repo>-land` integration worktree, behind a four-point hook contract. It is
**not** an alternative to `pr-land.sh`: that one merges a pull request through
the GitHub API behind its required checks, this one merges a local branch with
git. Its `--repo` is **mandatory with no cwd fallback**, unlike `known-issue.sh
--root` and `script-retire.sh --root`, because this path merges, pushes and
deletes a branch and a silent wrong-repo default is unrecoverable. `--dry-run`
calls no hook at all, so a consumer prints its own plan around it.
`--allow-untracked PATH` (repeatable) exempts one untracked file from the
branch-worktree dirty check.

`--lint-cmd` runs through `bash -c`, never word-split: the word-split form
*passes* `true && false`, so a red lint lands. The core carries no
`Co-Authored-By` / `Claude-Session` trailer support; a public tool must not
offer them.

night-watchman's `scripts/land-branch.sh` is a wrapper over this core, not a
copy: the ticket lifecycle stays there, the merge-and-push is here.

### `protections.sh`

Mirrors every repo's live landing rules — required checks, approving reviews,
code-owner review — into `repos.yaml` as generated keys; `--check` is the
drift gate. It records a private repo on GitHub Free as `unavailable` rather
than as no-protections, because the rulesets API answers 403 there and the two
are different facts.

`--store` also writes the facts through the `workspace-state` CLI; off by
default, and it refuses `--check`/`--dry-run`. The CLI is resolved from
`$WORKSPACE_STATE_BIN` then `PATH` and nowhere else — no dotfiles path, this
repo is public. **Exit 4 is passed through**: that CLI uses 4 for "unreachable
or unconfigured" and never for an empty result; `repos.yaml` is written first,
so a 4 means only the store half failed.

It reads two top-level keys, `repos:` and `adjacent_repos:`; `workspace.sh`
reads only `repos:`. `adjacent_repos:` holds repos whose landing policy matters
but which are not subdirectories of the workspace — the container repo the
manifest lives in, a dotfiles checkout elsewhere on disk. `protections.sh`
measures them exactly as members and sets an `adjacent` flag in the emitted
JSON. The key is optional and a name under both keys is an error.
`workspace.sh` must never see them, or `clone` would try to put
`home_workspace` inside `home_workspace/home_workspace`; `workspace-selftest.sh`
holds that, with fixture adjacent entries that have a real remote and a real
directory so a leak into `clone`, `pull`, `foreach` or `gen-settings` goes red
instead of passing vacuously.

### `script-analytics.py` and `script-retire.sh`

They travel together: `script-retire.sh --events FILE` consumes what
`script-analytics.py` records.

**This repo does not ship `templates/claude-prices.tsv`, and that is
deliberate.** `script-analytics.py` resolves its price table in order:
`$CLAUDE_PRICES_TSV`, then `<script>/../templates/`, then `<script>/`, then
`$CLAUDE_PROJECT_DIR/templates/`, then `$CLAUDE_PROJECT_DIR/`. A table here
would win at candidate two and silently shadow every consumer's own prices.
With nothing found it raises an error naming every path it tried plus
`--prices` and `$CLAUDE_PRICES_TSV`. The selftest pins its own copy under
`scripts/fixtures/` so a price edit anywhere cannot redden it.

`$CLAUDE_PROJECT_DIR` is populated for Claude Code *hooks* only; it is unset in
the Bash tool environment. **Outside a hook, `--prices` or `$CLAUDE_PRICES_TSV`
is required**, and any change leaning on `$CLAUDE_PROJECT_DIR` must keep that
escape.

The file's second line is `# script-analytics-extractor-sentinel: v1`.
night-watchman's `script-events-hook.sh` greps for it before invoking the
script, so a foreign `script-analytics.py` on the same path cannot win. Keep
the line.

homelab keeps its own `scripts/dev/script-analytics.py`, which loads
`scripts/dev/claude-cost.py` at runtime for its price helpers; homelab has no
`templates/` directory and no `claude-prices.tsv`. For that consumer this copy
is not a drop-in: every price-table candidate above misses. Open question:
should homelab adopt this copy with `$CLAUDE_PRICES_TSV` set, or keep its own?

`claude-cost.py` stays in night-watchman: a script invoked by a hook inside a
shipped plugin is machine-applied, not repo-consumed, so it sits on the plugin
side of the boundary rule.

**`script-retire.sh` takes `--root PATH`.** Without it the repo it retires
from is the caller's cwd — deliberate, because a fixture repo invokes it by
path from outside itself. This path `git rm`s, commits and hands off to a
`land-branch.sh`, so a drifted cwd deletes files in whichever repo it is
standing in. An absolute path into ai-toolkit implies nothing about cwd; pass
`--root`. Empty, missing or non-git `--root` is an error, never a fall back to
cwd.

**`script-retire.sh --yes` requires a `land-branch.sh` that is not here.** It
resolves `${LAND_BRANCH_SH:-$HERE/land-branch.sh}`, and the existence check
sits inside the `--yes` branch only. Report mode works with no land-branch.sh;
`--yes` fails loudly (`Error: cannot find land-branch.sh at …`) rather than
half-landing. Set `$LAND_BRANCH_SH` to the consuming repo's copy before using
`--yes`.

### `scripts/lib/kit.sh` and `scripts/lib/ghkit.sh`

`kit.sh` is the single copy of the generic helpers: `die`, `warn`, `need`,
`show_help`, `known_command`, `tmpfile`. **The admission rule is "is it
generic", not "is it used today".** Nothing here may name a host, a vault, a
multiplexer or any other specific tool; a helper bound to one belongs in the
consuming repo. `warn` is here though nothing calls it, because it is generic
and pairs with `die`.

`ghkit.sh` is separate because `gh` is a specific tool. It holds
`gh_unreadable_branch_rules` and `gh_required_contexts`, which returns
**three** outcomes: read (possibly empty), not-visible (403/404), failed.
`pr-land.sh` and `land-queue.sh` both call it, so "what does this base
require" has one implementation. A rules read that fails for any reason
other than 403/404 is a refusal, not evidence of an absence.

`show_help` (prints the caller's own `#` header) is a second help convention
beside the `usage()` heredoc the older scripts hand-write; both are live and
that is known.

**`tmpfile` takes a variable name (`tmpfile ENGINE`) and assigns into the
caller's shell.** Never `f=$(tmpfile)`: a command substitution runs in a
subshell, so the cleanup trap registered there fires and deletes the file
before the caller sees the path, and the caller then recreates it at the
default umask — mode 0644 instead of 0600, and leaked into `TMPDIR`. This is
a security class of bug, not a nit: the same defect in homelab's `labkit.sh`
leaked thousands of temp files, some holding real 1Password values.
`scripts/kit-selftest.sh` covers it. homelab's `labkit.sh` keeps the
`f=$(tmpfile)` signature and moved the registry into a file instead; the two
libraries solve the same defect deliberately differently and should not be
made to converge.

bash keeps **one** EXIT handler, so a script that sources `kit.sh` and sets
its own `trap ... EXIT` silently replaces `_kit_cleanup` and stops cleaning
up. No script sourcing `kit.sh` traps EXIT. `git-retry.sh` and `land-queue.sh`
trap EXIT and do not source `kit.sh`, so the collision is one `source` away
in either. A caller that needs both adds a `kit_on_exit` registration rather
than trapping directly.

### Before accepting a script: find its third consumer surface

The two-surfaces table describes what **this repo publishes**. It does not
describe what a donor repo serves, and there is a third consumer class that
is invisible from here and fails silently for strangers:
`${CLAUDE_PLUGIN_ROOT}/scripts/<name>`, referenced from a plugin's shipped
skills, agents and hooks. A marketplace installer of that plugin has
`CLAUDE_PLUGIN_ROOT` and **no ai-toolkit checkout at all**, so deleting a
script from the donor turns every such reference into a dead path for every
external adopter while the donor's CI and the operator's machine stay green.

**Before accepting any script here, grep the donor for
`${CLAUDE_PLUGIN_ROOT}/scripts/<name>` as well as its CI.** The check is
mandatory; rerouting is not. It can be a reason to leave a script where it is
(`claude-cost.py`), or to reroute through a resolver shim that ships with the
plugin (`known-issue.sh`, via night-watchman's `scripts/ai-toolkit-root.sh`),
or to change nothing because the plugin keeps a wrapper (`land-branch.sh`,
referenced twice from night-watchman's `skills/session-start/SKILL.md`). Only
a whole-file move forces a reroute.

**State the adopter cost out loud when you do reroute.** A resolver shim means
an adopting repo needs a checkout or an env var where the script used to ship
inside the plugin.

## `actions/`

Four: `comment-lint` (caps a file-header comment at 80 lines, any other
comment run at 4 — length only, not a judgment of usefulness),
`no-personal-paths` (fails a build when a tracked file names a home
directory — wrong in a public repo, and silently broken on every other
machine regardless), `skill-routing` (ranks `SKILL.md` descriptions against
prompt fixtures, fails on a collision), and `bar-check` (fails a diff that
adds a suppression, deletes or skips a test, or edits a threshold down). Every
one takes `report-only` for graduated adoption, and every one ships **both** a
composite action (`actions/<name>/action.yml`) and a same-named reusable
workflow (`.github/workflows/<name>.yml`) that wraps it — the wrapper exists
because a reusable workflow's `uses: ./path` resolves against the *caller's*
checkout, not this repo, so it references the action by full `@v1` ref.
Full option lists are in each `action.yml` and in `README.md`.

work-order's `conformance/README.md` names `ai-toolkit/scripts/verify-run.sh
--against` as supplying the half of its `[MUST-9]` check the validator cannot
do itself. That division of labour is recorded only in prose in another repo;
nothing pins it, and nothing fails here if `verify-run.sh` is renamed or moved.

## The `release` MCP server

`.mcp.json` registers a stdio MCP server named `release` at
`${HOME}/.claude/mcp/release/server.js`. This repo owns the *registration*
only; the server is installed by dotfiles. It exposes `pr_land`,
`release_publish`, `tag_major` and `checks`, each of which execs the script
above that owns the behaviour. A newly registered MCP server stays at
*pending approval* until a human runs `claude` once in the checkout; an agent
cannot approve one for itself. Whether it is live in a given session is
answered by whether `mcp__release__*` tools are listed, not by `.mcp.json`.
