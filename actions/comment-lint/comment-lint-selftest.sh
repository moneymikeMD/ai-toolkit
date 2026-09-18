#!/bin/bash
#
# Selftest for comment-lint.py. The assertions live in the linter
# itself (--selftest, fixture-driven); this wrapper exists so the repo's
# *selftest*.sh discovery loop and CI find it like every other suite.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/comment-lint.py" --selftest
