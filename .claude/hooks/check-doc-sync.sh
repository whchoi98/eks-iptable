#!/bin/bash
# Check if documentation is in sync with code changes
# Triggered on Write/Edit tool calls

CHANGED_FILE="$1"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Only check shell scripts and manifests
case "$CHANGED_FILE" in
  *.sh|*.yaml|*.yml)
    ;;
  *)
    exit 0
    ;;
esac

# Check if CLAUDE.md mentions the changed file's directory
DIR=$(dirname "$CHANGED_FILE" | sed "s|${PROJECT_ROOT}/||")
if [ "$DIR" != "." ] && ! grep -q "$DIR" "${PROJECT_ROOT}/CLAUDE.md" 2>/dev/null; then
  echo "NOTE: ${DIR}/ is not documented in CLAUDE.md"
fi
