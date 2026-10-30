#!/usr/bin/env bash
# Repo health check, run at the start of every session (CLAUDE.md, "Shipping rule").
# Shows uncommitted work, local branches with commits not yet on origin/main, and
# branches tracking origin/main (a push from one of those would go to main).
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

if ! git fetch --prune origin 2>/dev/null; then
    echo "warning: git fetch failed; comparing against the last fetched origin/main"
fi

echo "== Current branch"
git branch --show-current

echo
echo "== Uncommitted changes (git status -s)"
changes=$(git status -s)
if [ -n "$changes" ]; then echo "$changes"; else echo "(none)"; fi

echo
echo "== Local branches"
printf '%-40s %-14s %s\n' "BRANCH" "NOT IN MAIN" "UPSTREAM"
git for-each-ref --format='%(refname:short)|%(upstream:short)' refs/heads |
while IFS='|' read -r branch upstream; do
    ahead=$(git rev-list --count "origin/main..$branch" 2>/dev/null || echo "?")
    note=""
    if [ "$upstream" = "origin/main" ] && [ "$branch" != "main" ]; then
        note="  <- tracks origin/main: a push would go to main"
    fi
    printf '%-40s %-14s %s%s\n' "$branch" "$ahead" "${upstream:-(none)}" "$note"
done
