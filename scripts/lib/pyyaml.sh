#!/bin/bash
#
# pyyaml.sh — choose the interpreter for scripts' embedded Python, once per run.
# Generic: it names no host, vault or multiplexer.
#
# Usage: source this file, then
#
#     resolve_yaml_python || die "$YAML_PY_ERROR"
#     "${YAML_PY[@]}" - "$arg" <<'PY' ... PY
#
# Routes, in order; the first that can `import yaml` wins:
#   1. $AI_TOOLKIT_PYTHON, when set. Set but empty, or set and unable to import
#      yaml, is an error: an explicit choice never falls through.
#   2. uv on PATH: `uv run --no-project --with 'pyyaml>=6,<7' python`, probed
#      once. A failed probe (offline, cold cache) falls through.
#   3. python3, then python3.N newest first, whichever is first on PATH and can
#      import yaml. This is the route CI takes.
#   4. None: YAML_PY_ERROR names every route tried and why it failed.
#
# shellcheck disable=SC2034  # YAML_PY and YAML_PY_ERROR are read by the sourcing script
#
# YAML_PY_SPEC is the PyYAML requirement handed to uv; a range, no lockfile.

YAML_PY_SPEC="pyyaml>=6,<7"
YAML_PY=()
YAML_PY_ERROR=""

_yaml_py_probe() { "$@" -c 'import yaml' >/dev/null 2>&1; }

resolve_yaml_python() {
    local why="" cand name seen=" " names tried=""
    YAML_PY=()
    YAML_PY_ERROR=""

    if [ -n "${AI_TOOLKIT_PYTHON+set}" ]; then
        if [ -z "$AI_TOOLKIT_PYTHON" ]; then
            YAML_PY_ERROR="AI_TOOLKIT_PYTHON is set but empty; unset it or name an interpreter"
            return 1
        fi
        if _yaml_py_probe "$AI_TOOLKIT_PYTHON"; then
            YAML_PY=("$AI_TOOLKIT_PYTHON")
            return 0
        fi
        YAML_PY_ERROR="AI_TOOLKIT_PYTHON=$AI_TOOLKIT_PYTHON cannot import yaml (or is not runnable)"
        return 1
    fi
    why="AI_TOOLKIT_PYTHON: not set"

    if command -v uv >/dev/null 2>&1; then
        if _yaml_py_probe uv run --no-project --quiet --with "$YAML_PY_SPEC" python; then
            YAML_PY=(uv run --no-project --quiet --with "$YAML_PY_SPEC" python)
            return 0
        fi
        why="$why; uv: 'uv run --with $YAML_PY_SPEC' failed the import probe (offline or cold cache?)"
    else
        why="$why; uv: not on PATH"
    fi

    names=$(compgen -c python3 2>/dev/null | grep -E '^python3(\.[0-9]+)?$' | sort -u -V -r)
    for name in python3 $names; do
        case "$seen" in *" $name "*) continue ;; esac
        seen="$seen$name "
        while IFS= read -r cand; do
            [ -n "$cand" ] || continue
            if _yaml_py_probe "$cand"; then
                YAML_PY=("$cand")
                return 0
            fi
            why="$why; $cand: cannot import yaml"
            tried=1
        done < <(type -aP "$name" 2>/dev/null)
    done
    [ -n "$tried" ] || why="$why; no python3 on PATH"

    YAML_PY_ERROR="PyYAML is required and no route supplied it. Tried: $why. Fix one: set AI_TOOLKIT_PYTHON, install uv, or pip3 install pyyaml (apt: python3-yaml)"
    return 1
}
