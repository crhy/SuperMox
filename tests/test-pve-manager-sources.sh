#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -d upstream/pxvirt/packages/pve-manager ]; then
  echo "SKIP"
  exit 0
fi

fail=0
out=build/pve-manager-sources-apply
src=upstream/pxvirt/packages/pve-manager/pve-manager

rm -rf "$out"
if ! bash scripts/apply-patches.sh "$out" >/dev/null; then
  echo "FAIL: apply-patches.sh failed"
  exit 1
fi

# The Makefile installs configs/pve-sources.sources to
# /etc/apt/sources.list.d/pve-enterprise.sources, so the patched source file is
# exactly what every installed SuperMox node gets.
shipped="$out/pve-manager/pve-manager/configs/pve-sources.sources"
if [ ! -f "$shipped" ]; then
  echo "FAIL: patched tree has no configs/pve-sources.sources"
  exit 1
fi
if ! grep -qF -- 'install -D -m 0644 pve-sources.sources $(DESTDIR)/etc/apt/sources.list.d/pve-enterprise.sources' \
  "$out/pve-manager/pve-manager/configs/Makefile"; then
  echo "FAIL: configs/Makefile no longer installs pve-sources.sources as pve-enterprise.sources"
  fail=1
fi

# 1. The shipped stanza must be disabled: an enabled paid repository makes every
#    apt update on a subscription-less node fail with 401 Unauthorized.
if ! grep -qx 'Enabled: no' "$shipped"; then
  echo "FAIL: shipped pve-enterprise.sources has no 'Enabled: no' line"
  cat "$shipped"
  fail=1
fi
if grep -qiE '^Enabled:[[:space:]]*(yes|true)[[:space:]]*$' "$shipped"; then
  echo "FAIL: shipped pve-enterprise.sources carries an enabling Enabled: line"
  cat "$shipped"
  fail=1
fi
if [ "$(grep -c '^Enabled:' "$shipped")" != 1 ]; then
  echo "FAIL: Enabled: must appear exactly once in the shipped file"
  cat "$shipped"
  fail=1
fi

# 2. The file is kept, not deleted: a subscribed admin must still be able to
#    switch it on, so the URI, suite and keyring stay intact.
for needle in 'URIs: https://enterprise.proxmox.com/debian/pve' \
              'Suites: trixie' \
              'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg'; do
  if ! grep -qF -- "$needle" "$shipped"; then
    echo "FAIL: shipped pve-enterprise.sources lost: $needle"
    cat "$shipped"
    fail=1
  fi
done

# 3. A comment above the stanza must explain why it is disabled, otherwise an
#    admin "fixing" a broken apt update will re-enable a repository that 401s.
if ! grep -q '^#.*subscription' "$shipped"; then
  echo "FAIL: no comment mentioning a Proxmox subscription above the stanza"
  cat "$shipped"
  fail=1
fi
# the comment must sit above the stanza, not after it
first_field="$(grep -nE '^(Enabled|Types):' "$shipped" | head -1 | cut -d: -f1 || true)"
comment_line="$(grep -n '^#' "$shipped" | head -1 | cut -d: -f1 || true)"
if [ -z "$comment_line" ] || [ -z "$first_field" ] || [ "$comment_line" -ge "$first_field" ]; then
  echo "FAIL: the explanation is not above the stanza"
  cat "$shipped"
  fail=1
fi

# 4. Negative control: the fix comes from our patch, not from upstream.
if grep -q '^Enabled:' "$src/configs/pve-sources.sources"; then
  echo "FAIL: upstream pve-sources.sources already carries Enabled: - test no longer proves the patch"
  fail=1
fi

# 5. Version suffix: our changelog entry must be the top one, so apply-patches.sh
#    does not stack a second +supermox1 entry on top of it (that would make the
#    built deb 9.2.24+supermox2+supermox1, which dpkg orders below the deb we
#    already shipped).
cl="$out/pve-manager/pve-manager/debian/changelog"
ver="$(dpkg-parsechangelog -l "$cl" -S Version)"
if [ "$ver" != "9.2.24+supermox2" ]; then
  echo "FAIL: patched pve-manager version is $ver, expected 9.2.24+supermox2"
  fail=1
fi
if printf '%s\n' "$ver" | grep -qE '\+supermox[0-9]+\+supermox'; then
  echo "FAIL: patched pve-manager version carries a double +supermox suffix: $ver"
  fail=1
fi

rm -rf "$out"

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: pve-manager ships the enterprise repository disabled (Enabled: no)"
