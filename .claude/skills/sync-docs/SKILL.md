---
name: sync-docs
description: Synchronize CLAUDE.md and docs/ with current project state
---

1. Scan all `.sh` scripts and extract current execution flow
2. Update CLAUDE.md "실행 순서" section if scripts changed
3. Update CLAUDE.md "Key Commands" with any new commands discovered
4. Update `docs/architecture.md` if manifests or cluster configs changed
5. Report any undocumented files or directories
