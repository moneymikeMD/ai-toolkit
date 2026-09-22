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
| **Operator scripts** | `scripts/` (11), each with its own `<name>-selftest.sh`, over `scripts/lib/kit.sh` and `scripts/lib/ghkit.sh` | Invoked by **absolute path** out of the caller's working checkout | None. Not pinned, not versioned, not released — a save to disk is live to every caller immediately. |

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

`known-issue.sh` (manage a repo's `docs/known-issues/` entries and the
generated `docs/known-issues.md` index; `lint` is the drift gate a consumer
runs in CI), arrived 2026-09-21 under NWM-128. It gained `remanifest` under
NWM-154 (2026-09-22): `lint` fails any entry whose sha256 no longer matches
`_manifest.json`, and until then there was **no supported way back to green**
once one had drifted — a consumer adopting this onto a corpus with history hit
it on day one. `remanifest <slug>...` re-records the named hashes and
`remanifest --drop <slug>...` removes the record of a file that is gone; both
print what they did, refuse the other's case, and write nothing unless every
named slug is valid. There is deliberately no `--all`, because acceptance has
to be an act rather than a rubber stamp, and the manifest failures in `lint`
now name the repair path instead of being a dead end.

Worth knowing what the absence cost: homelab's corpus was red with exactly
this — 11 stale hashes and 1 orphaned key — and it went green in commit
`9c8d5e0`, whose subject is about taking this script from ai-toolkit, by
**hand-editing `_manifest.json`**. That is precisely the edit class the check
exists to catch, done because nothing else was available.

`protections.sh` (mirror every repo's live landing rules — required checks,
approving reviews, code-owner review — into `repos.yaml` as generated keys,
and `--check` as the drift gate), arrived 2026-09-22 under LAB-292. It records
a private repo on GitHub Free as `unavailable` rather than as no-protections,
because the rulesets API answers 403 there and the two are different facts.
Its state-store half went live 2026-09-22 once LAB-291's CLI existed:
`--store` writes the same facts through `workspace-state`, off by default and
refusing `--check`/`--dry-run`. The CLI is resolved from
`$WORKSPACE_STATE_BIN` then `PATH` and nowhere else — no dotfiles path, this
repo is public. **Exit 4 is passed through**, because that CLI uses 4 for
"unreachable or unconfigured" and never for an empty result; `repos.yaml` is
written first, so a 4 means only the store half failed.

**Four scripts were assigned here, and three have arrived.** `known-issue.sh`
under NWM-128 (Completed), `script-analytics.py` and `script-retire.sh`
together under NWM-130 (Completed). Only `land-branch.sh` is outstanding, as
NWM-131 — and that is a *wrapper split*, not a move: the generic core comes
here and the ticket lifecycle stays in night-watchman.

**`claude-cost.py` was never a fifth assignment, and counting it as one is a
mistake this file made for a day.** NWM-129 is Completed *as satisfied in
place*: a script invoked by a hook inside a shipped plugin is machine-applied,
not repo-consumed, so it stays on the plugin side of the boundary rule. It is
not a pending arrival, and nothing here is waiting for it.

### `script-analytics.py` and `script-retire.sh`, and two things to know

They came together because `script-retire.sh --events FILE` consumes what
`script-analytics.py` records; splitting them leaves a half-working pair. Both
are night-watchman's copies, which are the later hardened ones.

**This repo does not ship `templates/claude-prices.tsv`, and that is
deliberate.** `script-analytics.py` resolves its price table in order:
`$CLAUDE_PRICES_TSV`, then `<script>/../templates/`, then `<script>/`, then
`$CLAUDE_PROJECT_DIR/templates/`, then `$CLAUDE_PROJECT_DIR/`. Shipping a
table here would win at candidate two and **silently shadow every consumer's
own prices** — measured 2026-09-22: with one present, night-watchman's run
resolved to ai-toolkit's table rather than its own; with it absent, to
`night-watchman/templates/claude-prices.tsv`, which is right. With nothing to
find it raises an error naming every path it tried plus `--prices` and
`$CLAUDE_PRICES_TSV`. The price table is the consumer's data, not this tool's.
The selftest pins its own copy under `scripts/fixtures/` so a price edit
anywhere cannot redden it.

**Two of those five candidates never fire outside a hook.**
`$CLAUDE_PROJECT_DIR` is populated for Claude Code *hooks* only — measured
2026-09-22, it is unset in the Bash tool environment, so an agent or a human
at a shell falls straight past both `$CLAUDE_PROJECT_DIR` candidates to the
error. The 2026-09-22 measurement above that showed night-watchman's own table
winning was taken with the variable set by hand; it is a true statement about
resolution order and a misleading one about ordinary use. **In practice
`--prices` or `$CLAUDE_PRICES_TSV` is required outside a hook**, and any
future change leaning on `$CLAUDE_PROJECT_DIR` needs that escape kept.

**And one consumer's price table is not a table at all.** homelab's
`scripts/dev/script-analytics.py` loads `scripts/dev/claude-cost.py` at
runtime via `importlib.util.spec_from_file_location` and reuses its `usd_cost`
and price-table helpers; homelab has **no `templates/` directory and no
`claude-prices.tsv` anywhere**. NWM-129 kept `claude-cost.py` there on
purpose, so for that consumer this copy does not relocate the price source —
it *removes* it, and every resolution candidate above misses. homelab has
correctly not retired its copy. That is the mirror image of the shadowing
problem: a table here outranks a consumer's own, and a consumer may not have a
table to outrank. The options are on LAB-228 comment 10956 and the choice is
the owner's; what belongs here is that **the swap is not drop-in for homelab,
and assuming it is would break that repo's cost reporting silently.**

**`script-retire.sh` takes `--root PATH` (LAB-300, 2026-09-22).** Without it
the repo it retires from is the caller's cwd — deliberate, because a fixture
repo invokes it by path from outside itself. But this path `git rm`s, commits
and hands off to `land-branch.sh`, so a drifted cwd deletes files in whichever
repo it is standing in. That is NWM-145's hazard on a destructive path, and it
got sharper when homelab retired its own copy: the documented form used to be
`./scripts/dev/script-retire.sh`, whose leading `./` implied a cwd inside the
target. An absolute path into ai-toolkit implies nothing. Empty, missing or
non-git `--root` is an error, never a fall back to cwd.

Found and measured by the homelab session, which handed it over rather than
reaching across into this repo — the right call, and the reason the fix is
here rather than worked around there.

**`script-retire.sh --yes` requires a `land-branch.sh` that is not here.** It
resolves `${LAND_BRANCH_SH:-$HERE/land-branch.sh}`, and the existence check
sits inside the `--yes` branch only. So report mode works fine with no
land-branch.sh (measured: exit 0), and `--yes` fails loudly — `Error: cannot
find land-branch.sh at …` — rather than half-landing. That is a documented
precondition, not a defect: set `$LAND_BRANCH_SH` to the consuming repo's copy
before using `--yes`. The parameter already existed; nothing needed adding.

### `scripts/lib/kit.sh` — why there is a library here now

Decided 2026-09-21 under NWM-128, having to be decided before `known-issue.sh`
could move at all. Until that day every script here was standalone — seven
scripts, no shared library, `grep -l '^\. \|^source ' scripts/*.sh` empty. The
incoming scripts source night-watchman's `scripts/lib/kit.sh`, so the choice
was: bring the library, inline its helpers into each script, or take a subset.

**The library came.** Inlining would have duplicated five function bodies
across two scripts and left them to drift, which is the exact failure this repo
exists to end — it is the single copy, so it may not reintroduce copies
internally. The standalone property it costs was never a stated choice: six
commits each added one small script, no commit message or `README.md` line ever
claimed it, so it was an artefact of scripts arriving one at a time rather than
a constraint anyone set.

**The admission rule is "is it generic", not "is it used today".**
`herdr_notify` did not come: it names one specific terminal multiplexer, and a
public generic toolkit must not carry a helper bound to a particular tool — the
same boundary rule that keeps hosts and vaults out of this repo. `warn` did
come though nothing here calls it yet, because it is generic and pairs with
`die`. Six helpers: `die`, `warn`, `need`, `show_help`, `known_command`,
`tmpfile`. Add to it on that rule; do not add a helper a consuming repo should
own.

**There is a second library now: `scripts/lib/ghkit.sh`** (NWM-162,
2026-09-22). It holds the GitHub reads more than one script must agree about,
and it is separate from `kit.sh` for kit.sh's own stated reason — kit.sh may
not name a specific tool, and `gh` is one. It currently holds
`gh_required_contexts`, which returns **three** outcomes: read (possibly
empty), not-visible (403/404), failed. `pr-land.sh` and `land-queue.sh` both
call it; before that they read the same fact two ways, and the wrong one was
in the script that lands a queue unattended.

Two consequences to keep in mind. `scripts/*.sh` does **not** glob
`scripts/lib/*.sh`, so the `shellcheck` job names both — a new lib file is
covered only because that glob is there. And `show_help` (prints the caller's
own `#` header) is a second help convention beside the `usage()` heredoc the
older seven scripts hand-write; converting them was out of scope, so both
conventions are live and that is known, not an oversight.

**`tmpfile` was fixed on the way in, so this copy is not byte-identical to
night-watchman's.** It took no argument and echoed its path, which meant every
caller wrote `f=$(tmpfile)` — a command substitution, so the cleanup trap it
registered fired in that subshell and deleted the file before the caller saw
the path. The caller then recreated it at the default umask. Measured: mode
0644 rather than the documented 0600, and the file leaked into `TMPDIR` on
every run, so neither guarantee the header promised actually held. It now takes
a variable name (`tmpfile ENGINE`) and assigns into the caller's shell, where
the trap works. `scripts/kit-selftest.sh` covers it and is red on four
assertions against the original file.

homelab hit the identical bug in `scripts/lib/labkit.sh` and fixed it the other
way, under LAB-103: it kept the `f=$(tmpfile)` signature and moved the registry
from a shell variable into a *file*, which survives the subshell. That is the
better trade at 30+ call sites; here there were two, so changing the signature
was cheaper than carrying a registry file that itself needs cleaning up. Worth
knowing before assuming the two libraries should converge — they solved the
same defect deliberately differently. Worth knowing too what it cost there:
3,523 leaked temp files on the owner's Mac, some holding real 1Password field
values. This is not a cosmetic class of bug.

One hazard inherited with the pattern, which homelab filed as LAB-104: bash
keeps **one** EXIT handler, so a script that sets its own `trap ... EXIT`
silently replaces `_kit_cleanup` and stops cleaning up. Nothing sourcing
`kit.sh` traps EXIT today, but `git-retry.sh` and `land-queue.sh` both do, so
the collision is one `source` away. It is called out in `kit.sh`'s header at
the point of use. If a caller ever needs both, add a `kit_on_exit` registration
the way labkit did rather than trapping directly.

### Before accepting a script: find its third consumer surface

The two-surfaces table above describes what **this repo publishes**. It does
not describe what the donor repo was serving, and there is a third consumer
class that is invisible from here and fails silently for strangers:
`${CLAUDE_PLUGIN_ROOT}/scripts/<name>`, referenced from a plugin's shipped
skills, agents and hooks.

A marketplace installer of that plugin has `CLAUDE_PLUGIN_ROOT` and has **no
ai-toolkit checkout at all**. So deleting a script from the donor turns every
such reference into a dead path for every external adopter, while the donor's
own CI and the operator's own machine stay green — the failure lands only on
third parties, who have no way to report it.

Found the hard way on NWM-128. The plan and the receiving side both looked at
CI usage and missed four references in two shipped skills
(`tickets-protocol`, `session-start`) and one agent (`librarian`).
night-watchman fixed it by routing them through a
`scripts/ai-toolkit-root.sh` shim that ships **with the plugin** and exits 1
naming what to set, on the same shape as its existing `work-order-root.sh`.

**So before accepting any further script here, grep the donor for
`${CLAUDE_PLUGIN_ROOT}/scripts/<name>` as well as its CI.** The same shape
decided NWM-129: a `plugin.json` SessionEnd hook hardcodes
`$PLUGIN_ROOT/scripts/claude-cost*.py`, and rather than reroute it, the owner
closed that ticket as satisfied in place. So this is a recurring shape, not
one ticket's accident — and note it can be a *reason to leave a script where
it is* as readily as a thing to fix on the way in. `land-branch.sh` (NWM-131)
already has two such references, at `session-start/SKILL.md:155` and `:339`.

**Running the check is mandatory; rerouting is not.** NWM-131 is a *wrapper
split* — the generic merge-and-push core comes here, the ticket lifecycle
stays in night-watchman as a wrapper — so those two paths may correctly keep
pointing at the retained wrapper and need no change at all. Decide it
deliberately rather than discover it; the check tells you which, and only a
whole-file move forces a reroute.

**State the adopter cost out loud when you do reroute.** A resolver shim means
an adopting repo now needs a checkout or an env var where the script used to
ship inside the plugin. That is a real cost this repo imposes on consumers, and
it is the part most likely to be forgotten later.

### Paths are the caller's, and cwd is what resolves them

`known-issue.sh` takes its target from `git rev-parse --show-toplevel`, not
from its own location, which is what makes it work at all when invoked by
absolute path from outside — the surface every script here is consumed on.
**`--root PATH` landed under NWM-145 (2026-09-22)** and is recognised anywhere
in the argument list, so a call can name its target instead of inheriting it.
cwd stays the default, deliberately: a plugin script runs from
`${CLAUDE_PLUGIN_ROOT}`, outside the target repo entirely, and changing the
default would break that case.

So the hazard is now a choice rather than a precondition. A call without
`--root` still lands wherever cwd is, and from a worktree with drifted cwd
that is silently the wrong repo — it happened twice in one week (NWM-122,
NWM-142). Pass `--root` from anything that is not already standing in the
repo it means to write to.

The two live `lint` call sites were measured on 2026-09-22 and neither can
write into the wrong repo: `lint` is read-only (it loads, compares and
prints — no write path), night-watchman's CI runs it with cwd at its own
checkout, and homelab's `lint.sh` wraps it in `(cd "$REPO_ROOT" && …)`. Both
were run against their real corpora — 27 and 107 entries — with the target
trees' digests identical before and after. Adopting `--root` at those two
call sites is NWM-159 and LAB-298, filed so the correctness stops depending
on a caller holding cwd right.

**No `known-issue` composite action is published, and that is deliberate.**
NWM-128's text asks for one, written when this repo did not yet exist (it still
carries `Blocked_by: ai-toolkit existing and publishing the action`). The
consuming side chose otherwise: night-watchman resolves the ai-toolkit copy by
env var and checkout path, the way `work-order-root.sh` already resolves its
dependency, rather than through a pinned `@v1` action. Do not read the missing
action as an oversight to correct. The general point stands though — the
`scripts/` surface cannot serve a CI consumer, because a GitHub runner has no
absolute-path checkout to invoke; a CI consumer needs either its own checkout
step or an action.

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

NWM-128's text asked for a `known-issue` action to be published here. That
ticket is **Completed** — `known-issue.sh` landed in `f81cd50` — and no such
action exists, deliberately; the reasoning is under "No `known-issue`
composite action is published" above. `actions/` has grown from one to four
since that ticket was filed, and nothing is waiting on a fifth. Separately,
work-order's
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
