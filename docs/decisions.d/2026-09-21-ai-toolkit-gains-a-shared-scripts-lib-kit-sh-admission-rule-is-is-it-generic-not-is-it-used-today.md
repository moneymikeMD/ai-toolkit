---
date: 2026-09-21
slug: ai-toolkit-gains-a-shared-scripts-lib-kit-sh-admission-rule-is-is-it-generic-not-is-it-used-today
title: "ai-toolkit gains a shared scripts/lib/kit.sh; admission rule is 'is it generic', not 'is it used today'"
---

# ai-toolkit gains a shared scripts/lib/kit.sh; admission rule is 'is it generic', not 'is it used today'

## Decision

ai-toolkit brings scripts/lib/kit.sh (die, warn, need, show_help, known_command, tmpfile) rather than inlining helpers, ending its standalone-scripts property (2026-09-21). Admission is by genericity: herdr_notify stayed out as terminal-multiplexer-specific, warn came though unused.

## Why

Inlining duplicates five function bodies across two scripts and lets them drift, the failure ai-toolkit exists to end; standalone had been an artefact, not a stated constraint.

## Cost

scripts/*.sh does not glob scripts/lib/*.sh so shellcheck CI must name both; show_help is a second help convention beside usage() heredocs.
