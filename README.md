# ai-toolkit

Shared, repo-consumed tooling. Public so that any repository — public or
private — can consume it from CI without a credential.

## What belongs here

The test is whether a **machine applies it** or a **repo calls it**.

| | |
| --- | --- |
| A machine applies it | `dotfiles` (private) — shell, editor and agent config, applied to a home directory |
| A repo calls it | **here** — CI actions, linters, anything invoked from a workflow or a repo-scoped checkout |

This repository is public. Nothing naming a host, a vault, an address or any
other personal infrastructure may be committed to it.

## comment-lint

Fails a build when comments run longer than the comment rule allows: a file
header documents usage and flags and caps at 80 lines; any comment run below
the header caps at 4.

It is line-based, not a parser. It measures **length**, which is the
mechanically checkable half of the rule — it cannot tell a necessary comment
from a useless one. Judgement stays with the reviewer.

It deliberately does not count heredoc bodies, YAML block scalars, Python
docstrings, shellcheck directives, shebangs or coding lines. A script that
writes Markdown from a heredoc is not commenting.

### As a step

```yaml
- uses: actions/checkout@v4
- uses: moneymikeMD/ai-toolkit/actions/comment-lint@v1
```

With options:

```yaml
- uses: moneymikeMD/ai-toolkit/actions/comment-lint@v1
  with:
    max-block: "4"
    report-only: "true"   # count violations without failing the build
```

### As a whole job

```yaml
jobs:
  comment-lint:
    uses: moneymikeMD/ai-toolkit/.github/workflows/comment-lint.yml@v1
    with:
      report-only: "true"
```

### Locally

```bash
python3 actions/comment-lint/comment-lint.py            # walks git ls-files
python3 actions/comment-lint/comment-lint.py --stats     # per-file ratios, no gate
./actions/comment-lint/comment-lint-selftest.sh          # 13 fixture assertions
```

## no-personal-paths

Fails a build when a tracked file names somebody's home directory. Two bugs at
once: in a public repo it names a person, and anywhere it resolves nowhere on
another machine — so a config carrying one (an `.mcp.json` server path, a compose
volume, an Alloy `__path__`) is silently broken in every other checkout.

### As a step

```yaml
- uses: actions/checkout@v4
- uses: moneymikeMD/ai-toolkit/actions/no-personal-paths@v1
```

### As a whole job

```yaml
jobs:
  no-personal-paths:
    uses: moneymikeMD/ai-toolkit/.github/workflows/no-personal-paths.yml@v1
```

### Locally

```bash
python3 actions/no-personal-paths/no-personal-paths.py          # walks git ls-files
python3 actions/no-personal-paths/no-personal-paths.py --stats  # what was scanned, no gate
./actions/no-personal-paths/no-personal-paths-selftest.sh       # 25 fixture assertions
```

### Declaring a deliberate fixture

A test fixture often needs a realistic absolute path. Declare those in
`.github/personal-paths-allow` — a path glob, or `name:<who>` for a fake home
directory used across several files:

```
# gitignore-style globs
hooks/fixtures/**
providers/*/*/fixtures/**

# or exempt the fake identity itself, wherever it appears
name:fixture
name:adopter
```

`runner`, `root`, `ubuntu` and `linuxbrew` are exempt already — `/home/runner`
is the GitHub Actions home, not a person. `CHANGELOG.md` is exempt because
release-please generates it from commit messages, so a path quoted in a commit
body would otherwise fail a build nobody can fix without rewriting history.

**Why an allowlist and not a narrower file filter.** Scanning only config-shaped
files would let a leak through in a `.md` or a `.sh`, which is where they
actually accumulate. An exception you have to write down is an exception a
reviewer sees in a diff.

## Adopting it in a repo that has a backlog

Point it at an existing repository and it will light up. Start with
`report-only: "true"`, read `--stats`, and turn the gate on once the count is
near zero. Two traps worth knowing before anyone starts deleting:

**Check whether headers are load-bearing.** In some repositories a script's
leading comment block *is* its `--help` output, rendered at runtime. Trimming
a header there silently truncates the help text.

**Diff the non-comment lines mechanically after a cleanup.** A comment-removal
pass that drops a `set -euo pipefail` by an off-by-one can leave every test
still passing. Strip comments from both versions and diff what is left.

## git-retry

Runs a git command and retries **only** transient network failures. For callers
that run several git operations at once, where a dropped connection is common
and a retry a second later usually succeeds.

```bash
scripts/git-retry.sh push -u origin my-branch
scripts/git-retry.sh fetch --prune origin
GIT_RETRY_ATTEMPTS=5 GIT_RETRY_BASE_DELAY=3 scripts/git-retry.sh push origin main
```

A rejected ref, a merge conflict or a bad path fails immediately. Only
transport errors are retried, and git's own exit code and output are passed
through unchanged.

**Why it matches stderr rather than the exit code.** git exits 128 for every
fatal error, so the exit code cannot tell "the connection dropped" from "you
are not allowed to push that". Matching the message is the only way to
distinguish them, which also means the pattern list is the thing to extend when
a new transport error shows up.

**Why the backoff has jitter.** The failure this exists for is bursty — several
callers failing at the same moment because they opened connections at the same
moment. Retrying instantly from all of them recreates the burst, so each
attempt waits longer, with a small per-process offset so they do not
resynchronise.

It is a script rather than an action on purpose: the failure it addresses
happens on developer and agent machines, not in CI, where the runner already
has its own retry behaviour.

## pr-land

Merges a PR, but only after checking the base branch's actual required
status checks against the actual check-runs on the PR's head SHA — not from
memory, which has been wrong twice in one hour.

```bash
scripts/pr-land.sh 42
scripts/pr-land.sh 42 --repo owner/repo
scripts/pr-land.sh 42 --dry-run
scripts/pr-land.sh 42 --merge-state-poll-s 60
```

The decision, in order: any required context present and failed, cancelled or
timed out is a refusal, naming which one; required contexts absent **and** the
PR authored by a bot is a squash merge with `--admin`; every required context
green while the PR is `BLOCKED` with `reviewDecision` `REVIEW_REQUIRED` is a
squash merge with `--admin`; every required context green otherwise is a plain
squash merge; anything else — pending, or partially absent on a human PR — is a
refusal.

**`--admin` is derived, never a parameter.** Its two paths are the two cases
the owner's grant of 2026-09-19 clears. A bot-authored PR (for example, a
release-please PR running on `GITHUB_TOKEN`) triggers a workflow run GitHub
never actually executes: zero jobs, zero check-runs, and the required contexts
are permanently *absent* rather than failed. A review-gated repo — the resting
state of every repo here, with no second reviewer for the gate to summon —
reports `REVIEW_REQUIRED` forever. The script reasons its way to both instead
of a caller asking for either.

**A check that ran and failed is never bypassed**, on any path, and any other
check that ran and failed on the same head SHA cancels both bypasses too. That
boundary is the point of deriving `--admin` rather than accepting it, and it
carries its own named assertion in `pr-land-selftest.sh`.

**`mergeStateStatus` is computed lazily** and answers `UNKNOWN` until GitHub
has computed it, so it is re-read on a bounded budget (`--merge-state-poll-s`,
default 30s). An `UNKNOWN` that never settles derives no bypass.

**The PR's state is always read back after a merge attempt**, and the exit
code depends on that read, not on the merge command's own exit status. A
classifier denial is not proof a merge did not happen — an already-merged PR
has returned a denial after the fact — so the read-back is unconditional.

## verify-run

Runs a ticket's `verify` frontmatter block with the rules a hand-rolled
runner keeps forgetting built in, instead of remembered.

```bash
scripts/verify-run.sh path/to/TICKET.md --root ~/code/wt-ticket-repo
scripts/verify-run.sh path/to/TICKET.md --root ~/code/wt-ticket-repo --against main
scripts/verify-run.sh path/to/TICKET.md --root ~/code/wt-ticket-repo --format json
```

The block runs under `set -e`, so every line gates the result rather than
only its last one; the block's own `cd ~/code/<repo>` line is replaced by
`--root`, so it runs against a worktree instead of whatever that path
happens to resolve to on the machine running it; a line ending in
`|| echo ...` is rejected before anything runs, because that idiom always
exits 0; and `--against REF` runs the block in a scratch worktree at REF
first and fails if it passes there, since a block that passes before the
work exists is not testing anything. No shell trace flag is ever set, and
the script's own source is checked for that string.
## land-queue

Lands a list of PRs against one repo, serialized and refreshed, and shells
out to `pr-land.sh` for the merge decision itself — it is never
reimplemented here, and `--admin` is never passed to it.

```bash
scripts/land-queue.sh 42 43 44 --repo owner/repo
scripts/land-queue.sh 42 --wait-checks-s 900 --stop-on-refusal
scripts/land-queue.sh 42 --merge-state-poll-s 90
scripts/land-queue.sh 42 --dry-run
```

It exists for two guarantees a lone merge decision does not provide: one
landing at a time per repo (a lock keyed on the repo slug, never a checkout
path), and freshness. Freshness is four things: a PR behind its base is updated
before it is handed to the merge gate; a PR conflicting with its base is
refused here, naming the base and the files it changes, rather than failing at
the merge gate and reporting the wrong reason; a required check with no
conclusion is waited for whoever moved the head SHA, not only when this run
moved it; and no decision is taken on a `mergeStateStatus` of `UNKNOWN`, which
is what GitHub answers until it has computed that field. After this run lands
something, the next PR's first read is discarded, because it can still answer
from the computation GitHub did against the old base.

A PR whose merge is not confirmed by reading its state back afterward is
reported refused, regardless of what `pr-land.sh`'s own exit code said.

Every call to `gh` goes through one of five named functions —
`repo_default_slug`, `pr_read`, `pr_files`, `pr_update_branch`,
`pr_wait_checks` — and the selftest asserts that on the source, because the
first thing that happened to the seam was a fourth call site appearing
somewhere else.

It does not resolve a conflict; it turns a silent, discovered-late pile-up
of PRs into immediate, serialized, one-at-a-time refusals.

## release-publish

Publishes a release-please release end to end: checks the open PR against
the level you asked for, merges it through `pr-land.sh`, waits for the
resulting release and CI, then repoints the floating major tag through
`tag-major.sh`. What used to be six manual steps, each individually
verifiable and none of them written down.

```bash
scripts/release-publish.sh minor
scripts/release-publish.sh patch --repo owner/repo
scripts/release-publish.sh major --i-am-the-owner
scripts/release-publish.sh minor --dry-run
```

Run from inside the target repo's checkout — it reads
`.release-please-manifest.json` there to know the current version.

**A major release is refused without `--i-am-the-owner`.** Majors remain
the owner's call; that boundary is enforced in code, not left as a
sentence in a handoff document a wave agent never reads.

**More than one open release-please PR is a refusal, not a guess.** A
sibling package's release PR can be open at the same time, and merging
one leaves the other DIRTY against the shared manifest file until
release-please's own bot catches up. Pass `--pr NUMBER` to say which one.

**The merge itself is `pr-land.sh`'s job.** This script only decides
*whether* to publish; the required-check gate has one implementation, not
two that can drift apart.

## tag-major

Repoints the floating major tag (`v1`) onto the newest real version tag
(`v1.2.3`) — the one step release-please does not take on its own.

```bash
scripts/tag-major.sh
scripts/tag-major.sh --repo owner/repo
scripts/tag-major.sh --dry-run
```

**A real version tag is never the thing that moves.** Only the floating
major is re-pointed; a genuine `vX.Y.Z` tag is refused as a target even if
something asks for it — that guard is the reason this script exists.

**The move goes through the GitHub Git Data API, not a local push**, so
it needs no checkout at all once `--repo` is known. The ref is read back
afterward and the script fails unless the read-back SHA matches the
intended commit — a push reporting success has not always meant the tag
actually moved.

## workspace

Operates on every repo a workspace manifest names, and generates the agent
read scope from it. A workspace is a directory holding a `repos.yaml` and one
subdirectory per project, each its own independent git clone.

```bash
scripts/workspace.sh list                       # name, branch, agent flag, url
scripts/workspace.sh clone                      # clone whatever is missing
scripts/workspace.sh status                     # branch, dirty count, unpushed count
scripts/workspace.sh pull                       # ff-only, skipping dirty repos
scripts/workspace.sh foreach -- git log -1      # run a command in each repo
scripts/workspace.sh gen-settings               # write additionalDirectories
scripts/workspace.sh status --root ~/code/other-workspace
```

`--root` defaults to the nearest ancestor holding a `repos.yaml`, so the verbs
work from inside any project in the workspace. `--dry-run` makes `clone` and
`gen-settings` print instead of act.

**No submodules and no pinning.** The manifest records which repos belong
together and which an agent may read, never which commit each sits at. A
workspace that must be restorable to an exact multi-repo state wants submodules
or a lockfile instead; this is for the case where the requirement is only that
every project is visible and operable at once.

**Why `gen-settings` writes absolute paths.** A relative
`additionalDirectories` entry resolves against a root that is not the settings
file's own directory, so `../sibling` silently names a path that does not
exist. The generated entries are absolute, and every other key in the file is
preserved.

Requires PyYAML (`pip3 install pyyaml`, or `apt install python3-yaml`). The
script fails with that message rather than misparsing.

## release MCP server

`.mcp.json` in this repo registers a stdio MCP server (`release`, sourced
from a private dotfiles repo's `dot_claude/mcp/release/`) exposing four
tools: `pr_land`, `release_publish`, `tag_major`, `checks`. It is a
dispatcher, not a second implementation — every tool call execs the script
above (or `gh pr checks`) that already owns the behaviour, so it holds no
release logic of its own.

The point is analytics granularity, not a new capability: a call through
this repo's own scripts stays inside one `Bash` bucket in tool-call
telemetry, while an MCP tool call arrives under its own name. No tool takes
a bypass flag, and none reaches an action its underlying script cannot.

Enabled here only, not globally — see the server's own README for the
registration snippet and how to run its selftest.

The server path is written `${HOME}/.claude/mcp/release/server.js`.
`.mcp.json` expands `${VAR}` and `${VAR:-default}` in `command`, `args`, `env`,
`url` and `headers`, so no absolute home directory belongs in it. An unset
variable is left unexpanded and warned about rather than failing the load, so a
checkout on a machine without the server simply has no `release` tool.

The [no-personal-paths](#no-personal-paths) action enforces the rule at the top
of this file, and this repo runs it on its own CI.

The [no-personal-paths](#no-personal-paths) action enforces the rule at the top
of this file, and this repo runs it on its own CI.

## Versioning

Consumers pin a major tag (`@v1`). `release-please` maintains `CHANGELOG.md`
and cuts the exact semver tag from Conventional Commits; a second job
repoints the major tag at each release, because release-please itself only
creates the exact version.

**The release PR is the human gate, and it is the only one.** Because a
consumer may have this repo's action as a *required* check, a moving major
tag is load-bearing for someone else's main branch — a broken tag reddens
their build immediately. Merging the release PR is therefore a deliberate
act, not a rubber stamp. Before merging one:

- this repo's CI is green, including the selftest
- the linter has been run against a heredoc-heavy repository and the output
  read by a person, not just observed to exit zero

That second check exists because every false positive seen so far came from
a file that writes Markdown or config from a heredoc, and the one false
negative lived in the same place.

## How this repo is worked

`main` is protected: pull request required, `selftest` and `self-lint` must
pass, force-push and deletion blocked. No approving review is required.

That is deliberate, not an oversight. An outside contributor cannot merge
here regardless — they have no write access — so a review requirement would
not be what gates them. What it would do is block Dependabot's auto-merge,
which waits on every merge requirement including reviews. If a collaborator
with write access is ever added, revisit it.

Dependabot watches the `github-actions` ecosystem weekly. Patch and minor
bumps auto-merge once the required checks pass; majors wait for a human.
There are no package dependencies to watch — `comment-lint.py` is stdlib
only.

`CHANGELOG.md` is generated. Do not edit it by hand.

`comment-lint.py` originated in
[night-watchman](https://github.com/moneymikeMD/night-watchman) and was seeded
here from `89e64b0`.

## License

MIT — see [LICENSE](LICENSE).
