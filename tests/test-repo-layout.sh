#!/usr/bin/env bash
# Fail if a tracked top-level entry is not one we expect (catches stray copies of patched trees or downloads).
set -euo pipefail
cd "$(dirname "$0")/.."
allowed=' .gitignore AGENTS.md README.md config cron docs init.d packaging patches scripts src tests '
allowed+=' smhome.png theapp.png supermox_white_paper_1.pdf '
bad=0
while IFS= read -r entry; do
  case "$entry" in "Design - SUPERMOX.pdf") continue ;; esac
  if [[ "$allowed" != *" $entry "* ]]; then
    echo "FAIL: unexpected tracked top-level entry: $entry"
    bad=1
  fi
done < <(git ls-files | cut -d/ -f1 | sort -u)
[ "$bad" -eq 0 ] && echo "OK: repo top level only has expected entries"
exit "$bad"
