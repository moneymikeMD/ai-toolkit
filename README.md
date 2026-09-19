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
```

The decision, in order: every required context present and successful is a
plain squash merge; any required context present and failed, cancelled or
timed out is a refusal, naming which one; required contexts absent **and**
the PR authored by a bot is a squash merge with `--admin`; anything else —
pending, or partially absent on a human PR — is a refusal.

**`--admin` is derived, never a parameter.** A bot-authored PR (for example,
a release-please PR running on `GITHUB_TOKEN`) triggers a workflow run that
GitHub never actually executes: zero jobs, zero check-runs, and the required
contexts are permanently *absent* rather than failed. `--admin` is the only
way past that, and the script reasons its way there instead of a caller
asking for it — a caller cannot use this script to bypass a check that
actually failed.

**The PR's state is always read back after a merge attempt**, and the exit
code depends on that read, not on the merge command's own exit status. A
classifier denial is not proof a merge did not happen — an already-merged PR
has returned a denial after the fact — so the read-back is unconditional.

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
