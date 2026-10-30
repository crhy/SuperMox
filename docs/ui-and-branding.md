# SuperMox look and web interface

Status: design (2026-10-29).

## Branding source

The project website (`website/`, published at supermox.me) is the single source of SuperMox's look:

- Symbol: `website/assets/supermox-symbol.svg`.
- Colours: background `#092b32`, deep `#07252c`, ink `#12373b`, text `#eef5ef`, muted `#a4bcb9`, accent teal `#35d8b0`,
  lines `#ffffff20`.
- Tagline: "One OS. All yours."

Everything else (web UI, ISO boot screens, installer slides, Waydroid/Lawnchair defaults) takes its icons and colours from
there. `scripts/branding-assets.sh` exports the PNG sizes that tools need (favicon 16/32/48, logo 128/256/512, GRUB
background 1920x1080) from the SVG with `rsvg-convert`, so nobody keeps second copies by hand.

"Proxmox" is a trademark, so SuperMox's own pages and titles never use the name or logo. Where the code comes from Proxmox
VE, the about dialog and the docs say "based on Proxmox VE (AGPL-3.0)", and every upstream copyright notice stays.

## Phase 1: dark SuperMox theme as the default (small, low risk)

- PVE already loads themes as `/pwt/themes/theme-<name>.css` (`www/index.html.tpl` in pve-manager; theme files ship in
  proxmox-widget-toolkit). We add `theme-supermox-dark.css`, built on the stock `theme-proxmox-dark.css` and recoloured
  with the palette above. It is shipped by a small `supermox-ui` package into the widget toolkit's theme directory.
- A pve-manager patch adds `supermox-dark` to the theme list and makes it the default when there is no theme cookie.
  People can still pick light, dark or auto.
- Rebranding patches: the page title, the login window title, the top-left logo (`www/images/`), the favicon, and the
  product name strings in `manager6`. These are exact string and file replacements. The behaviour stays the same.

## Phase 2: a simpler home screen ("SuperMox Home")

The full PVE interface stays available as "Advanced". In front of it sits a simple page built with the website's style,
using the same PVE API (`/api2/json`, ticket and CSRF login):

- **Devices:** every cluster node (core and edge), its tier (KVM/LXC/TCG, from supermox-node-caps), and its live CPU, RAM
  and disk as bars.
- **Apps and machines:** guests as cards, with start, stop, open console, and "move to the fastest free device" (which
  calls migrate).
- **Your files:** the shared home folder's state from docs/shared-home.md: in sync, devices holding copies, conflicts.
- **Add a device:** shows the QR invite (supermox-join invite) and approves pending joins.

Served by pveproxy as static files under `/supermox/`; the login redirects there. No new daemon. The top bar has a link to
"Advanced (full interface)".

## SuperMox Manager (the local desktop app)

SuperMox Manager now has native GTK screens for the dashboard, machine actions,
node/storage inventories and tasks. It runs on a separate desktop without the
server package. Optional WebKit embeds the full existing interface for advanced
workflows that have not yet been rebuilt natively.

See [the desktop client guide](supermox-manager.md) for preview, packaging,
feature coverage, connection security and integration-test limitations.

## Build order

1. `branding-assets.sh`, the `supermox-ui` package with `theme-supermox-dark.css`, and the pve-manager theme-default and
   rebranding patches.
2. SuperMox Manager native desktop screens, with the full interface available for advanced workflows.
3. SuperMox Home: the read-only dashboard first (devices, guests, files), then actions, then add a device.
