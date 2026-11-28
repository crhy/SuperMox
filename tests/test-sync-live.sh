#!/usr/bin/env bash
# f15b: the home sync layer against a real Syncthing, not a fake API.
#
# Two instances of the installed syncthing, two members that are not real
# users (alice and bob), every path under build/.  This is the only test that
# can catch us having invented an endpoint: the fake API in tests/py agrees
# with whatever the code asks for, and Syncthing 1.29.x has no /api/v1 at
# all.  Skips (exit 0) when syncthing is absent or not 1.29.x.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/build/f15b"
homes="$work/homes"
join="$work/join"
alice_port=8391
bob_port=8392
# The port each instance listens on for its peer.  One host cannot bind
# 22000 twice, so the test gives each instance its own loopback endpoint
# and the membership entry names that endpoint instead of an overlay address.
alice_listen=22010
bob_listen=22011

ok() { echo "ok: $1"; }

die() {
  echo "FAIL: $1"
  exit 1
}

skip_unless_syncthing() {
  command -v syncthing >/dev/null 2>&1 || {
    echo "SKIP: test-sync-live: no syncthing"
    exit 0
  }
  local ver
  ver="$(syncthing --version 2>/dev/null | head -1)"
  case "$ver" in
    *"1.29."*) ;;
    *)
      echo "SKIP: test-sync-live: needs Syncthing 1.29.x, found: $ver"
      exit 0
      ;;
  esac
}

# --- instance plumbing ----------------------------------------------------

api_key() {
  local f="$work/st/$1/config.xml"
  [ -f "$f" ] || return 0
  grep -o '<apikey>[^<]*' "$f" | head -1 | cut -d'>' -f2
}

api_url() {
  # The address the instance chose, read back from its own config.xml:
  # this is the same thing supermox-sync does, so a wrong guess here
  # would be the same wrong guess the CLI makes.
  local f="$work/st/$1/config.xml" addr
  addr="$(grep -o '<address>127\.[^<]*' "$f" | head -1 | cut -d'>' -f2)"
  printf 'http://%s' "$addr"
}

# api <node> <path-under-rest> [json-body]
api() {
  local node="$1" path="$2" data="${3:-}"
  local url key
  url="$(api_url "$node")"
  key="$(api_key "$node")"
  if [ -n "$data" ]; then
    curl -s -H "X-API-Key: $key" -X PUT -H 'Content-Type: application/json' \
      -d "$data" "$url/rest/$path"
  else
    curl -s -H "X-API-Key: $key" "$url/rest/$path"
  fi
}

code_get() {
  # code_get <node> <path-under-rest> [auth]
  # With the key the path is answered on its merits; without it Syncthing
  # refuses before routing, which is how we know the API is authenticated.
  local node="$1" path="$2" key=""
  if [ "${3:-}" = "auth" ]; then
    key="$(api_key "$node")"
  fi
  local url
  url="$(api_url "$node")/rest/$path"
  if [ -n "$key" ]; then
    curl -s -o /dev/null -w '%{http_code}' -H "X-API-Key: $key" "$url"
  else
    curl -s -o /dev/null -w '%{http_code}' "$url"
  fi
}

json_field() {
  python3 -c 'import json,sys
print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
}

# The ids, parsed rather than grepped: a formatting change in Syncthing's
# JSON must not be what makes this test pass or fail.
device_ids() {
  api "$1" config/devices |
    python3 -c 'import json,sys
print(" ".join(sorted(d["deviceID"] for d in json.load(sys.stdin))))'
}

folder_ids() {
  api "$1" config/folders |
    python3 -c 'import json,sys
print(" ".join(sorted(f["id"] for f in json.load(sys.stdin))))'
}

# What the instance actually holds, for a failure message that says why
# a comparison came out unequal rather than just that it did.
device_dump() {
  api "$1" config/devices |
    python3 -c 'import json,sys
for d in json.load(sys.stdin):
    print("  %s name=%r addresses=%r" %
          (d["deviceID"], d.get("name"), d.get("addresses")))'
}

# The same comparison reconcile makes, printed side by side: what the
# membership list asks for, and what the instance reports back.
explain_drift() {
  local node="$1"
  PYTHONPATH="$root/src" python3 - "$join" "$work/st/$node" "$node" <<'PY'
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.environ["SUPERMOX_SRC"])
sys.path.insert(0, os.environ["SUPERMOX_SRC"])
from supermox import sync as sync_mod

join, home, node = sys.argv[1:4]
with open(join + "/membership.json") as fh:
    members = json.load(fh)["list"]
with open(home + "/config.xml", encoding="utf-8") as fh:
    conf = fh.read()
key = conf.split("<apikey>")[1].split("<")[0]
addr = conf.split("<address>")[1].split("<")[0]

def get(path):
    req = urllib.request.Request("http://%s/rest/%s" % (addr, path))
    req.add_header("X-API-Key", key)
    return json.load(urllib.request.urlopen(req))

have = get("config/devices")
myid = get("system/status")["myID"]
want = sync_mod.desired_devices(members, node)
print("  myID=%s" % myid)
for d in want:
    print("  want  %s name=%r addresses=%r" %
          (d["deviceID"], d["name"], d["addresses"]))
for d in have:
    if d["deviceID"] != myid:
        print("  have  %s name=%r addresses=%r" %
              (d["deviceID"], d.get("name"), d.get("addresses")))
PY
}

prepare_config() {
  # Pin the freshly generated config while Syncthing is stopped, which is
  # how Syncthing says to do it: a running instance keeps the listeners it
  # already bound, so addresses set through the API afterwards would not
  # take effect until a restart.  Two changes, both about isolation:
  # listen on one loopback endpoint rather than every interface, and
  # announce nowhere (no global announce, no LAN, no relay, no NAT), so
  # the peer's device entry is the only thing that can connect the two
  # instances -- which is the mechanism the cluster depends on.
  python3 - "$1" "$2" "$3" <<'PY'
import re
import sys

path, endpoint, gui_port = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
text = text.replace(
    "<listenAddress>default</listenAddress>",
    "<listenAddress>tcp://%s</listenAddress>\n"
    "        <listenAddress>quic://%s</listenAddress>"
    % (endpoint, endpoint))
for tag in ("globalAnnounceEnabled", "localAnnounceEnabled",
            "relaysEnabled", "natEnabled"):
    text = re.sub(r"<%s>true</%s>" % (tag, tag),
                  "<%s>false</%s>" % (tag, tag), text)
text = re.sub(r"(<gui[^>]*>\s*<address>)[^<]*(</address>)",
              lambda m: "%s127.0.0.1:%s%s" % (m.group(1), gui_port, m.group(2)),
              text, count=1)
if "quic://%s" % endpoint not in text or "127.0.0.1:%s" % gui_port not in text:
    sys.exit("FAIL: Syncthing's config template no longer has the lines "
             "this test edits")
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)
PY
}

start_instance() {
  local node="$1" port="$2" endpoint="$3"
  syncthing generate --home "$work/st/$node" --no-default-folder \
    >"$work/$node.generate.log" 2>&1
  prepare_config "$work/st/$node/config.xml" "$endpoint" "$port"
  syncthing serve --home "$work/st/$node" \
    --no-browser --no-restart \
    >"$work/$node.log" 2>&1 &
  echo "$!" >"$work/$node.pid"
}

wait_ping() {
  local node="$1" i=0
  while [ "$i" -lt 60 ]; do
    if [ -n "$(api_key "$node")" ] && [ -n "$(api "$node" system/ping)" ]; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.5
  done
  echo "FAIL: $node never answered /rest/system/ping"
  tail -20 "$work/$node.log"
  exit 1
}

my_id() {
  api "$1" system/status | json_field myID
}

scan() {
  # Force a rescan: the default interval is an hour, and a test that
  # waits for it is a test that times out.
  local node="$1" folder="$2"
  curl -s -o /dev/null -H "X-API-Key: $(api_key "$node")" \
    -X POST "$(api_url "$node")/rest/db/scan?folder=$folder"
}

wait_for() {
  local path="$1" limit="${2:-40}" i=0
  while [ "$i" -lt "$limit" ]; do
    [ -e "$path" ] && return 0
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}

# supermox-sync <subcommand> as one node.  No --url: the CLI must find
# the address and the key in config.xml by itself.
sm_sync() {
  local node="$1"
  shift
  SUPERMOX_ETC="$join" SUPERMOX_SYNC_HOME_ROOT="$homes/$node" \
    PYTHONPATH="$root/src" python3 "$root/bin/supermox-sync" \
    --home "$work/st/$node" --node "$node" --state-dir "$join" "$@"
}

# --- safety net -----------------------------------------------------------

# Every folder path either instance is about to manage must live under build/.
# If it does not, stop that instance before it can touch anything real.
assert_paths_under_build() {
  local node="$1" bad
  # Two views of the same thing: the API list is what the running instance
  # acts on, and config.xml is what survives a restart.  A folder pointing
  # outside build/ would sync a real user's home, so both must be clean.
  bad="$(api "$node" config/folders |
    python3 -c '
import json, sys
for folder in json.load(sys.stdin):
    if not folder["path"].startswith(sys.argv[1]):
        print("api: %s" % folder["path"])
' "$root/build/")"
  bad="$bad$(python3 - "$work/st/$node/config.xml" "$root/build/" <<'PY'
import sys
import xml.etree.ElementTree as ET

# Syncthing's config template ships one <folder> with an empty id and path
# "~"; it is inert (absent from the API list) and reconcile cannot remove
# it, so only folders with a real id are checked.
for folder in ET.parse(sys.argv[1]).findall("folder"):
    if folder.get("id") and not folder.get("path", "").startswith(sys.argv[2]):
        print("config: %s=%s" % (folder.get("id"), folder.get("path")))
PY
)"
  if [ -n "$bad" ]; then
    echo "FAIL: $node manages paths outside build/:"
    printf '%s\n' "$bad"
    if [ -f "$work/$node.pid" ]; then
      kill "$(cat "$work/$node.pid")" 2>/dev/null || true
    fi
    return 1
  fi
}

cleanup() {
  local node pid
  for node in alice bob; do
    if [ -f "$work/st/$node/config.xml" ]; then
      api "$node" system/shutdown >/dev/null 2>&1 || true
    fi
    if [ -f "$work/$node.pid" ]; then
      pid="$(cat "$work/$node.pid")"
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT

# --- the test -------------------------------------------------------------

skip_unless_syncthing

rm -rf "$work"
mkdir -p "$work/st/alice" "$work/st/bob" \
  "$homes/alice/alice" "$homes/bob/bob" "$join"

# A busy port would make one instance answer on another address, and
# every assertion below would then read the wrong instance.
for p in "$alice_port" "$bob_port"; do
  if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$p/"; then
    echo "SKIP: test-sync-live: port $p is in use"
    exit 0
  fi
done

start_instance alice "$alice_port" "[::1]:$alice_listen"
start_instance bob "$bob_port" "[::1]:$bob_listen"
wait_ping alice
wait_ping bob
ok "two instances answering /rest/system/ping"

# The old assumption, stated so its absence is visible: with the key
# supplied, /api/v1 is a 404, and an unauthenticated request is refused.
if [ "$(code_get alice 'api/v1/version' auth)" != "404" ]; then
  echo "FAIL: expected /rest/api/v1/version to 404"
  exit 1
fi
if [ "$(code_get alice 'system/ping')" = "200" ]; then
  echo "FAIL: an unauthenticated ping was accepted"
  exit 1
fi
ok "no /api/v1, and the API key is required"

alice_id="$(my_id alice)"
bob_id="$(my_id bob)"
[ -n "$alice_id" ] && [ -n "$bob_id" ] ||
  die "could not read myID from both instances"

# A real signed membership list, not a hand-written one: reconcile records
# each node's own device id, and recording means re-signing the list.
PYTHONPATH="$root/src" python3 - "$join" <<'PY'
import base64
import sys

from supermox import state

st = state.NodeState(sys.argv[1])
st.create_cluster("abandon " * 11 + "about", "alice", ["127.0.0.1:8743"],
                  "amd64", ["kvm"])
st.add_member({
    "name": "bob",
    "wg_pub": base64.b64encode(b"\x22" * 32).decode("ascii"),
    "ed_pub": base64.b64encode(b"\x33" * 32).decode("ascii"),
    "overlay_addr": "fd00:1234:5678:9abc:def0:1122:3344:5566",
    "endpoints": ["127.0.0.1:8743"],
    "arch": "amd64",
    "caps": ["kvm"],
    "role": "core",
})
PY

PYTHONPATH="$root/src" python3 - "$join" "$alice_id" "$bob_id" \
  "tcp://[::1]:$alice_listen" "tcp://[::1]:$bob_listen" <<'PY'
import sys

from supermox import state

st = state.NodeState(sys.argv[1])
st.load()
st.set_syncthing_id("alice", sys.argv[2])
st.set_syncthing_id("bob", sys.argv[3])

# The overlay address a real member would have is replaced by the endpoint
# that member's Syncthing actually listens on: no WireGuard network exists
# in a test, and sync.py passes an address that already has a scheme through
# to the device entry unchanged.
for name, endpoint in (("alice", sys.argv[4]), ("bob", sys.argv[5])):
    for member in st.membership:
        if member["name"] == name:
            member["overlay_addr"] = endpoint
st.save()
PY
ok "signed membership list naming both device ids"

sm_sync alice reconcile >"$work/reconcile-alice.out" ||
  die "reconcile failed for alice (see $work/reconcile-alice.out)"
sm_sync bob reconcile >"$work/reconcile-bob.out" ||
  die "reconcile failed for bob (see $work/reconcile-bob.out)"
assert_paths_under_build alice || die "alice escaped build/"
assert_paths_under_build bob || die "bob escaped build/"
ok "reconcile ran on both nodes, all paths under build/"

# Each instance must hold exactly the two device ids: the peer's, plus the
# local one Syncthing adds itself.  A duplicate local entry would share
# every folder with the instance that owns it.
# Sorted the same way device_ids() sorts: the instance decides the order.
want_devices="$(printf '%s\n%s\n' "$alice_id" "$bob_id" | sort | paste -sd' ')"
for node in alice bob; do
  got="$(device_ids "$node")"
  [ "$got" = "$want_devices" ] ||
    die "$node devices are [$got], expected [$want_devices]"
done
ok "each instance shares with the peer, once, and not with itself"

want_folders="home-alice home-bob"
for node in alice bob; do
  got="$(folder_ids "$node")"
  [ "$got" = "$want_folders" ] ||
    die "$node folders are [$got], expected [$want_folders]"
done
ok "home-alice and home-bob on both instances"

# The ignore list is a file inside the shared folder, so it travels:
# reconcile writes it once, Syncthing carries it to the other node.
[ -f "$homes/alice/alice/.stignore" ] ||
  die "reconcile did not write .stignore into alice's home"
scan alice home-alice
scan bob home-alice
wait_for "$homes/bob/alice/.stignore" ||
  die ".stignore never reached bob's copy of alice's home"
ok "the ignore list arrived as a synced file"

# A normal file syncs, and wait says so instead of the caller sleeping.
printf 'hello from alice\n' >"$homes/alice/alice/hello.txt"
scan alice home-alice
scan bob home-alice
sm_sync bob wait --folder home-alice --timeout 30 >/dev/null ||
  die "wait never reported home-alice up-to-date"
wait_for "$homes/bob/alice/hello.txt" ||
  die "hello.txt never arrived at bob"
cmp "$homes/alice/alice/hello.txt" "$homes/bob/alice/hello.txt" ||
  die "hello.txt arrived changed"
ok "alice's file arrived at bob, and wait confirmed it"

# The list is in force on the running instance, not merely written down.
# The window is bounded: if it were synced, it would be synced by now.
mkdir -p "$homes/alice/alice/.cache"
printf 'junk\n' >"$homes/alice/alice/.cache/junk.txt"
scan alice home-alice
scan bob home-alice
if wait_for "$homes/bob/alice/.cache/junk.txt" 8; then
  die ".cache was synced despite .stignore"
fi
ok "the ignore list is in force on the receiving instance"

# A conflict copy is a file name to us.  Who made it is Syncthing's business;
# our job is to find it where it landed and never to pick a winner.
conflict='notes.sync-conflict-20260101-000000-ABCDEF1.txt'
printf 'two versions\n' >"$homes/alice/alice/$conflict"
scan alice home-alice
scan bob home-alice
wait_for "$homes/bob/alice/$conflict" ||
  die "the conflict copy never arrived at bob"
status_out="$(sm_sync bob status)"
case "$status_out" in
  *"$conflict"*) ;;
  *)
    printf '%s\n' "$status_out"
    die "status did not report the conflict copy"
    ;;
esac
ok "status reports the conflict copy, and never resolves it"

# Idempotence: the second reconcile must write nothing at all.
second="$(sm_sync alice reconcile)"
[ -z "$second" ] || {
  echo "FAIL: second reconcile wrote something:"
  printf '%s\n' "$second"
  echo "alice's instance holds these devices:"
  device_dump alice
  echo "what reconcile wanted to write, and why:"
  explain_drift alice
  exit 1
}
ok "reconcile is idempotent"

sm_sync alice verify >/dev/null ||
  die "verify rejected a freshly reconciled instance"
ok "verify agrees with reconcile"

# The device id each instance learned is now in the signed list, so the
# other node can find it without a human adding a host in the Syncthing GUI.
PYTHONPATH="$root/src" python3 - "$join" "$alice_id" "$bob_id" <<'PY'
import json
import sys

with open(sys.argv[1] + "/membership.json") as fh:
    signed = json.load(fh)
ids = {m["name"]: m.get("syncthing_id") for m in signed["list"]}
if ids != {"alice": sys.argv[2], "bob": sys.argv[3]}:
    raise SystemExit("membership list holds %r" % (ids,))
PY
ok "both device ids recorded in the signed membership list"

assert_paths_under_build alice || die "alice escaped build/"
assert_paths_under_build bob || die "bob escaped build/"

# shutdown is the service's business at boot, but the endpoint must work.
sm_sync bob shutdown >/dev/null
i=0
while [ "$i" -lt 20 ]; do
  [ -z "$(api bob system/ping)" ] && break
  i=$((i + 1))
  sleep 0.5
done
[ -z "$(api bob system/ping)" ] || die "shutdown left bob's instance running"
ok "shutdown stopped the instance"

echo "PASS: test-sync-live"
