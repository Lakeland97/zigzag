# Firefox extensions as a first-class package kind — design

**Status:** binding for `feat/firefox-extensions`, which is stacked on PR A of the Chrome truth layer and is opened
only after the current five PRs merge. Written 2026-11-18.

## Why

Zigzag's extension framework speaks Chrome's dialect. Firefox extensions are WebExtensions too, but they arrive as
`.xpi`, use `browser.*` with Promises, declare their identity under `browser_specific_settings.gecko`, and put their
background in `background.scripts` even on Manifest V3. Today every one of those is invisible to Zigzag: the file
picker refuses `.xpi`, the store has no record of a Firefox identity, and a Firefox package that reached WebKit would
meet a callback-shaped `chrome` namespace it never calls.

The Chrome work made the framework tell the truth about what it provides. Firefox support extends the same framework,
not a parallel one: one package pipeline, one surface, one claims model, a second manifest dialect and a Promise facade
over the same APIs. A per-extension shim is a bug, not a strategy.

## Goals

- Install a Firefox extension from an `.xpi`, and import one already installed in a Firefox profile.
- Run it at the same level as a Chrome extension: background (MV2 page/scripts, MV3 scripts), content scripts,
  action/browser_action popup, options page, side panel from `sidebar_action`, storage, tabs, and the bridge namespaces
  Zigzag already answers.
- Give it `browser.*` with Promises, its Firefox ID, and honest host/platform answers.
- Describe Firefox-only limits through the same claim overlay and install sheet, with zero validator diagnostics.
- Keep Firefox and Chrome packages distinguishable in Settings, the sheet, and the store.

## Non-goals

- Verifying AMO signatures or checking AMO for updates. An XPI is accepted as bytes; whether it is signed is recorded
  and shown, never trusted as authority.
- Firefox Sync for `storage.sync`. Settings stay on this Mac, as the Chrome claim already says.
- Containers/contextual identities, themes, devtools pages, PKCS#11, DNS, telemetry, Normandy, experiments, legacy
  bootstrapped add-ons, and `browser_specific_settings.gecko.strict_min_version` enforcement.
- Translating Firefox-only APIs Zigzag cannot provide (`privacy.*` beyond the Chrome model, `browserSettings.*`),
  beyond claiming them unsupported with a line.
- A side-loading developer mode distinct from the existing unpacked flow.

## Decisions already made

**Package kind is recorded, not guessed at run time.** `ExtensionStore.Package` gains
`kind: String` (`"chromium"` default for every existing record; `"firefox"` for XPIs) and `firefoxID: String?`. The
package folder keeps Zigzag's opaque 32-character ID; `browser.runtime.id` answers the Firefox ID from the manifest.
An XPI with no gecko ID gets an ID derived from its bytes and is marked unsigned in the record; two XPIs with the same
gecko ID are the same extension and update in place.

**Normalize Firefox's manifest once, at extract time.** `FirefoxManifest.normalized(_:)` returns a manifest WebKit can
read: MV3 `background.scripts` becomes a generated classic worker that `importScripts` the listed files in order;
`sidebar_action` gains a `side_panel` twin; MV3 host patterns move from `permissions`/`optional_permissions` into
`host_permissions`/`optional_host_permissions`; a string `content_security_policy` becomes `{extension_pages: …}` for
MV3; MV2 string `web_accessible_resources` become MV3 objects. The original keys are left in place where WebKit
ignores them. The zip's files are never edited in the package the person chose: XPIs are extracted into Zigzag's
store, and normalization writes the manifest there.

**The Promise facade is self-gated, not per-package plumbing.** A new `firefox-polyfill.js` is appended to the shared
compatibility prelude, after Zigzag's surface and differences. The prelude is injected per profile, not per package, so
the script decides for itself: it builds `browser` only when `runtime.getManifest()` carries `browser_specific_settings`
or `applications`, the keys only a Firefox package has. It then wraps the finished `chrome` surface: a function returns a
Promise unless it is on the small synchronous list (`runtime.getManifest`, `runtime.getURL`, `runtime.id`,
`i18n.getMessage`, `i18n.getUILanguage`, `i18n.getAcceptLanguages`); event objects pass through; properties pass through.
Rejections use Firefox's error shape `{message}`. It is a stand-in, so the claims say `emulated`, not `native`. A Chrome
manifest with neither key is left exactly as it was, including WebKit's own `browser` if it supplies one.

**`runtime.getBrowserInfo` answers Zigzag, not Firefox.** `{name: "Zigzag", vendor: "Lakeland97", version: <app
version>, buildID: ""}` and `getPlatformInfo` `{os: "mac", arch: "aarch64"}` on Apple silicon, `"x86-64"` otherwise.
An extension that gates on `name === "Firefox"` will take its other path; the install sheet says the browser is not
Firefox. Lying here would make version checks meaningless.

**One claim model, two overlays.** `firefox-compatibility.json` has the same schema and validator as
`compatibility.json`; the universe it validates against is `firefox-api.json`. `ExtensionCompatibility` carries a
`kind` and loads the matching pair; `ExtensionReport.limits` and the sheet take the package kind. A single merged
overlay was rejected: the two API sets differ, and a Firefox-only member must not appear in Chrome's matrix or vice
versa.

**Firefox's API universe is generated from Mozilla's types, pinned.** `scripts/firefox-api.py` reads
`@types/firefox-webext-browser` at a pinned version (143.0.1), excludes `browser._manifest`, and writes
`firefox-api.json` with the same namespace/function/event/constant/enum/object shape the Chrome generator produces, so
`api-surface.js` can be pointed at either universe. The package does not annotate permissions; Firefox permission rows
are seeded by hand from Mozilla's documented permission list, and the generator is not asked to invent them.

**Import reads XPIs Firefox already downloaded.** `FirefoxImporter` scans
`~/Library/Application Support/Firefox/Profiles/*/extensions/*.xpi`, reads each manifest, and offers name, version,
gecko ID, and source profile. Installing copies the XPI through the same review sheet as a picked file. Firefox's
`extensions.json` is not parsed: an XPI's manifest is the authority, and an extension disabled there is still offered
(its XPI exists).

**The sheet's noise rule from PR A stays.** A `partial` permission row adds no line until per-call reporting returns;
only `unsupported`/`deprecated` rows do, plus raw names for permissions no claim covers. Firefox-only permission rows
follow the same rule.

## Left to the builder

- The exact wording of the Firefox-only catalog lines, following `docs/i18n/glossary.md` and the existing tone.
- Whether `sidebarAction` gets a runtime facade in this branch or is claimed `unsupported` until the side-panel bridge
  grows it. The design prefers the facade if the existing `sidePanel` bridge answers open/close/disable; otherwise a
  stated limit.
- The XPI fixture format for tests (a tiny zip built in Swift, or a checked-in base64 fixture) and the exact XPI
  security limits, which mirror `PackageZip`'s.
- The Settings row shape for a Firefox package (a "Firefox" line and gecko ID), following the existing extension row.
