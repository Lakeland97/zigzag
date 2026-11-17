# Chrome extension compatibility — design

2026-11-17

## Intent

Zigzag already loads Chrome extensions through WebKit's `WKWebExtension`, and many work. The ones that don't fail in
the long tail: an API that silently does nothing, an event that never fires, a popup at the wrong size, a service
worker that has gone to sleep, a permission that looks granted but isn't. This is a program to close that tail at the
framework level, so that most if not all Chrome extensions work — before any Firefox work begins.

The unit is the framework, not an extension. Individual extensions are evidence and tests, not the shape of the work.
Where a Chrome feature depends on a Google service, the answer may be a bridge to Google's own endpoints or a local
equivalent, but never a pretence that Zigzag is Chrome.

This is the first of two long-horizon tasks. Firefox extension support (#277) starts only when this one is finished and
merged; the design for that will be its own document, and it will reuse the registry and harness built here.

## The bar

"Most if not all extensions work" means, observably:

- An extension installs or updates from the Chrome Web Store, and the install sheet says truthfully what will and
  will not work — no installed-but-dead extension.
- The framework APIs an ordinary extension uses behave as Chrome documents: callback and Promise forms, events,
  errors, and lifecycle.
- Extension UI lands where Chrome puts it and at the size Chrome gives it: action popup, options page, side panel,
  omnibox, notifications and context menus.
- An extension that asks for a feature Zigzag cannot provide fails loudly and in a Chrome-shaped way; it never gets an
  `undefined` that looks like success.
- A curated corpus of real extensions passes its smoke flows, and Zigzag's own security model (site access, private
  windows, native messaging consent) is not weakened to get there.

"Near enough" is about observability, not internals: the same callbacks fire and the same pixels land in the same
place, even where Zigzag's implementation is a bridge or an emulation.

## Non-goals and anti-goals

- Not embedding Chromium, and not forking WebKit. Zigzag keeps its own engine and its own security model.
- Not pixel-identical Chrome chrome around the extension; extension content fidelity is the target.
- Not Chrome-account sync of settings, Chrome Web Store payments, enterprise policy, or private Google APIs without
  official access.
- Not per-extension special cases as a strategy. The existing shims for 1Password, Bitwarden, Motrix and Tampermonkey
  are grandfathered evidence, not the pattern; each gets a reason and a retirement path.
- Not Firefox work before the Chrome bar is met and merged.

Anti-goals, each a failure even if extensions "work":

- Silent stubs: a namespace that exists but does nothing.
- Auto-granting a permission or host access to avoid a prompt.
- Faking a Google identity, token or service.
- Breaking site access, private-window isolation or extension consent to make a test pass.
- Measuring success by one popular extension while the framework stays uneven.

## What exists now

The extension layer has four parts. `ExtensionBridge` is a permission-checked native dispatcher; `bridge.js` installs
the JS namespaces WebKit does not provide; `webkit-differences.js` corrects members WebKit supplies; and
`api-surface.js` fills what is still missing from `chrome-api.json`, the full Chrome API description generated from
`chrome-types` by `scripts/chrome-api.py` and injected by `ExtensionBridgeScript.surface` (`__SURFACE__`). WebKit
supplies manifest parsing, content scripts, and many namespaces (`tabs`, `windows`, `storage`, `alarms`, `cookies`,
`webNavigation`, `declarativeNetRequest`, `action`, `i18n`, and more).

What the surface layer does today: it leaves anything WebKit, the bridge or the corrections layer provides; for the
rest it adds Chrome's constants and enums, declares its events (which never fire), and adds functions that reject a
promise or **call a callback with no arguments**. It does not set `runtime.lastError`. That callback silence is the
concrete defect the first deliverable fixes.

Native namespaces today, all partial in some members unless noted:

- `history`, `topSites`, `bookmarks`, `downloads`, `notifications`, `idle`, `tts`, `offscreen`, `identity`,
  `sidePanel`, `proxy`, `tabCapture`, `userScripts`, `system.display`, `power`, `runtime.getContexts`.

WebKit-provided namespaces Zigzag patches: `tabs`, `windows`, `runtime`, `scripting`, `cookies`, `permissions`,
`action`/`browserAction`, `contextMenus`, `declarativeNetRequest`, `alarms`, `commands`, `i18n`, `storage`,
`webNavigation`, `webRequest` (observation only). `management` exists only on the Chrome Web Store page; `omnibox`,
`privacy`, `sessions`, `search`, `debugger`, `tabGroups` and `fontSettings` are inert surfaces.

UI today:

- The action popup is an `NSPopover` anchored at the address bar, sized by WebKit, with no Chrome min/max clamp.
- Options open only as a tab; `options_ui.open_in_tab` is not honoured.
- The side panel is a fixed 380 pt column on the right, without resize or open/close events.
- Omnibox has no address-bar UI; the manifest key is reported as unsupported.
- Notifications are text-only; buttons, images, lists and progress are ignored, and `onButtonClicked` never fires.
- DevTools extension pages and panels are not supported and are not listed as a limit.
- Native messaging is implemented, including Chrome host manifests and `chrome-extension://<id>/` origins.
- CRX installs require the Chrome Web Store's publisher signature as well as the developer's; a developer-signed
  package without the store's proof is refused. That is a deliberate gate, not a compatibility gap, but the corpus
  must install through the store or the app-bundled path.
- Per-profile `offSites` can turn one extension off on one site in one profile; it is a Zigzag addition to site
  access and must survive the registry and lifecycle work.
- MV2 background pages miss the per-extension prelude (WebSocket shim, keepalive, diagnostics) that MV3 workers get.
- `ConnectGuard` already holds back content scripts that reconnect in a tight loop — the kind of edge case this
  program generalises rather than one-offs.

The recurring defect is not one missing API; it is that capability is spread across a Swift switch, the JS layers,
the install report's permission-level `limitNames` table, and per-extension shims, with no single statement of what
Zigzag claims to support. The first deliverable makes that statement and makes every gap in it loud.

## The first deliverable: truth

No API work starts before the framework can state what it supports and fail honestly where it does not. The first plan
is that truth layer: `chrome-api.json` as the generated universe, `compatibility.json` as the claims over it, the stub
generator fixed to set `runtime.lastError`, MV2 prelude parity, accurate `getContexts`, and an install report driven
by the same claims, with tests that keep all of them in step.

It is deliberately first because it turns unknown breakage into a visible, finite list. Every later phase moves
entries from `unsupported` to a working status; none of it starts by guessing at the tail or by adding another shim
over a silent stub.

## The compatibility model

### 1. One capability registry

`chrome-api.json` is already the universe: 87 namespaces and 973 members at this writing — functions, events,
constants, enums and objects, nested ones included — generated from `chrome-types` by `scripts/chrome-api.py`. The
registry does not copy it. A small, hand-maintained `compatibility.json` sits over it and records only **claims**:
entries for the members whose status is not the default. Anything the universe lists and the overlay does not claim
is `unsupported`, with the namespace's reason and catalog key supplying the install-sheet line. That keeps the overlay
to the members Zigzag actually reaches, rather than 973 transcribed rows that would rot.

Each claim has one of six statuses:

- `native` — WebKit supplies it and it matches Chrome's observable contract.
- `patched` — WebKit supplies it and `webkit-differences.js` corrects it; the entry names the correction.
- `bridged` — Zigzag's native code answers it; the entry names the handler.
- `emulated` — Zigzag reproduces the observable behaviour without the Chrome service; the entry names it.
- `unsupported` — a stable reason and a catalog key for the install sheet; this is the default.
- `deprecated` — Chrome has removed it; answer only where old extensions need it.

A claim can be made at namespace level and overridden per member. `patched`, `bridged` and `emulated` must name an
implementation, and a claim naming one that does not exist fails the build, so the overlay cannot promise a handler
nobody wrote.

The registry drives four things, so they cannot drift: the JS surface, the runtime failure, the install report, and
the tests. `api-surface.js` still fills every missing member, because an `undefined` is worse than a loud failure: for
an `unsupported` member the stub is the claimed behaviour, and for a claimed member that is missing at runtime the
stub fails the same way and the log records drift. The install report derives its limits from the same claims; the
current static `limitNames` table becomes checked data rather than prose. A test takes the union of `chrome-api.json`
and `compatibility.json` and fails on a claim that names a member the universe does not have, a contradictory claim,
or an implementation with no claim behind it.

A build-time check compares every `native` claim with a runtime probe of WebKit at the deployment target, so `native`
cannot silently become false when macOS or WebKit changes; the published matrix is pinned to the WebKit version it was
verified against. `webkit-differences.js` becomes the implementation of `patched` claims, not a fourth list: every
correction has a claim and a test. Install-sheet wording is grouped by feature or namespace, carries a catalog key,
and is translated (including zh-Hans); the overlay does not embed English prose.

### 2. Chrome-shaped failure

Unsupported calls behave as Chrome does when an API is absent or a permission is missing: a callback receives
`runtime.lastError` and an undefined result; a Promise rejects with an `Error` naming the feature. `lastError` is set
only for the duration of the callback and cleared after it, as in Chrome. No unsupported member returns `undefined`
and looks like success.

The generator that has to change is `api-surface.js`'s `unavailable()`: today it calls the callback with no arguments
and never sets `runtime.lastError`, so a caller that checks only the error sees success and carries on with an
undefined result. The first deliverable fixes that function and the event objects it generates, rather than adding
another layer over them.

Events are the deliberate exception: every event is declared even when it can never fire. Extensions register
listeners at the top of a background script, and an absent event would throw there and kill the whole extension
rather than one feature. A never-firing event is named as a limit in the install sheet; the object exists, the
listener is accepted, and nothing arrives. Calls still fail loudly.

Part of this is truth in the install sheet: an extension that asks for devtools or dynamic `webRequestBlocking` is told
so before it is added, in words a person can act on.

### 3. API semantics

For every implemented namespace, match Chrome's observable contract:

- Callback and Promise forms; optional arguments; `this` binding; `chrome.runtime.lastError`.
- Event objects: `addListener`/`removeListener`/`hasListener`, listener argument shapes, and the fields Chrome
  promises (`tab`, `frameId`, `documentId`, `timeStamp`, `transitionType`, `url`).
- Message passing: `sendMessage`/`onMessage`, ports, `connect`, external messaging, structured cloning, and NUL-safe
  answers. Sender identity must be the real tab/frame/origin, never a manufactured one.
- Extension IDs, URLs, and `runtime.getURL` consistent with the scheme decision below.
- Tab identity in windows that share a space: a shared tab is reported once, in the window that holds it, with
  consistent indices across `tabs`, `windows` and their events.
- Legacy aliases (`chrome.extension.*`, `browserAction`, `pageAction`, `tabs.executeScript`/`insertCSS`) where old
  extensions still call them.

### 4. Lifecycle

- MV3 service workers: wake on events, stay alive only while work or an open port needs it, and survive update,
  suspend and restart without losing alarms or stored data.
- Bridged events wake a suspended worker: the native emitter calls `loadBackgroundContent()`, holds the event while
  `bridge.js` reconnects, then delivers it on the port, with a bounded queue and a logged drop if the background
  cannot load. The same path carries notifications, history, idle, side panel, TTS and context-menu events. An event
  that cannot be delivered this way is marked delivered-while-running in its claim, not promised as a wake-up.
- MV2 background pages: the same per-extension prelude, WebSocket shim, diagnostics and keepalive that MV3 workers
  get, so an old extension is not a second-class citizen.
- Accurate `runtime.getContexts` and `getBackgroundPage` for both.
- Install, update, enable, disable and uninstall transitions, including permission diffs and the update sheet.
- Alarms and storage survive relaunch; a missed alarm fires once, not in a burst.

### 5. Content scripts and worlds

Manifest and dynamic scripts, `world: MAIN`, `all_frames`, `match_about_blank`, `match_origin_as_fallback`, injected
CSS, and `web_accessible_resources`. Sender identity and `frameId` come from WebKit, not from the shim. User scripts
keep their existing world and messaging, but share the same claims and error semantics.

### 6. UI fidelity

- **Action popup.** Content-sized, clamped to Chrome's minimum and maximum (800×600 is the documented ceiling), with
  scrolling when the content is taller, correct Escape/click-outside/focus behaviour, and no clipping when the window
  is narrow. The popover is an implementation detail; the geometry and behaviour are the contract.
- **Options.** `options_ui.open_in_tab` decides between a tab and an embedded page in Settings › Extensions; both
  load the same extension URL and storage.
- **Side panel.** Resizable within sensible bounds, width remembered, `onOpened`/`onClosed` emitted, and
  `setPanelBehavior` honoured. Chrome's side panel is right-sided by default; changing sides is not required.
- **Omnibox.** A real keyword mode in the address bar: typing the keyword and a separator enters the extension's
  suggestions, `onInputChanged` and `onInputEntered` fire, and `setDefaultSuggestion` is visible.
- **Notifications.** Match Chrome on macOS, which is the bar: title, message, icon, images and buttons through
  `UNUserNotificationCenter` categories, with `onButtonClicked`; lists, progress and priority degrade to text and are
  documented. No new in-app notification host.
- **Context menus.** Page, action, selection, link, editable and tools contexts; checkbox and radio items;
  separators; icons.
- **Extension windows and pages.** `windows.create({type: "popup"})` opens a Chrome-like popup (no Zigzag chrome,
  content-sized), and extension pages load under the scheme the extension expects.
- **Media and capture.** `tabCapture` video as well as audio, and `desktopCapture` through the system picker. These
  are the difference between a recorder working and an extension that appears installed. `pageCapture.saveAsMHTML`
  has no MHTML writer in WebKit (it produces a webarchive), so it stays a documented limit unless the corpus needs
  the file format, in which case a serialiser is its own project.
- **DevTools.** WebKit exposes no extension devtools API. For this version it is a documented limit with an install
  warning; if the corpus shows it is common enough, a dedicated Zigzag devtools host is its own project.

### 7. The URL scheme

Extensions and their resources should live at `chrome-extension://<id>/…`, because extensions hard-code that scheme in
manifests, CSP, `web_accessible_resources` and fetch calls. `webkit-extension://` stays the internal scheme if WebKit
requires it. The spike decides between serving the public scheme directly through a custom scheme handler and
aliasing it to the internal one; either way `runtime.getURL` returns the form the extension expects, and both forms
resolve to the same bytes and origin behaviour.

The security invariant comes before the convenience: a web page must never be served an extension resource that is
not in `web_accessible_resources`, and a page navigation must never become an extension-origin document. A custom
scheme handler sees the request but not the initiating document, so it may not be able to tell an extension's own
fetch from a page's. If neither direct serving nor aliasing can enforce `web_accessible_resources` and the extension
CSP, the public scheme stays `webkit-extension://` and `chrome-extension://` is reported as a documented limit rather
than shipped insecure.

### 8. Permissions and install

- The install/update sheet lists abilities and limits from the claims and the generated universe, not from a static
  table.
- Optional permissions and `permissions.request` present a real sheet; a request cannot widen the profile's site
  access mode (`all`, `click`, `sites`) or turn extensions on for a site where they are off.
- Unknown or WebKit-dropped permissions are reported, not silently discarded.
- Native messaging consent is explicit, as it is today.
- Private windows behave as they do now: no extension controller, no standing grants.

### 9. Networking

- `declarativeNetRequest`: complete static, dynamic and session rules; per-rule enable/disable and counts; regex
  support; header modification; redirects; `getMatchedRules`.
- `webRequest`: observation is already native. `onAuthRequired` works. Blocking and redirecting are the hard part:
  WebKit does not expose a per-request decision point. A deterministic subset (URL/type matches with cancel or a
  fixed redirect) can be compiled into content rules; a handler that decides per request from live state cannot be.
  The design implements the deterministic subset, reports the dynamic case honestly, and steers new extensions to
  DNR. A local intercepting proxy is considered and rejected: privacy, certificate and performance costs outweigh the
  compatibility gain.
- Proxy: fixed HTTP/HTTPS/SOCKS servers work. PAC needs a per-URL decision WebKit cannot apply; it stays a documented
  limit unless the spike finds a supported path.
- Cookie stores, `sameSite` and partition keys match Chrome where WebKit exposes them.

### 10. Chrome-only and Google-backed services

The rule is official endpoints and informed consent; no spoofing.

- `identity.launchWebAuthFlow`: harden redirect matching, window lifecycle and error results.
- `identity.getAuthToken`: bridge through a Zigzag-owned OAuth client where Google permits the scopes, and fail
  explicitly where it does not. Chrome's own client ID is never used.
- `identity.getProfileUserInfo`: the Zigzag profile's account where there is one, empty otherwise; no invented email.
- `storage.sync`: Chrome-compatible local semantics and quotas first. Cross-device sync via iCloud key-value storage
  if the app's signing and distribution allow it; otherwise the setting and install sheet say "stays on this Mac"
  rather than pretending to sync.
- `management`: full local management of installed extensions, not only the Web Store page.
- Native messaging: already implemented and stays; the work is completeness against real hosts, not a new bridge.
- Deprecated Google channels (`gcm`, `instanceID`, `pushMessaging`): documented `unsupported`; no emulation.
- `chrome.webstore.install` and inline install: not restored; the store's own page and Zigzag's install flow remain.

### 11. Performance and robustness

Extensions must not be able to make Zigzag janky: lazy shims, no synchronous chatter per request, the existing
connection-storm guard, bounded logs, and a cap on native messaging and capture work. A slow or broken extension
must fail inside its own world, not stall the browser's main thread.

### 12. The compatibility harness

- An in-repo fixture extension exercising manifest, background, content script, popup, options, storage, messaging
  and a native host, used by end-to-end tests.
- Contract tests per namespace against the JS surface, not only per Swift handler.
- A committed corpus document listing real extensions by ID, version, category and smoke flow, with recorded results.
  Binaries are never committed; the runner installs from the store locally.
- Geometry checks for popup and options pages (size, clamp, scroll), and screenshot checks where practical.
- A generated compatibility matrix (`docs/extension-compatibility/matrix.md`) from `compatibility.json` and
  `chrome-api.json`, plus a short known-limits page.
- The debug `exttest` command and the existing extension tests stay the first line; the corpus is the second.

## Decisions I am making

- `chrome-api.json` is the generated universe; `compatibility.json` is the hand-maintained claim overlay. The JS
  surface, install report and matrix are generated from the two, never hand-written.
- Truth ships first: no new API work until the generated universe, the claim overlay, honest failure and the install
  report exist.
- Unsupported means a loud, Chrome-shaped failure and an install-sheet line — never a silent stub.
- Tier A (framework core) and Tier B (widely used) are in scope; Tier C (devtools, debugger, PAC, deprecated Google
  channels, enterprise) is documented except where the corpus proves otherwise.
- No new per-extension shims. Existing ones are retired when the framework covers their reason.
- `chrome.tabGroups` and `tabs.group`/`ungroup` are bridged onto Zigzag's tab-tree groups, IDs, ordering and colours
  included; `tabs.ungroup` stops reporting success before it can ungroup. Tab managers are in the corpus.
- Notifications follow Chrome on macOS, not Chrome's abstract maximum; fields macOS cannot show are documented.
- The public extension scheme should be `chrome-extension://`; `webkit-extension://` is an internal detail if it must
  remain.
- Google-backed features use official endpoints and consent; local equivalents are labelled as local.
- Native messaging is completed, not rebuilt.
- Firefox is a separate design after this program merges.

## Shaping the work

The work is a sequence of small PRs on `main`, in this order. Each PR is independently reviewable and leaves the
browser working.

1. **Truth.** The generated universe plus claim overlay, generated stubs and report, Chrome-shaped errors, MV2 prelude
   parity, `getContexts`, tests that keep them in sync. This is deliberately first: it converts unknown breakage into a
   visible list.
2. **Core.** Runtime, messaging and ports, tabs and windows, tab groups, storage, alarms, scripting, permissions, i18n,
   context menus and notifications; legacy aliases.
3. **UI.** Popup geometry, options (tab and embedded), side panel resize and events, omnibox, extension windows,
   the scheme decision.
4. **Media and capture.** Tab and desktop capture, page capture, TTS events and notification media.
5. **Networking.** DNR completeness, the deterministic webRequest blocking subset, proxy and cookie edges.
6. **Chrome and Google.** Identity, storage sync, management, deprecated channels, install/update/permission flows.
7. **Corpus hardening.** Real extensions, the tail they expose, performance, docs and the matrix; then freeze.

## Plans

The seven phases are seven plans, not one branch. The first is **Truth**, covering only the claim overlay, the failure
semantics, MV2 prelude parity, `getContexts` and the tests that keep them in step; it is the plan written next, and it
merges before any later phase begins. Each later plan starts from the merged previous one and carries its own tests
and full gate. That keeps truth reviewable on its own before the API work commits to a shape, and keeps each change
small against a moving `main`.

## Spikes before those commitments harden

Each is a small experiment on `main`'s current code, not a product change:

1. Popup geometry: what WebKit exposes for content size and scroll, and whether clamping outside the popover is
   enough for focus and dismissal.
2. `chrome-extension://` scheme: can a custom scheme handler serve it while enforcing `web_accessible_resources` and
   the extension CSP, and do content scripts and storage keep their origin identity?
3. DevTools: does the installed WebKit expose any extension devtools surface at Zigzag's deployment target?
4. `identity.getAuthToken`: can a Zigzag OAuth client request the scopes extensions commonly ask for, and what does
   Google's consent show?
5. iCloud key-value storage: does Zigzag's signing and distribution permit it for `storage.sync`?
6. webRequest blocking: which deterministic handlers compile cleanly into content rules, and what is left over?
7. Capture: ScreenCaptureKit for tab video and the system picker for `desktopCapture` at the deployment target.
8. Native messaging: one real host (1Password or Bitwarden) end to end, including reconnect and quit.
9. Bridged events and a suspended MV3 worker: load the background, wait for `bridge.js` to reconnect, deliver a
   queued event, and find the point where an event is lost.
10. Notification buttons and images through the macOS center, and which fields Chrome on macOS itself shows.
11. Tab-group IDs, ordering and colours when Chrome's per-window groups are mapped onto Zigzag's tab tree.

## Risks

- **WebKit limits.** DevTools, per-request blocking, PAC and possibly the scheme alias may be impossible without
  engine changes. The design names them early and reports them honestly rather than discovering them in the corpus.
- **Google authorization.** `getAuthToken` may be unavailable for scopes Google will not grant a third-party client;
  `storage.sync` may have no permitted backend. The fallbacks are explicit, not fake.
- **Scope.** "Most if not all" is open-ended. The claims, tiers and corpus are how it becomes finite and testable.
- **Security.** Host permissions, native messaging, capture and site access are the places where compatibility work
  can weaken the browser. Each gets its own tests; no grant is widened for a corpus pass.
- **Performance.** More shims and events mean more main-thread work. The storm guard and the lazy surface are the
  model; benchmarks are part of the corpus.
- **Main drift.** The owner moves `main` quickly. Small PRs, rebased one at a time, with the full gate before push.

## Definition of done for the Chrome program

- The registry covers every namespace and member in `chrome-api.json`; no silent unsupported member remains.
- Tier A and Tier B are complete, or have a documented, install-sheet-visible reason.
- Popup, options, side panel, omnibox, notifications and context menus pass their geometry and behaviour checks.
- MV2 and MV3 lifecycle tests pass across suspend, restart, update and uninstall.
- The corpus meets its agreed bar, with no security or private-window regressions.
- The matrix and known-limits page are published, and every open Chrome-compatibility PR is merged.
- Only then does the Firefox design (#277) start.

## What is left to the builder

- The exact `compatibility.json` schema (status, implementation and reason fields) and where the generated JS copy
  lives.
- Whether the public scheme is served directly or aliased, after the spike.
- The popup's minimum size and scroll behaviour within Chrome's documented bounds.
- The corpus: which extensions, which flows, and the pass bar. The intent is breadth across password managers, ad
  blockers, tab managers, translators, automation, media and developer tools, not a single category.
- The order inside each phase, and how much of Tier C is worth doing after the corpus speaks.
