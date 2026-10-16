---
date: 2026-09-20
slug: code-is-three-manifest-workspaces-driven-by-repos-yaml-not-git-submodules
title: "~/code is three manifest workspaces driven by repos.yaml, not git submodules"
---

# ~/code is three manifest workspaces driven by repos.yaml, not git submodules

## Decision

The ~/code projects live in three thin private workspaces (home_workspace, home_exp_workspace, home_thirdparty_workspace), each tracking only coordination files with an allowlist .gitignore and a repos.yaml manifest driven by ai-toolkit/scripts/workspace.sh (2026-09-20).

## Why

The workspace needs every project visible and operable at once, not restorable to an exact multi-repo state; pinning costs a detached HEAD plus a pointer-bump commit per child change in any tool, so a pinning tool buys nothing.

## Cost

unrecorded in memory 4241f438
