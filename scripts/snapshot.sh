#!/usr/bin/env bash
# snapshot.sh — show what's about to be committed, without committing.
#
# Why: when an LLM session is interrupted or context is wiped, anything
# in the working tree that hasn't been committed is gone forever. Run
# this at the END of every AI-assisted editing session to see what
# would be lost. Then decide: commit it, stash it, or discard it.
#
# Usage:
#   ./scripts/snapshot.sh         # show staged + unstaged + untracked
#   ./scripts/snapshot.sh --add   # git add -A first, then show
#
# Safe by default: does NOT commit. Use --add only when you intend
# to stage everything (review the output before committing).

set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--add" ]; then
    echo "==> Staging all changes (--add)"
    git add -A
    echo ""
fi

echo "=== Branch ==="
git rev-parse --abbrev-ref HEAD
echo ""
echo "=== Staged for commit (git diff --cached --stat) ==="
STAGED=$(git diff --cached --stat)
if [ -z "$STAGED" ]; then
    echo "(nothing staged)"
else
    echo "$STAGED"
fi
echo ""
echo "=== Unstaged changes (git diff --stat) ==="
UNSTAGED=$(git diff --stat)
if [ -z "$UNSTAGED" ]; then
    echo "(working tree clean)"
else
    echo "$UNSTAGED"
    echo ""
    echo "WARNING: unstaged changes are NOT in git history."
    echo "Run './scripts/snapshot.sh --add' then 'git commit' to save them."
fi
echo ""
echo "=== Untracked files (git ls-files --others --exclude-standard) ==="
UNTRACKED=$(git ls-files --others --exclude-standard)
if [ -z "$UNTRACKED" ]; then
    echo "(nothing untracked)"
else
    echo "$UNTRACKED"
    echo ""
    echo "WARNING: untracked files will be LOST if the working tree is wiped."
    echo "Decide: commit them, add to .gitignore, or delete."
fi
echo ""
echo "=== Last 3 commits ==="
git log --oneline -3
