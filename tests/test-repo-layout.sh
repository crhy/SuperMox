#!/usr/bin/env bash
# Fail if a tracked or new (untracked, not ignored) top-level entry is not one we expect.
# Catches stray copies of patched trees, downloads and unrelated folders before the queue's auto-commit adds them.
set -euo pipefail
cd "$(dirname "$0")/.."
allowed=' .gitignore AGENTS.md CHANGELOG.md README.md bin config cron docs init.d packaging patches scripts src tests website '
allowed+=' smhome.png theapp.png supermox_white_paper_1.pdf website '
bad=0
while IFS= read -r entry; do
  case "$entry" in "Design - SUPERMOX.pdf") continue ;; esac
  if [[ "$allowed" != *" $entry "* ]]; then
    echo "FAIL: unexpected top-level entry (tracked or new): $entry"
    bad=1
  fi
done < <({ git ls-files; git ls-files --others --exclude-standard; } | cut -d/ -f1 | sort -u)
[ "$bad" -eq 0 ] && echo "OK: repo top level only has expected entries"
exit "$bad"
