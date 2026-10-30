# SuperMox website

A portable, responsive redesign using the teal Common Orbit identity and the message “One OS. All yours.”

## Open in VSCodium

Extract this ZIP, then choose **File → Open Folder** and select `supermox-website`.

Open `index.html` directly in a browser, use a live preview extension, or run:

```bash
npm run dev
```

The optional development server needs Node.js 20.11 or newer. It has no npm dependencies. You can instead use `python3 -m http.server 3000` and visit http://localhost:3000.

## Files to edit

- `index.html`: all page text, navigation, links, and section structure.
- `styles.css`: palette, typography, desktop and mobile layouts.
- `script.js`: mobile navigation and the interactive concept panel.
- `assets/supermox-symbol.svg`: editable vector interpretation of the selected Common Orbit concept; also used as the favicon.
- `documents/supermox-whitepaper.pdf`: original, unmodified project whitepaper.
- `dev-server.mjs`: optional local preview server. Not needed in production.

No framework, build step, external fonts, analytics, trackers, cookies, or third-party scripts. The website works without an internet connection except for external links. Without JavaScript, the page content, PDFs, and FAQ still work; the desktop navigation remains available.

## Cloudflare Pages deployment

From the repository root, stage the public assets:

```bash
bash scripts/build-website.sh
```

Deploy only `build/website/`. It contains the HTML, CSS, JavaScript, SVG, screenshots,
whitepaper, and Cloudflare security headers. Do not upload the repository root:
it contains private local credentials and unrelated operating system sources.
No framework or build command is needed on Cloudflare.

With Node.js and Wrangler installed, load the token privately and deploy:

```bash
export CLOUDFLARE_API_TOKEN="$(cat cloudflaretoken)"
export CLOUDFLARE_ACCOUNT_ID="fb0f7af515e774afd5df4203bc58563e"
npx wrangler pages deploy build/website --project-name supermox --branch main
unset CLOUDFLARE_API_TOKEN
```

The intended production domain is `supermox.me`. Associate the domain with the
Pages project before changing its website DNS records. Preserve unrelated DNS
records, including email records. The “Original website” link points to the
previous Weebly site so it remains useful after the switch.

The production deployment is live at https://supermox.pages.dev/ (Pages project
`supermox`, production branch `main`). Production assets are compared byte for
byte with the staged files after deployment. The owner reported changing the
GoDaddy nameservers on October 29, 2026. Cloudflare's assigned nameservers are
`ganz.ns.cloudflare.com` and `sunny.ns.cloudflare.com`. Both `supermox.me` and
`www.supermox.me` are associated with the Pages project, with proxied CNAME records
targeting `supermox.pages.dev`. The two former apex website A records were replaced;
the unrelated `_domainconnect` record was preserved. A pre-change DNS backup is
stored locally at `build/website-tooling/dns-before-pages.json`.

At the last check, public DNS still returned GoDaddy's nameservers and Cloudflare
reported the zone and custom domains as pending. Verify zone activation, Pages
custom-domain validation, and HTTPS before treating the domain migration as live.

`cloudflaretoken` and the source ZIP are excluded in this checkout's
`.git/info/exclude`. Keep credentials outside version control and never include
them in the deployment folder.

## Content provenance

Copy is adapted from the original home and design pages at https://supermox.me (redirecting to https://supermox.weebly.com), the original whitepaper in this package, and https://github.com/crhy/SuperMox/blob/master/README.md, reviewed October 29, 2026.

The page presents universal device support, cross-device resource pooling, proposed security mechanisms, and the resource marketplace as the project vision. It does not offer a finished universal installer. GitHub is the primary contribution link.

Spaced Linux desktop details and links were checked against https://spacedlinux.com/ on October 29, 2026. The desktop section describes its Devuan/sysvinit foundation, MATE and Compiz interface, local Voxa features, and live USB option.

## Verification

The original website package reports browser review at desktop width and in a
390px mobile frame, including navigation and concept controls. Local deployment
checks verified asset paths, anchor targets, JavaScript syntax, and the public
file list. Live production assets match the staged files. Universal device
compatibility and external project integrations are outside this website package.

The repository gate (`bash scripts/check.sh`) was attempted in this development
runtime but could not pass because required tools and runtime dependencies are
missing, including ShellCheck, rsync, dpkg, LSB init helpers, and the Python
mnemonic and PyNaCl packages.

## Screenshot sources

Images are hosted locally and displayed without altering the originals:

- `assets/screenshots/spaced-desktop.webp` (1600 × 900): Spaced Linux's Compiz workspace cube, from https://spacedlinux.com/assets/screenshots/desktop-compiz.webp.
- `assets/screenshots/android-lawnchair.jpg` (728 × 1536): user-provided `LawnChairScreenShot.jpg`, showing an Android home screen with the Lawnchair launcher. Published unchanged with permission implied by the request to use it. Labeled as an Android interface reference; it is not identified as a LineageOS or SuperMox build.
- `assets/screenshots/supermox-original-phone.png` (326 × 326): reference phone artwork from the original SuperMox homepage, https://supermox.weebly.com/uploads/7/4/4/8/74488167/published/phone.png?1572481059. Presented as archival artwork, not a current product screenshot.

Sources reviewed October 29, 2026. Captions link to the original projects.

The screenshot update was reviewed in Chromium at 1440px and 390px: all images
loaded, no horizontal overflow, and no JavaScript errors. The deployed public
files matched the staged files byte for byte after publishing.
