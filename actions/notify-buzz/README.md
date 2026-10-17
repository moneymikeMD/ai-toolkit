# notify-buzz

Posts a message into a Buzz channel through a Buzz webhook workflow
(`POST <relay>/hooks/<workflow-id>` with an `x-webhook-secret` header).

The step never fails the caller's job. If Buzz is unreachable or answers
non-2xx it emits `::warning::` with the HTTP status and continues. A wrong or
missing secret answers HTTP 404, which shows up as that warning. Missing
`url`, `secret` or `title` is a setup error and does fail the step.

## Inputs

| Input | Required | Default | Becomes |
| --- | --- | --- | --- |
| `url` | yes | | the full hook URL (from a secret) |
| `secret` | yes | | `x-webhook-secret` header (from a secret) |
| `status` | no | `firing` | `{{trigger.status}}` |
| `title` | yes | | `{{trigger.title}}` |
| `message` | no | empty | `{{trigger.message}}` |
| `link` | no | this run's URL | `{{trigger.externalURL}}` |

The body is a flat JSON object built with `jq`. `url` and `secret` are masked
and never echoed.

## Post on failure

```yaml
steps:
  - uses: actions/checkout@v7
  - run: ./build.sh
  - if: failure()
    uses: moneymikeMD/ai-toolkit/actions/notify-buzz@v1
    with:
      url: ${{ secrets.BUZZ_HOOK_URL }}
      secret: ${{ secrets.BUZZ_HOOK_SECRET }}
      title: ${{ github.repository }} build failed
      message: ${{ github.workflow }} on ${{ github.ref_name }}
```

## Selftest

`./actions/notify-buzz/notify-buzz-selftest.sh` runs the script against a
local stub server; no network.
