#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

work="build/t21-build-order"
rm -rf "$work"
mkdir -p "$work"

components=()
while IFS= read -r c; do
  components+=("$c")
done < <(bash scripts/fetch-upstream.sh --list)

# Parse one debian/control file. Emits tab-separated records:
#   B<TAB>dep   build dependency
#   R<TAB>dep   runtime dependency (from a binary package's Depends)
#   P<TAB>name<TAB>comp  binary package produced by comp
# Continuation lines are joined; version constraints (), arch [] and
# build-profile <> parts are stripped; "a | b" keeps both; ${...} vars dropped.
# credit=1: binary packages from this control file are produced by comp.
# credit=0: still parse build/runtime deps, but do NOT credit produced packages
# (used for subdirs of a multi-subdir component that config/build-subdirs.txt does not build).
parse_control() {
  local f="$1" comp="$2" credit="$3"
  awk -v comp="$comp" -v credit="$credit" '
    function emit_list(kind, value,   n, i, part, m, j, a, parts, alts) {
      n = split(value, parts, ",")
      for (i = 1; i <= n; i++) {
        part = parts[i]
        gsub(/\([^)]*\)/, "", part)
        gsub(/\[[^]]*\]/, "", part)
        gsub(/<[^>]*>/, "", part)
        m = split(part, alts, "|")
        for (j = 1; j <= m; j++) {
          a = alts[j]
          gsub(/^[ \t]+/, "", a)
          gsub(/[ \t]+$/, "", a)
          if (a == "") continue
          if (a ~ /\$/) continue
          print kind "\t" a
        }
      }
    }
    function flush(   ) {
      if (field == "Build-Depends" || field == "Build-Depends-Indep" || field == "Build-Depends-Arch")
        emit_list("B", val)
      else if (field == "Depends")
        emit_list("R", val)
      else if (field == "Package")
        if (credit == 1) print "P\t" val "\t" comp
      field = ""; val = ""
    }
    /^[A-Za-z][-A-Za-z0-9]*:/ {
      flush()
      ci = index($0, ":")
      field = substr($0, 1, ci - 1)
      val = substr($0, ci + 1)
      gsub(/^[ \t]+/, "", val)
      next
    }
    /^[ \t]/ {
      if (field != "") { t = $0; gsub(/^[ \t]+/, "", t); val = val " " t }
      next
    }
    { flush() }
    END { flush() }
  ' "$f"
}

# Subdirs of a component that config/build-subdirs.txt builds (empty => the
# whole component is built). Same parsing as scripts/vm-build-pkg.sh.
read_subdirs() {
  local comp="$1"
  local file="$repo_root/config/build-subdirs.txt"
  local line rest
  local -a words
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    if [ "${line%% *}" = "$comp" ]; then
      rest="${line#* }"
      [ "$rest" = "$line" ] && continue
      read -ra words <<< "$rest"
      for _w in "${words[@]}"; do
        printf '%s\n' "$_w"
      done
    fi
  done < "$file"
}

: > "$work/produced.tsv"
for c in "${components[@]}"; do
  base="upstream/pxvirt/packages/$c/$c"
  : > "$work/raw.$c"
  sub=()
  while IFS= read -r _s; do
    [ -n "$_s" ] && sub+=("$_s")
  done < <(read_subdirs "$c")
  while IFS= read -r f; do
    credit=1
    if [ "${#sub[@]}" -gt 0 ]; then
      credit=0
      rel="${f#"$base"/}"
      for _s in "${sub[@]}"; do
        case "$rel" in "$_s"/*) credit=1; break ;; esac
      done
    fi
    parse_control "$f" "$c" "$credit" >> "$work/raw.$c"
  done < <(find "$base" -name .git -prune -o -type f -path '*/debian/control' -print)
  awk -F'\t' '$1=="B"{print $2}' "$work/raw.$c" | LC_ALL=C sort -u > "$work/$c.build"
  awk -F'\t' '$1=="R"{print $2}' "$work/raw.$c" | LC_ALL=C sort -u > "$work/$c.runtime"
  awk -F'\t' '$1=="P"{print $2"\t"$3}' "$work/raw.$c" >> "$work/produced.tsv"
done
LC_ALL=C sort -u -o "$work/produced.tsv" "$work/produced.tsv"

# Union of every build and runtime dependency name.
: > "$work/all-deps.txt"
for c in "${components[@]}"; do
  cat "$work/$c.build" "$work/$c.runtime"
done | LC_ALL=C sort -u > "$work/all-deps.txt"

# Ask the VM once which names have an install candidate. For an offline
# regeneration (no VM), set SUPERMOX_POLICY_CACHE to a saved apt-cache policy
# capture and it is used instead of querying the VM.
mapfile -t alldeps < "$work/all-deps.txt"
names="${alldeps[*]}"
if [ -n "${SUPERMOX_POLICY_CACHE:-}" ] && [ -f "${SUPERMOX_POLICY_CACHE:-}" ]; then
  cp "${SUPERMOX_POLICY_CACHE}" "$work/policy.out"
else
  bash scripts/vm-ssh.sh "apt-cache policy $names" 2>/dev/null > "$work/policy.out"
fi

# Parse apt-cache policy: a package is present iff it has a Candidate that is not (none).
awk '
  /^[^ \t].*:$/ { name = $0; sub(/:$/, "", name); cur = name }
  /^[ \t]+Candidate:/ {
    c = $0
    sub(/^[ \t]*Candidate:[ \t]*/, "", c)
    if (cur != "") cand[cur] = c
  }
  END { for (k in cand) print k "\t" cand[k] }
' "$work/policy.out" | LC_ALL=C sort > "$work/present.tsv"

# Combined tagged input for the doc generator.
{
  awk -F'\t' '{print "pres\t" $0}' "$work/present.tsv"
  awk -F'\t' '{print "prod\t" $0}' "$work/produced.tsv"
  for c in "${components[@]}"; do
    awk -v c="$c" '{print "dep\t" c "\tbuild\t" $0}' "$work/$c.build"
    awk -v c="$c" '{print "dep\t" c "\truntime\t" $0}' "$work/$c.runtime"
  done
} > "$work/combined.tsv"

# Generate docs/build-deps.md.
awk -F'\t' '
  function missing(name) { return !( (name in pres) && pres[name] != "(none)" ) }
  $1=="pres" { pres[$2] = $3; next }
  $1=="prod" { prod[$2] = $3; next }
  $1=="dep" {
    comp = $2; kind = $3; name = $4
    if (!(comp in comps)) { comps[comp] = 1; ncomp++ }
    if (kind == "build") {
      bmiss[comp, name] = 1
      if ((name in prod) && prod[name] != comp) {
        e = prod[name] SUBSEP comp
        if (!(e in seen)) { seen[e] = 1; adj[prod[name]] = adj[prod[name]] " " comp; indeg[comp]++ }
      }
    } else {
      rmiss[comp, name] = 1
    }
    if (missing(name) && !(name in prod)) {
      if (name == "systemd" || name == "systemd-sysv") sysd[name] = 1
      else ext[name] = 1
    }
    next
  }
  END {
    # deterministic Kahn topological order over the components
    split("", order)
    for (c in comps) order[c] = 1
    # sorted component list
    m = 0
    for (c in comps) { m++; srt[m] = c }
    for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++)
      if (srt[j] < srt[i]) { t = srt[i]; srt[i] = srt[j]; srt[j] = t }
    # Kahn
    done = 0; pass = 0
    for (c in comps) indeg0[c] = indeg[c] + 0
    while (done < m) {
      progress = 0
      for (i = 1; i <= m; i++) {
        c = srt[i]
        if (order[c] == 1 && indeg0[c] == 0) {
          seq[++k] = c; order[c] = 0; indeg0[c] = -1; progress = 1; done++
          na = split(adj[c], nb, " ")
          for (x = 1; x <= na; x++) if (nb[x] != "") indeg0[nb[x]]--
        }
      }
      pass++
      if (!progress) break
    }
    # cycles: components still marked order==1
    cyc = ""
    for (i = 1; i <= m; i++) if (order[srt[i]] == 1) cyc = cyc " " srt[i]

    print "# Build dependencies on Devuan Ceres"
    print ""
    print "Generated by `scripts/build-deps-report.sh`. Deterministic (LC_ALL=C sort)."
    print "A dependency is MISSING if `apt-cache policy` on the Ceres VM reports no"
    print "install candidate (`(none)` or package not found)."
    print ""
    print "## Build order (our " m " components)"
    print ""
    print "Each component is listed after every component whose binary packages it"
    print "build-depends on."
    print ""
    for (i = 1; i <= k; i++) print (i) ". " seq[i]
    if (cyc == "") {
      print ""
      print "No dependency cycles among our components."
    } else {
      print ""
      print "CYCLE(S) involving:" substr(cyc, 2)
    }
    print ""
    print "## External missing packages (full sorted list)"
    print ""
    print "Missing on Ceres and NOT produced by any of our " m " components; each needs an"
    print "external source (e.g. Proxmox Rust crates `librust-*`, `libpve-rs-perl`,"
    print "`libproxmox-rs-perl`, `proxmox-*`)."
    print ""
    ne = 0
    for (name in ext) { ne++; earr[ne] = name }
    for (i = 1; i <= ne; i++) for (j = i + 1; j <= ne; j++)
      if (earr[j] < earr[i]) { t = earr[i]; earr[i] = earr[j]; earr[j] = t }
    if (ne == 0) print "(none)"
    for (i = 1; i <= ne; i++) print "- " earr[i]
    if ("systemd" in sysd || "systemd-sysv" in sysd) {
      print ""
      print "## Deliberately replaced (NOT missing; we ship sysvinit-core + our init.d scripts + the librust-proxmox-systemd-dev stub):"
      if ("systemd" in sysd) print "- systemd"
      if ("systemd-sysv" in sysd) print "- systemd-sysv"
    }
    print ""
    print "## Per component"
    print ""
    for (i = 1; i <= m; i++) {
      comp = srt[i]
      print "### " comp
      print ""
      print "| Dependency | Kind | Source |"
      print "| --- | --- | --- |"
      cnt = 0
      for (name in bmiss) {
        split(name, key, SUBSEP)
        if (key[1] != comp) continue
        if (!missing(key[2])) continue
        cnt++; rows[cnt] = key[2] "\tbuild"
      }
      for (name in rmiss) {
        split(name, key, SUBSEP)
        if (key[1] != comp) continue
        if (!missing(key[2])) continue
        cnt++; rows[cnt] = key[2] "\truntime"
      }
      for (a = 1; a <= cnt; a++) for (b = a + 1; b <= cnt; b++)
        if (rows[b] < rows[a]) { t = rows[a]; rows[a] = rows[b]; rows[b] = t }
      if (cnt == 0) { print ""; print "All build and runtime dependencies are available on Ceres."; print ""; continue }
      for (a = 1; a <= cnt; a++) {
        split(rows[a], r, "\t")
        dep = r[1]; kind = r[2]
        if (dep in prod) src = "produced by " prod[dep]
        else src = "external: needs a source"
        print "| " dep " | " kind " | " src " |"
      }
      print ""
    }
  }
' "$work/combined.tsv" > docs/build-deps.md

echo "Wrote docs/build-deps.md ($(wc -l < docs/build-deps.md) lines)"
