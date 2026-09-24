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
- uses: actions/checkout@v7
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
- uses: actions/checkout@v7
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

## skill-routing

Nothing tests that a user prompt reaches the right agent skill. Routing
failures are silent: the wrong `SKILL.md` loads, or none does, and nothing goes
red. This ranks every discovered skill **description** against a fixture of
realistic prompts with a stemmed TF-IDF cosine, and reports any pair of
descriptions similar enough to compete for the same prompt.

Deterministic and zero-token — python3 stdlib, no model call — so it can run on
every push. It does not replace `claude plugin eval`, which asserts real routing
against a live model with a `tool_used` grader and costs tokens per case. Use
both: this one as the gate, that one as the sample.

**The rule that comes with it: a routing failure means fix the description,
never the prompt.** The prompt is the user, and the user does not get patched.

Three things fail a build. A **description collision** at or above
`similarity-error` (0.75 by default; 0.50 warns). A **positive** prompt whose
own skill does not land inside `top-k`. A **negative** prompt whose named
skill is not outranked by the skill that actually owns it. Below the top-k
gate, the rank-1 rate over all positives is compared to `rank1-floor`.

A skill id is `LABEL/NAME`, where `NAME` comes from the frontmatter and `LABEL`
defaults to the basename of the root it was found under. Pass `LABEL=DIR` to
pin ids across checkout layouts, which matters once one run spans several
repos.

### As a step

```yaml
- uses: moneymikeMD/ai-toolkit/actions/skill-routing@v1
  with:
    roots: nw=skills
    fixtures: evals/routing/prompts.json
    allow: evals/routing/allowed-collisions.json
    rank1-floor: "1.0"
    top-k: "1"
    report-only: "true"
```

### As a whole job

```yaml
skill-routing:
  uses: moneymikeMD/ai-toolkit/.github/workflows/skill-routing.yml@v1
  with:
    roots: nw=skills
    fixtures: evals/routing/prompts.json
```

### Locally

```bash
python3 actions/skill-routing/skill-routing.py --list           # what it found
python3 actions/skill-routing/skill-routing.py a=one/skills b=two/skills
./actions/skill-routing/skill-routing-selftest.sh               # 18 + 14 assertions
```

### The split, and what the consuming repo owns

The ranker and the thresholds are generic and live here. The prompt fixtures,
the rank-1 floor and the accepted-collision list are judgement calls about one
repo's skills, so they live in that repo — the same split comment-lint uses.

Fixtures are JSON:

```json
{
  "positives": [{"prompt": "...", "skill": "nw/session-start"}],
  "negatives": [{"prompt": "...", "skill": "nw/grill", "owner": "nw/to-issues"}]
}
```

Accepted collisions are JSON too, and every pair in the file is a pair someone
decided not to fix:

```json
{"collisions": [["homelab/session-start", "night-watchman/session-start"]]}
```

### Adopting it in a repo that already collides

Start with `report-only: "true"`. A workspace whose skills grew in parallel
will light up on day one, and a check that reddens every branch before anyone
can fix it gets disabled rather than obeyed. Fix descriptions, move pairs out
of the allow file, then turn the gate on. `report-only` masks **violations**
only. A renamed fixture file, a JSON syntax error or a moved `skills/` dir
still reddens the build, because a report-only job that also swallows those is
permanently green whether or not the check ever ran.

Three traps. A prompt sharing **no** stemmed term with any description scores
zero everywhere; that is reported as a miss, not silently resolved by
tie-break. A skill with no `description` frontmatter can never be routed at
all, so it fails outright rather than sitting at rank 0. And two `SKILL.md`
declaring the same `name` under one label is the worst collision there is —
only the first is reachable — so it is reported by id and path rather than
deduplicated away.

## bar-check

Fails a diff that lowers a quality bar instead of meeting it. An agent that
cannot make a check pass can silence it instead, and the diff still merges
green — most easily in an unattended wave, where the same agent writes both the
code and the test that proves it.

Five categories, all language-generic, all read off the diff:

| Category | What it catches |
| --- | --- |
| `suppression` | an added `@ts-ignore`, `eslint-disable`, `# noqa`, `# type: ignore`, `// nolint`, `#[allow(…)]`, `@SuppressWarnings`, `# nosec`, `NOSONAR` and kin |
| `test-deleted` | a test file deleted or moved out of a test path, or more test declarations removed than added |
| `test-skipped` | an added `it.only`, `.skip`, `xit`, `@pytest.mark.skip`, `t.Skip`, `#[ignore]`, `@Disabled` |
| `assertion-removed` | a surviving test file that ends the diff with fewer assertions than it started with |
| `threshold-lowered` | a numeric threshold in a config file edited downward, coverage floors in particular |

It reads the diff, not the tree, so a violation already in the repository is
not the new branch's problem. Renaming a test is net zero; removing a
suppression is never reported.

### As a step

```yaml
- uses: actions/checkout@v7
  with:
    fetch-depth: 0
- uses: moneymikeMD/ai-toolkit/actions/bar-check@v1
  with:
    report-only: "true"
```

`fetch-depth: 0` is required — the check needs the merge base. With no `base:`
it uses the pull request's base sha, then the push's before sha. If neither
resolves it never passes on an empty diff: under `report-only` it emits a
`::warning::` and exits 0, and as a gate it errors and fails the job. An event
with no base at all — `workflow_dispatch`, `schedule`, `merge_group`, a
branch's first push — is therefore safe to add the job to in report-only mode.

### As a whole job

```yaml
jobs:
  bar-check:
    uses: moneymikeMD/ai-toolkit/.github/workflows/bar-check.yml@v1
    with:
      report-only: "true"
```

### Locally

```bash
python3 actions/bar-check/bar-check.py --base origin/main
python3 actions/bar-check/bar-check.py --diff - < some.patch
./actions/bar-check/bar-check-selftest.sh    # 35 fixture + 18 real-git assertions
```

### Declaring an exception

A legitimate suppression or a deliberately skipped test goes in
`.bar-check-allow`, one rule per line, `<category> <path-glob> [<substring>]`:

```
# Upstream types are wrong here; tracked as TICKET-1.
suppression src/legacy/*.ts @ts-ignore

# Quarantined until the flake is understood.
test-skipped tests/test_network.py

# The whole vendored tree, every category.
* third_party/vendor
```

`*` in the category column matches any category — prefer naming the categories
you mean, or the rule stops the check seeing that path's tests deleted too.

In the path column `*` and `?` stop at `/`, so `src/legacy/*.ts` names the
files in one directory and not the subtree under it; write `src/legacy/**/*.ts`
for the subtree, or just `src/legacy` — a directory named with no wildcard
covers everything beneath it.

A `#` opens a comment only as a line's first non-space character. Four of the
patterns you would put in the substring column start with `#`, so write the
reason on its own line above the entry, never trailing the rule.

The allow-file is never scanned as source, so quoting a pattern in order to
exempt it does not report it. Same reasoning as `no-personal-paths`: an
exception you have to write down is an exception a reviewer sees in the diff
that needs it, and it beats a cleverer regex that tries to guess intent.

### Adoption

`report-only` defaults to `"true"`, and every repo starts there. Run it over a
few waves, read what it names, add the exceptions that are real, and switch the
gate on per repo afterwards, the same graduated path `comment-lint` uses.

Two known limits, both deliberate. Only *downward* threshold edits are
reported: a ceiling that gets raised (`max-warnings 0` → `10`) is the same move
in the other direction, and detecting it needs the key to be known as a ceiling
rather than a floor. And an assertion count is a count, so swapping a real
assertion for a weaker one at the same line count is invisible.

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
status checks against the actual check-runs on the PR's head SHA, never from
memory.

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
the owner's standing grant clears. A bot-authored PR (for example, a
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

Runs a ticket's `verify` frontmatter block with its safety rules built in.

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

**A base whose required contexts cannot be read is not a refusal.** A private
repo on GitHub Free answers 403 for the call a plan that could show rules
would answer with an empty list, so there is nothing to wait for. Both this
script and `pr-land.sh` read that fact through `lib/ghkit.sh`, which returns
three outcomes rather than two: read, not-visible, failed. A rules read that
failed for any *other* reason still refuses, because that is not evidence
of an absence.

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

## land-core

Merges a finished branch onto a target branch and pushes it, through a
dedicated integration worktree. It is the generic half of a "land a ticket"
script: it knows nothing about tickets, trackers, dispatch or multiplexers.
A consuming repo supplies those through one hook script.

```bash
scripts/land-core.sh --repo /path/to/repo --branch feature
scripts/land-core.sh --repo /path/to/repo --branch feature --label TKT-1
scripts/land-core.sh --repo /path/to/repo --branch feature --hook ./lifecycle.sh
scripts/land-core.sh --repo /path/to/repo --branch feature --dry-run
```

`pr-land.sh` merges a **pull request** through the GitHub API behind its
required checks. This merges a **local branch** with git, in a worktree the
caller never stands in. They are not alternatives to each other; a repo that
lands through PRs wants `pr-land.sh`.

**`--repo` is mandatory and has no cwd fallback.** Every script here is
invoked by absolute path from outside the repo it acts on, and this one
merges, pushes and deletes a branch. A cwd default would silently pick
whichever repository the caller happened to be standing in. Empty, missing or
non-git is an error, never a fallback.

### The four-point hook contract

`--hook PATH` names one executable, called as `PATH <point>` with cwd set to
the integration worktree. The four points are where a lifecycle has to
interleave with git, and each one's failure semantics are already different:

| Point | State when it runs | Non-zero means |
| --- | --- | --- |
| `pre-merge` | synced to `origin/<target>`, nothing merged | reset to `origin/<target>`, undoing any commit the hook made; exit 2 |
| `post-merge` | the merge commit exists, lint has not run | revert the merge; exit 1 |
| `pre-push` | lint passed, nothing pushed | revert the merge; exit 1 |
| `post-push` | the push succeeded (or there was no remote) | recorded; cleanup still runs; exit 1 at the end. The landing stands and is never reverted |

A hook commits at `pre-merge` and `pre-push`, and those commits are inside
the pushed history — that is what makes a file-backed tracker's completion
commit land with the work rather than after it.

Context arrives as **environment variables, not positional arguments**, so
adding one later cannot shift an existing hook's `$2`: `LAND_CORE_POINT`,
`LAND_CORE_REPO` (the main worktree), `LAND_CORE_WORKTREE` (the integration
worktree), `LAND_CORE_BRANCH`, `LAND_CORE_TARGET`, `LAND_CORE_LABEL`,
`LAND_CORE_MERGE_SHA` (empty before the merge) and `LAND_CORE_PUSHED`. Exit 0
from a point the hook does not handle.

**Preflight belongs in the caller, not in a hook.** There is no fifth point
before the lock: a wrapper validates whatever it needs to — a ticket's stage,
a tracker's status — and only then calls this. That keeps a refusal from
creating an integration worktree first.

### What it does with the worktree

Merge, lint and push run in `<parent-of-the-main-worktree>/<repo>-land`,
never in `--repo` itself. Every run resets it to `origin/<target>`; a dirty
one is refused unless `--reset-land` is passed; a concurrent run is refused
by the lock at `<worktree>.lock`, which is never waited on and whose holder
is reclaimed if its pid is not running. The main worktree is **not**
fast-forwarded afterwards, because a sibling may hold uncommitted edits
there; the summary prints the `git pull --ff-only` to run by hand.

Reverting the merge is `git reset --hard ORIG_HEAD`, so a commit a
`pre-merge` hook made survives it, unpushed. The next run's reset to
`origin/<target>` discards it.

**`--dry-run` calls no hook** and runs no mutating command, including
creating the integration worktree. A consumer prints its own plan around
this one rather than expecting hooks to print theirs mid-run.

**`--lint-cmd` runs through `bash -c`**, so `a && b` is evaluated rather than
passed to `a` as two literal arguments; under word splitting `true && false`
*passes*, so a red lint lands. The default, when no command is given, is
`./scripts/lint.sh` in the merged tree if it is executable, else a warning
and no gate.

## release-publish

Publishes a release-please release end to end: checks the open PR against
the level you asked for, merges it through `pr-land.sh`, waits for the
resulting release and CI, then repoints the floating major tag through
`tag-major.sh`.

```bash
scripts/release-publish.sh minor
scripts/release-publish.sh patch --repo owner/repo
scripts/release-publish.sh major --i-am-the-owner
scripts/release-publish.sh minor --dry-run
```

It reads `.release-please-manifest.json` from the named repository's
default branch through the GitHub contents API, so it runs from any
directory and the cwd is never an input. A component PR (head
`release-please--branches--<base>--components--<name>`) is compared against
the manifest key `release-please-config.json` maps that component to, waits
for the `<name><separator>v<version>` release, and moves no floating major
tag, which belongs to the root package.

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
intended commit, because a push's exit code does not prove the tag moved.

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

**Only `repos:` is a member.** A manifest may also carry an `adjacent_repos:`
key, for repos whose landing policy `protections.sh` records but which are not
subdirectories of the workspace. Every verb here ignores that key: those
entries are never listed, cloned, pulled, iterated by `foreach`, or added to
`additionalDirectories`, whatever they set `agent` to.

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

## protections

Records how a landing actually works in every repo a `repos.yaml` names, by
reading the live GitHub API, and gates on drift from what is recorded.

```bash
scripts/protections.sh                    # fetch, then write the generated block
scripts/protections.sh --store            # ...and the workspace-state store
scripts/protections.sh --check            # compare recorded against live; non-zero on drift
scripts/protections.sh --dry-run          # print the diff a write would make
scripts/protections.sh --emit-json facts.json
scripts/protections.sh --emit-json - | workspace-state protections set --file -
scripts/protections.sh --root ~/code/other-workspace
```

Four generated keys go into each repo's entry, under a comment naming this
script, and nothing hand-written is touched:

| key | values |
| --- | --- |
| `landing` | `direct`, `checks`, `review`, `unavailable` |
| `required_checks` | a list of contexts, `none`, or `unavailable` |
| `code_owner` | a handle, `none`, or `unavailable` |
| `protections_fetched_at` | UTC, when the three above were measured |

**Two top-level keys are read.** `repos:` holds the workspace's own members,
one per subdirectory. `adjacent_repos:` holds repos whose landing policy
matters but which are not subdirectories of the workspace at all — the
container repo the manifest itself lives in, a dotfiles checkout elsewhere on
disk. Both are measured identically: the same generated keys, the same rows
through `--store`, and the same `--check` drift gate, because a value written
once and never compared is recorded rather than gated. The key is optional, a
name appearing under both is an error rather than a merge, and `workspace.sh`
reads only `repos:`. The emitted JSON carries `adjacent` per repo so a consumer
can tell the two apart.

`visibility` is fetched too, but the manifest already carries a hand-written
`visibility` key, so it is checked rather than duplicated: a write run corrects
it in place and says so, and `--check` reports a difference like any other
drift.

**`unavailable` is not a synonym for "no protections".** A private repo on
GitHub Free cannot have rulesets at all, and the API answers `403 Upgrade to
GitHub Pro` rather than an empty list. The two mean different things to a
future reader, and one of them is a plan-upgrade decision, so all three
generated values carry `unavailable` — `none` in any of them would read as
measured-and-empty. Any other API failure is an error, never `unavailable`.

**A ruleset counts only when it can actually fire.** It must be `active`, it
must target a branch, and its `conditions.ref_name` must match the default
branch. A ruleset aimed at a branch name that does not exist protects nothing
and has already shipped in this ecosystem once, so the match is evaluated
rather than assumed.

`--check` is the point of the script, not a nicety: it is what stops the
generated block becoming the next stale artifact, and it is the same shape as
`known-issue.sh lint`. Run it from CI or a cron.

Requires `gh`, authenticated, and PyYAML.

**The state store.** `--store` writes the same facts to the `workspace-state`
store as well as to `repos.yaml`, through that CLI. It is off by default,
because this script has to keep working on a machine that cannot reach the
store; and it is a write, so it refuses `--check` and `--dry-run`.

The CLI is resolved from `$WORKSPACE_STATE_BIN`, then `PATH`, and resolved
*before* any fetching, so a missing CLI costs nothing rather than being
discovered after twenty API calls. There is deliberately no fallback to a
dotfiles install path — this repo is public and does not get to know where
your binaries live.

**Exit 4 is passed straight through.** `workspace-state` uses 4 for "the
backend is unreachable or unconfigured", and it is never an empty result, so
a caller can tell a store that said nothing from no store at all. `repos.yaml`
is written before the store is touched, so a 4 means the manifest half
succeeded. That distinction is the whole point of the epic, and folding it
into a generic failure would throw it away.

`--emit-json -` writes the payload to stdout, which moves the per-repo table
to stderr so it cannot corrupt it. That is what makes the pipeline form work.

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

That second check exists because heredoc-heavy files are where the linter's
false positives and false negatives live.

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
There is no package manifest to watch: the actions are python3 stdlib only,
and `workspace.sh` and `protections.sh` need PyYAML at run time.

`CHANGELOG.md` is generated. Do not edit it by hand.

## License

MIT — see [LICENSE](LICENSE).
