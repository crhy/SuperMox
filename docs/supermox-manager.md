# SuperMox Manager

SuperMox Manager is a standalone GTK 3 desktop client for the SuperMox/PXVIRT
management API. It has its own native navigation, dashboard, inventory and
management actions. It can run on a separate workstation without installing a
SuperMox server. Python sources and the `Architecture: all` Debian package do
not assume a CPU architecture; GTK packages must be available for the target.

This is the first native implementation, not complete native feature parity.
The optional **Full management** window embeds the existing server interface
for workflows that have not yet been rebuilt. This remains a client of an
existing server: it does not replace pveproxy or the cluster services.

## Try it

On a desktop with `python3-gi`, `python3-cryptography` and `gir1.2-gtk-3.0`:

```sh
./bin/supermox-manager --demo
```

Preview mode is explicitly marked, uses synthetic resources and makes no
network requests. Actions are simulated. Launch without `--demo` to connect
to a real server:

```sh
./bin/supermox-manager --url https://node.example:8006/ --fingerprint SHA256_HEX
```

Supply the real certificate fingerprint, then enter credentials in the
connection dialog (for example, `root@pam`). Obtain the fingerprint through a
trusted channel from the node administrator. For a node's generated certificate:

```sh
openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -fingerprint -sha256
```

If pveproxy uses a custom certificate, inspect
`/etc/pve/local/pveproxy-ssl.pem` instead. Colons in fingerprints are accepted.
Local connections automatically use the installed node certificate when
available. The node picker uses root-owned, non-writable public membership
entries under `/etc/supermox`; it never reads private cluster keys.

## Current coverage

| Workflow | Implementation |
| --- | --- |
| Cluster overview, node/machine counts, memory | Native GTK, live API |
| VM/container search, sorting and selection | Native GTK |
| Node and storage inventory | Native GTK, read only |
| Guest configuration inspection | Native GTK, read only |
| Start, shutdown, stop, reboot, suspend, resume | Native GTK, confirmation for disruptive actions |
| Migration, named snapshots, backup submission | Native GTK forms; advanced options use Full management |
| Recent tasks, status and log inspection | Native GTK |
| Guest creation, clone, convert-to-template, delete | Native GTK forms; live API |
| Restore, hardware/network editing, storage content management | Existing server interface in Full management |
| Interactive consoles, cluster administration, permissions, HA, firewall and other advanced tools | Existing server interface in Full management |

All real operations require the connected user's server-side privileges.
Server versions and guest types may impose additional restrictions on actions.
Failures are displayed; the client does not claim successful completion merely
because an asynchronous task was submitted. Task details expose status and log.

Full management requires `gir1.2-webkit2-4.1` and a separate login. Its ephemeral
browser context supports same-origin console windows and explicit download
destinations. External identity-provider navigation is blocked, so external
SSO is not currently supported. Closing its window discards browser cookies.

## Session and TLS handling

The native API client checks the exact SHA256 leaf certificate fingerprint on
each connection **before sending credentials or requests**. Redirects are not
followed. Login tickets and CSRF tokens stay in memory; password/OTP fields are
discarded after login. Sign out clears the native session and closes Full
management windows. Window preferences are saved under the user's XDG config
directory using an allowlist that excludes credentials and connection secrets.

The compatibility browser checks the fingerprint before opening, then uses
WebKit's certificate validation and a host-specific exception for the checked
certificate. This is not the native client's per-request pin guarantee:
WebKit may also accept certificates trusted by its system CA store.

## Build and validation

With `dpkg-deb` and `rsvg-convert` installed:

```sh
bash scripts/build-manager.sh
```

The package is written under `build/`. Install the resulting `.deb` through the
system package manager to get the application menu entry and icons. WebKit is
a recommended dependency; native screens work without it. This package has no
dependency on the server package or an init system.

```sh
bash scripts/check.sh
xvfb-run -a python3 tests/gui-manager.py
```

API tests use a local HTTPS fixture to check certificate rejection before
credentials, login/CSRF, expired sessions, TFA challenges, redirects, resource
queries and error handling. The GUI smoke check exercises native preview
navigation and machine selection and writes `build/supermox-manager-preview.png`.
Live cluster operations and WebKit console workflows still require integration
testing against a running node; they have not been validated by those fixtures.

The client is AGPLv3. The complete license is in
`src/supermox_manager/COPYING` and is included in the package. SuperMox's
upstream lineage is PXVIRT/Proxmox VE; upstream trademarks are not used as the
application's branding.
