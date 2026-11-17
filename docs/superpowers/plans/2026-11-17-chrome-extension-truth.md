# Chrome Extension Truth Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Zigzag's Chrome extension compatibility truthful: a generated API universe, a small claim overlay, Chrome-shaped failures, an install report derived from the claims, MV2 background parity, and honest contexts.

**Architecture:** `chrome-api.json` stays the generated universe. A new `compatibility.json` records only claims; anything the universe lists and the overlay does not claim is `unsupported`. A Swift registry validates the overlay against the universe and drives the install report. `api-surface.js` sets `runtime.lastError` for callback-form unsupported calls and rejects Promise-form ones. MV2 backgrounds get the prelude through the overlay manifest. `getContexts` reports only the contexts Zigzag can name. The overlay is not injected into the prelude, so a report-only claim change does not rebuild every extension overlay.

**Tech Stack:** Swift 6, AppKit, WebKit, Swift Testing, JavaScriptCore, Python 3, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-17-extension-compatibility-design.md`

## Global Constraints

- `SWIFT_VERSION: "6.0"`, default actor isolation MainActor, deployment target macOS 15.4.
- `compatibility.json` is report-only. It never grants, widens or drops a permission, never calls `setPermissionStatus`, and never becomes a source of `declaredPermissions`.
- `chrome-api.json` is generated. `compatibility.json` is hand-maintained. The JS surface, install report and matrix are generated from the two.
- No per-extension shims. The existing 1Password, Bitwarden, Motrix and Tampermonkey shims are grandfathered; the prelude signature must not rebuild for report-only claims.
- `lastError` is set only for the duration of a failing callback and cleared after it, including when the callback throws. Promise failures reject with an `Error` and do not set it.
- Localization: every new user-facing string uses `String(localized:)` with a `comment:`, and every catalog key has a zh-Hans value.
- New files and resources are added by `xcodegen generate`; never hand-edit the four `project.pbxproj` sections.
- Gate: `TEST_RUNNER_ZIGZAG_TEST_VAULT=memory xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag`. In the extension worktree the full gate is the worktree script; record the baseline before starting.
- Private windows never host extension controllers, grants or contexts; `getContexts` must not report a private tab.

## Spec Corrections

These are facts the implementation must honour even where the design's wording is broader:

1. `chrome.runtime.getContexts` is MV3-only in Chrome (116+). Giving it to an MV2 background is a Zigzag superset and must not be claimed as Chrome behaviour.
2. `chrome.runtime.getBackgroundPage` is MV2-only and deprecated since Chrome 133. In MV3 pages it exists but errors with `"You do not have a background page."`; in an MV3 service worker it is absent.
3. MV2 event pages (`persistent: false`) must be allowed to suspend. Do not add the MV3 keepalive to them. A background page has real WebSockets, so the WebSocket stand-in stays service-worker-only.
4. `deprecated` means Chrome still answers it. A removed member is `unsupported` with reason `removed`, not `deprecated`.
5. The install sheet is permission-keyed. `compatibility.json` needs an explicit `permissions` section; member claims alone cannot replace `limitNames`.

## Review Focus

1. **A claim that grants.** The overlay must be inert data: no permission status, site access or state write follows from it. Test in Task 3.
2. **A namespace claim over a partial WebKit namespace.** Member overrides must be authoritative; a namespace-level `native` claim may not cover a member WebKit lacks. Test in Tasks 2 and 3.
3. **`lastError` leaking.** An unsupported callback sees it; the next call does not; a Promise failure never sets it. Test in Task 4.
4. **MV2 page identity.** The prelude may not replace the declared background page, reorder its scripts, or edit its CSP. Test in Task 7.
5. **Private contexts.** `getContexts` and its filters must not expose a private tab or a fabricated `documentId`. Test in Task 8.
6. **Report regressions.** An unknown permission must be reported, not dropped, and every existing limit's English and Chinese wording must stay. Test in Task 6.

---

### Task 0: Branch and baseline

**Files:**
- No source changes.

**Interfaces:**
- Produces: a clean worktree and a recorded baseline; the known headless `SettingsLayoutTests` failure is the only accepted red.

- [ ] **Step 1: Branch from the merged main**

```bash
git fetch origin main
git switch -c feat/extension-truth origin/main
```

If the design document has not merged yet, branch from the design branch and rebase after it lands.

- [ ] **Step 2: Run the baseline gate**

```bash
TEST_RUNNER_ZIGZAG_TEST_VAULT=memory xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag 2>&1 | tail -20
```

Expected: all suites pass except `SettingsLayoutTests.fitsThePageItIsGivenInsideAnAnimation` in a headless run. Record the exact count; do not treat another red as baseline.

- [ ] **Step 3: Commit nothing**

The branch is clean and ready for Task 1.

---

### Task 1: Generated universe

**Files:**
- Modify: `scripts/chrome-api.py`
- Regenerate: `Zigzag/Resources/Extensions/chrome-api.json`
- Create: `ZigzagTests/ChromeUniverseTests.swift`
- Modify: `Zigzag.xcodeproj/project.pbxproj` (only via `xcodegen generate`)

**Interfaces:**
- Produces: `ChromeUniverse.load(bundle:)`, `ChromeUniverse.contains(_:)`, `ChromeUniverse.paths`, `ChromeUniverse.NodeKind`.
- Produces: `python3 scripts/chrome-api.py --check` exits non-zero when the committed JSON differs from a regeneration.

- [ ] **Step 1: Write the failing universe test**

```swift
import Testing
@testable import Zigzag

struct ChromeUniverseTests {
    @Test func storageAreasAreInTheUniverse() throws {
        let universe = try ChromeUniverse.load(bundle: .main)
        #expect(universe.contains("storage.local.get"))
        #expect(universe.contains("storage.sync.QUOTA_BYTES"))
        #expect(universe.contains("privacy.network.webRTCIPHandlingPolicy.get"))
    }
}
```

Run:

```bash
xcodegen generate
TEST_RUNNER_ZIGZAG_TEST_VAULT=memory xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag \
  -only-testing:ZigzagTests/ChromeUniverseTests
```

Expected: FAIL on `storage.local.get`; the committed generator drops the `StorageArea & { … }` form.

- [ ] **Step 2: Fix the generator**

In `scripts/chrome-api.py`:

- Pin `CHROME_TYPES_VERSION = "0.1.464"` and download that tarball when no path is given.
- Parse an inline object after `Type & {`, merging the resolved base interface's members with the inline constants.
- Keep object-level `constants` and `enums`, not only namespace-level ones.
- Add `--check`: regenerate in memory and exit 1 with the first differing path when the committed file differs.
- Keep the output sorted and byte-stable.

- [ ] **Step 3: Regenerate and run the test**

```bash
python3 scripts/chrome-api.py
python3 scripts/chrome-api.py --check
xcodegen generate
TEST_RUNNER_ZIGZAG_TEST_VAULT=memory xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag \
  -only-testing:ZigzagTests/ChromeUniverseTests
```

Expected: the regeneration check is clean and the test passes.

- [ ] **Step 4: Commit**

```bash
git add scripts/chrome-api.py Zigzag/Resources/Extensions/chrome-api.json \
  ZigzagTests/ChromeUniverseTests.swift Zigzag.xcodeproj/project.pbxproj
git commit -m "The generated API universe includes every storage area"
```

---

### Task 2: Claim overlay, model and validator

**Files:**
- Create: `Zigzag/Extensions/ExtensionCompatibility.swift`
- Create: `ZigzagTests/ExtensionCompatibilityTests.swift`
- Modify: `Zigzag.xcodeproj/project.pbxproj` (only via `xcodegen generate`)

**Interfaces:**
- Consumes: `ChromeUniverse` from Task 1.
- Produces: `CompatibilityStatus`, `CompatibilityReason`, `CompatibilityClaim`, `CompatibilityPermission`, `CompatibilityGroup`, `CompatibilityOverlay`, `CompatibilityLimit`, `CompatibilityRegistry`, `CompatibilityValidator`.
- Produces: `ExtensionCompatibility.shared` and `ExtensionCompatibility.limits(forPermissions:manifestKeys:)`.

```swift
enum CompatibilityStatus: String, Codable, CaseIterable {
    case native, patched, bridged, emulated, unsupported, deprecated
}

enum CompatibilityReason: String, Codable {
    case webkitMissing, notImplemented, chromeService, platform, policy,
         securityGate, deprecatedChannel, enterprise, removed
}

struct CompatibilityClaim: Codable {
    var status: CompatibilityStatus
    var implementation: String?       // required for patched, bridged, emulated; "swift:" or "js:"
    var reason: CompatibilityReason?  // required for unsupported, deprecated
    var group: String?                // required for unsupported, deprecated
    var members: [String: CompatibilityClaim]?
}

struct CompatibilityPermission: Codable {
    var status: CompatibilityStatus
    var claims: [String]?
    var reason: CompatibilityReason?
    var catalog: String?
    var group: String?
    var order: Int?
}

struct CompatibilityGroup: Codable {
    var catalog: String
    var order: Int?
}

struct CompatibilityOverlay: Codable {
    var schemaVersion: Int
    var chromeTypes: String
    var groups: [String: CompatibilityGroup]
    var claims: [String: CompatibilityClaim]
    var permissions: [String: CompatibilityPermission]
    var manifest: [String: CompatibilityPermission]
}

struct CompatibilityLimit: Hashable, Sendable {
    let catalogKey: String?
    let group: String
    let reason: CompatibilityReason
    let status: CompatibilityStatus
    let source: String
    var text: String { CompatibilityText.text(for: catalogKey, fallback: source) }
}
```

Task 2 adds a fallback `CompatibilityText.text(for:fallback:)` that returns `fallback` until Task 3 expands its switch. The type exists from the moment `CompatibilityLimit` does.

- [ ] **Step 1: Write the failing validator tests**

Use inline JSON fixtures in `ExtensionCompatibilityTests`. The tests must not depend on the real overlay yet.

```swift
@Test func everyClaimNamesAMemberOfTheGeneratedUniverse() throws
@Test func noClaimIsMadeTwice() throws
@Test func claimsCarryTheFieldsTheirStatusNeeds() throws
@Test func everyClaimedImplementationExists() throws
```

Expected on the first run: `ChromeUniverse`, `CompatibilityOverlay` and `CompatibilityValidator` do not exist.

- [ ] **Step 2: Implement the model and validator**

`CompatibilityValidator.diagnostics(overlay:universe:implementations:)` must:

1. Walk namespace and member claims, building canonical paths (`storage.local.get`, `privacy.network.webRTCIPHandlingPolicy.get`).
2. Reject a claim on a path the universe does not have.
3. Reject duplicate canonical paths, including a namespace claim and a member claim for the same path.
4. Reject a missing `implementation` for `patched`/`bridged`/`emulated`.
5. Reject a missing `reason` or `group` for `unsupported`/`deprecated`.
6. Reject an implementation that is not a known `swift:` handler or a `js:` symbol present in the JS source.
7. Reject a group that has no `groups` entry or no catalog key.

For the implementation check, hoist `ExtensionBridge`'s handler types into `static let handlerNames: Set<String>` and read the `webkit-differences.js` source for `js:` names. Do not create a second hand-maintained implementation list.

- [ ] **Step 3: Implement the registry**

`CompatibilityRegistry` resolves the effective claim for a path by walking the namespace claim and its member overrides. A namespace status is the worst status of its members when a member override is present; the overlay may not make a namespace look better than its worst member.

- [ ] **Step 4: Run and commit**

```bash
xcodegen generate
TEST_RUNNER_ZIGZAG_TEST_VAULT=memory xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag \
  -only-testing:ZigzagTests/ExtensionCompatibilityTests
git add Zigzag/Extensions/ExtensionCompatibility.swift ZigzagTests/ExtensionCompatibilityTests.swift \
  Zigzag.xcodeproj/project.pbxproj
git commit -m "A claim overlay validates against the generated API universe"
```

---

### Task 3: Seed the claims and the install-sheet catalog

**Files:**
- Create: `Zigzag/Resources/Extensions/compatibility.json`
- Modify: `Zigzag/Extensions/ExtensionCompatibility.swift` (`CompatibilityText`)
- Modify: `Zigzag/Resources/Localizable.xcstrings`
- Modify: `ZigzagTests/ExtensionCompatibilityTests.swift`

**Interfaces:**
- Consumes: model and validator from Task 2.
- Produces: the real overlay and `CompatibilityText.text(for:fallback:)`.

- [ ] **Step 1: Write the failing seed tests**

```swift
@Test func everyNamespaceZigzagImplementsIsClaimed()
@Test func everyKnownPermissionHasAClaim()
@Test func everyClaimedImplementationExists()
@Test func everyGroupResolvesToACatalogEntry()
@Test func everyLimitCatalogKeyIsTranslated()
@Test func aClaimCannotGrantAnything()
```

`everyKnownPermissionHasAClaim` checks the union of the old `limitNames` keys and `ExtensionReport.askedPermissions`. `aClaimCannotGrantAnything` loads the real overlay and asserts `ExtensionBridge.handlerNames` and `ExtensionBridgeScript.permissions` are unchanged, and that `CompatibilityRegistry` has no setter for permission state.

- [ ] **Step 2: Seed `compatibility.json`**

Use namespace claims for the namespaces Zigzag actually reaches. The rest stay unclaimed and therefore `unsupported`.

```text
native:      alarms, commands, i18n, storage, webNavigation
patched:     tabs, windows, runtime, action, browserAction, contextMenus, menus,
             cookies, permissions, scripting, declarativeNetRequest, webRequest
bridged:     history, topSites, bookmarks, downloads, notifications, idle, tts,
             offscreen, identity, sidePanel, proxy, tabCapture, userScripts,
             system.display, power
deprecated:  extension (the legacy namespace Zigzag partly answers)
unsupported: omnibox, privacy, sessions, search, debugger, tabGroups, fontSettings,
             devtools, publicSuffix, management, pageCapture, desktopCapture,
             and every other namespace the inventory does not implement
```

Partial namespaces need member overrides. At minimum:

```text
tabs:        group, ungroup, createSplit, unsplit, discard, highlight, executeScript, insertCSS
windows:     create popup behaviour is a limit, not a missing member
runtime:     restart, restartAfterDelay, getPackageDirectoryEntry; getContexts is bridged;
             getBackgroundPage is patched (MV2 only)
action:      setBadgeTextColor, getBadgeTextColor, getUserSettings, onUserSettingsChanged
notifications: onButtonClicked, onShowSettings, onPermissionLevelChanged, getPermissionLevel
sidePanel:   getLayout, onOpened, onClosed
system.display: every function but getInfo/getDisplayLayout; onDisplayChanged
power:       reportActivity
identity:    getAuthToken, getProfileUserInfo, getAccounts, removeCachedAuthToken, onSignInChanged
bookmarks:   onImportBegan, onImportEnded, onChildrenReordered
downloads:   setShelfEnabled, setUiOptions, acceptDanger, onDeterminingFilename
tabCapture:  video capture is a permission-level limit; the capture member itself is bridged for audio
cookies:     getPartitionKey
permissions: addHostAccessRequest, removeHostAccessRequest
storage:     managed, sync semantics
scripting:   file: patterns
declarativeNetRequest: updateStaticRules, getDisabledRuleIds, isRegexSupported, rule counts
```

The overlay also needs an explicit `permissions` section because the install sheet is permission-keyed. Map each old `limitNames` row to one of:

```text
supported    no install-sheet line
partial      one line per distinct catalog key in claims
unsupported  one line, with the old wording
deprecated   one line, Chrome still answers it
```

Keep the old English strings as the catalog values: `"Proxy scripts (PAC)"`, `"Tab groups"`, `"Font settings"`, `"Reading aloud"`, `"Your location"`, `"Reading what you copy"`, `"Managing other extensions"`, `"Privacy settings"`, `"Debugging pages"`, `"Saving pages"`, `"Recording your screen"`, `"Signing in with your account"`, `"Address bar keyword"`. The 14 rows that `coveredPermissions` suppressed today become `supported`/`bridged` claims with no catalog.

- [ ] **Step 3: Add the catalog text**

`CompatibilityText` maps a semantic key to a localized string:

```swift
static func text(for key: String?, fallback: String) -> String {
    guard let key else { return fallback }
    switch key {
    case "extension.limit.tabGroups":
        return String(localized: "extension.limit.tabGroups", defaultValue: "Tab groups",
                      comment: "A Chrome extension feature Zigzag cannot provide: grouping tabs.")
    // one case per catalog key
    default:
        return fallback
    }
}
```

Add every new key to `Localizable.xcstrings` with a zh-Hans value. Do not put English prose in `compatibility.json`.

- [ ] **Step 4: Run and commit**

```bash
xcodegen generate
TEST_RUNNER_ZIGZAG_TEST_VAULT=memory xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag \
  -only-testing:ZigzagTests/ExtensionCompatibilityTests -only-testing:ZigzagTests/LocalizationTests
git add Zigzag/Resources/Extensions/compatibility.json Zigzag/Extensions/ExtensionCompatibility.swift \
  Zigzag/Resources/Localizable.xcstrings ZigzagTests/ExtensionCompatibilityTests.swift
git commit -m "The compatibility claims and install-sheet wording are seeded"
```

---

### Task 4: Chrome-shaped failure in the generated surface

**Files:**
- Modify: `Zigzag/Resources/Extensions/api-surface.js`
- Modify: `ZigzagTests/ExtensionScriptTests.swift`

**Interfaces:**
- Produces: `unavailable(name)` that calls a callback asynchronously with no arguments and `runtime.lastError` set, or rejects a Promise; leaves `lastError` undefined outside the callback.
- Produces: event objects that track `addListener`/`removeListener`/`hasListener`/`hasListeners` without firing.

- [ ] **Step 1: Add `surfaceWorld` and the failing tests**

```swift
private static func surfaceWorld(_ surface: String? = nil) throws -> JSContext
```

Seed `chrome.runtime.getManifest`, `sendNativeMessage`, `console`, and the manual timer queue used by `fakeWorld`.

```swift
@Test func anUnsupportedCallbackGetsLastErrorAndNoResult()
@Test func lastErrorIsGoneOnceTheCallbackReturns()
@Test func anUnsupportedPromiseRejectsWithTheFeatureNameOnly()
@Test func anUnsupportedCallIsNotedOnce()
@Test func unsupportedEventsKeepTheirListenersAndNeverFire()
```

Expected on the first run: the callback sees no `lastError`; the event's `hasListener` is always false.

- [ ] **Step 2: Implement `withLastError` and `unavailable`**

```js
const errorFor = (name) => ({ message: `${name} isn't available in Zigzag` });

const withLastError = (name, run) => {
  const error = errorFor(name);
  const saved = runtimes.map((runtime) => [runtime, Object.getOwnPropertyDescriptor(runtime, 'lastError')]);
  try {
    for (const runtime of runtimes) {
      try {
        Object.defineProperty(runtime, 'lastError', {
          get: () => error, configurable: true, enumerable: true,
        });
      } catch (e) {
        runtime.lastError = error;
      }
    }
    run();
  } finally {
    for (const [runtime, descriptor] of saved) {
      if (descriptor) Object.defineProperty(runtime, 'lastError', descriptor);
      else { try { delete runtime.lastError; } catch (e) {} }
    }
  }
};
```

`unavailable(name)`:

```js
const callback = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
note(name);
if (callback) {
  setTimeout(() => {
    try { withLastError(name, () => callback()); }
    catch (e) { console.error(e); }
  }, 0);
  return undefined;
}
return Promise.reject(new Error(errorFor(name).message));
```

- [ ] **Step 3: Track event listeners**

```js
const listeners = new Set();
return {
  addListener(listener) { if (typeof listener === 'function') listeners.add(listener); },
  removeListener(listener) { listeners.delete(listener); },
  hasListener(listener) { return listeners.has(listener); },
  hasListeners() { return listeners.size > 0; },
  addRules(rules, callback) { if (typeof callback === 'function') setTimeout(() => withLastError('rules', () => callback([])), 0); },
  getRules(ids, callback) { /* same shape */ },
  removeRules(ids, callback) { /* same shape */ },
};
```

Keep the event inert; the listener set is only for `hasListener`.

- [ ] **Step 4: Run and commit**

```bash
TEST_RUNNER_ZIGZAG_TEST_VAULT=memory xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag \
  -only-testing:ZigzagTests/ExtensionScriptTests
git add Zigzag/Resources/Extensions/api-surface.js ZigzagTests/ExtensionScriptTests.swift
git commit -m "An unsupported surface call fails the way Chrome's callback and promise forms do"
```

---

### Task 5: The same failure in the bridge and compatibility layer

**Files:**
- Modify: `Zigzag/Resources/Extensions/bridge.js`
- Modify: `Zigzag/Extensions/ExtensionStore.swift` (the `compatibility` prelude)
- Modify: `ZigzagTests/ExtensionScriptTests.swift`

**Interfaces:**
- Consumes: the `lastError` pattern from Task 4.
- Produces: `callWithError` used by every bridge callback failure and by `ExtensionShims.compatibility`'s `no()`.

- [ ] **Step 1: Add the failing tests**

```swift
@Test func aBridgedCallbackFailureSetsLastError()
@Test func aCompatibilityLayerFailureNoLongerLooksLikeSuccess()
@Test func anUnsupportedCompatibilityMemberIsNotAnsweredWithAnEmptySuccess()
```

Use `bridge.js`'s existing callback tests and the `compatibility` source extracted from `ExtensionStore`.

- [ ] **Step 2: Fix `bridge.js`**

Replace the `callback(undefined)` failure path with the same save/define/call/restore block. The error message is the bridge's existing `<ns>.<fn> isn't available in Zigzag` string.

- [ ] **Step 3: Fix `ExtensionShims.compatibility`**

`no()` sets `lastError` for the callback duration and rejects a Promise. For every `done([])` or no-op that stands for a Chrome member Zigzag does not implement (management, sessions, debugger, topSites, privacy, and the rest of the inventory), use the failing stub instead of an empty success. Keep only intentional emulations that the overlay claims `emulated`; add those claims in Task 3 if they are missing.

- [ ] **Step 4: Run and commit**

```bash
TEST_RUNNER_ZIGZAG_TEST_VAULT=memory xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag \
  -only-testing:ZigzagTests/ExtensionScriptTests
git add Zigzag/Resources/Extensions/bridge.js Zigzag/Extensions/ExtensionStore.swift \
  ZigzagTests/ExtensionScriptTests.swift
git commit -m "Bridged and compatibility-layer failures set lastError too"
```

---

### Task 6: Install report from the claims

**Files:**
- Modify: `Zigzag/Extensions/ExtensionReport.swift`
- Modify: `Zigzag/Extensions/ExtensionSheet.swift`
- Modify: `Zigzag/Settings/SettingsView.swift`
- Modify: `Zigzag/Import/ImportExtensionViews.swift`
- Modify: `ZigzagTests/ExtensionSecurityTests.swift`
- Modify: `ZigzagTests/ExtensionCompatibilityTests.swift`

**Interfaces:**
- Consumes: `CompatibilityRegistry` and `CompatibilityLimit` from Tasks 2 and 3.
- Produces: `ExtensionReport.limits: [CompatibilityLimit]`.

- [ ] **Step 1: Write the failing report tests**

```swift
@Test func limitsComeFromClaimsNotFromWebKit()
@Test func aPermissionNoClaimCoversIsReportedNotDropped()
@Test func oneFeatureIsOneLineHoweverManyMembersAsk()
@Test func theInstallSheetLimitsReadAsTheyDidBefore()
@Test func anUpdateShowsOnlyLimitsItAdds()
```

Expected on the first run: `limits` is still `[String]`; an unknown permission produces no line.

- [ ] **Step 2: Replace the static tables**

Delete `limitNames`, `partLimits` and `manifestLimits`. Build limits with:

```swift
limits = ExtensionCompatibility.shared.limits(forPermissions: requested,
                                               manifestKeys: manifestKeys)
```

Keep the shim subtraction (`coveredPermissions`, `knownIssue`) after the claims and log a shim-covered limit once. The overlay is the source of wording; the shim only suppresses a line it actually covers.

`init(requesting:)` uses the same limits, not `[]`. `init(newIn:comparedTo:)` computes the delta by catalog key. `init(combining:)` keeps `limits = []`.

- [ ] **Step 3: Update the render sites**

`ExtensionSheet`, `SettingsView` and `ImportExtensionViews` render `limit.text` instead of the string. Remove the 200 pt cap in the sheet's limit box or make it scroll; a grouped list must not clip silently.

- [ ] **Step 4: Run and commit**

```bash
TEST_RUNNER_ZIGZAG_TEST_VAULT=memory xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag \
  -only-testing:ZigzagTests/ExtensionSecurityTests \
  -only-testing:ZigzagTests/ExtensionCompatibilityTests \
  -only-testing:ZigzagTests/LocalizationTests
git add Zigzag/Extensions/ExtensionReport.swift Zigzag/Extensions/ExtensionSheet.swift \
  Zigzag/Settings/SettingsView.swift Zigzag/Import/ImportExtensionViews.swift \
  ZigzagTests/ExtensionSecurityTests.swift ZigzagTests/ExtensionCompatibilityTests.swift
git commit -m "The install sheet takes its limits from the compatibility claims"
```

---

### Task 7: MV2 background parity

**Files:**
- Modify: `Zigzag/Extensions/ExtensionStore.swift`
- Create: `ZigzagTests/ExtensionOverlayTests.swift`
- Modify: `Zigzag.xcodeproj/project.pbxproj` (only via `xcodegen generate`)

**Interfaces:**
- Produces: `ExtensionStore.overlaySignature(prelude:patches:fill:package:)`.
- Produces: `ExtensionStore.writeOverlayManifest(in:from:prelude:)` (internal for tests) handling `background.service_worker`, `background.page`, `background.scripts`, and no background.
- Produces: `ExtensionShims.backgroundPrelude(keepsAlive:)`.

- [ ] **Step 1: Write the failing overlay tests**

```swift
@Test func mv2BackgroundScriptsRunThePreludeFirst()
@Test func mv2BackgroundPageGetsThePreludeAheadOfItsScripts()
@Test func aBackgroundPageInASubfolderLoadsThePreludeFromTheRoot()
@Test func thePreludeTagIsInsertedOnce()
@Test func mv3WorkerStillGetsTheEntryScript()
@Test func aManifestWithNoBackgroundStillGetsPatchesAndTheConnectGuard()
@Test func editingAnUnpackedBackgroundPageRebuildsItsOverlay()
```

Use a temporary directory and a fixture manifest; never touch an installed extension.

- [ ] **Step 2: Branch the manifest writer**

- `background.service_worker`: keep today's `zigzag-entry.js`/`importScripts` path.
- `background.page`: leave the key; copy the HTML into the overlay and insert one `<script src="/zigzag-prelude.js" data-zigzag-prelude="1"></script>` before the first script. Do not inline JS; preserve CSP, script order and the document URL.
- `background.scripts`: set `["zigzag-prelude.js"] + scripts`; preserve the original order and dedupe.
- No background: write the manifest, permissions and ConnectGuard and return true; patches and language fill must still apply.

- [ ] **Step 3: Keep the lifecycle honest**

`backgroundPrelude(keepsAlive:)` includes keepalive only for a service worker or a persistent MV2 page. An MV2 event page (`persistent: false`) must be allowed to suspend. The WebSocket stand-in remains service-worker-only; a background page has real WebSockets.

Add `overlayFormatVersion` and the background manifest/page digest to `overlaySignature`, so an older marker or an edited background page rebuilds once. Do not include claim text in the signature.

- [ ] **Step 4: Run and commit**

```bash
xcodegen generate
TEST_RUNNER_ZIGZAG_TEST_VAULT=memory xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag \
  -only-testing:ZigzagTests/ExtensionOverlayTests
git add Zigzag/Extensions/ExtensionStore.swift ZigzagTests/ExtensionOverlayTests.swift \
  Zigzag.xcodeproj/project.pbxproj
git commit -m "MV2 backgrounds get the prelude without breaking their lifecycle"
```

---

### Task 8: Honest contexts

**Files:**
- Modify: `Zigzag/Extensions/BridgeNamespaces.swift`
- Modify: `Zigzag/Resources/Extensions/bridge.js`
- Modify: `Zigzag/Resources/Extensions/webkit-differences.js`
- Modify: `ZigzagTests/ExtensionBridgeTests.swift`
- Modify: `ZigzagTests/ExtensionScriptTests.swift`
- Modify: `Zigzag/Resources/Extensions/compatibility.json`

**Interfaces:**
- Produces: `ContextType`, `Context`, `ContextFilter`, `BridgeContexts.matching(_:filter:)`.
- Produces: `getContexts` MV3-only (bridge installs it only for MV3) and `getBackgroundPage` Chrome-shaped errors.

- [ ] **Step 1: Write the failing context tests**

```swift
@Test func backgroundWorkerHasNoDocumentFields()
@Test func mv2BackgroundPageUsesItsGeneratedPage()
@Test func anExtensionWithoutBackgroundHasNoBackgroundContext()
@Test func filtersMatchEveryChromeField()
@Test func filtersMatchAbsentDocumentFieldsAsEmpty()
@Test func contextIdsAreStableAcrossCalls()
@Test func documentIdsAreNotInvented()
@Test func aPopupKeepsItsQueryString()
```

Extend `ExtensionContextsTests`; keep the side-panel tests that still describe real behaviour.

- [ ] **Step 2: Model the contexts**

```swift
nonisolated struct Context {
    var type: ContextType
    var contextID: String
    var documentID: String? = nil
    var documentURL: URL?
    var tabID = -1
    var windowID = -1
    var frameID = 0
    var incognito = false
}

nonisolated struct ContextFilter {
    init(_ object: [String: Any])
    func matches(_ context: Context) -> Bool
}
```

- [ ] **Step 3: Report only what can be named**

- BACKGROUND: emit when `hasBackgroundContent`; MV3 worker has `tabId/windowId/frameId = -1` and no document fields; MV2 page uses its declared `background.page` or `_generated_background_page.html`, `frameId = 0`.
- POPUP and SIDE_PANEL: live URL, including query; stable UUID `contextId` cached by `ObjectIdentifier`.
- OFFSCREEN_DOCUMENT: same, when one is open.
- TAB, DEVELOPER_TOOLS, subframes, `documentId`: leave out and claim as limits; WebKit exposes no Chrome tab/document identity.
- `incognito` is always false because private windows have no extension controller; omit private contexts at the call site.
- Filters: all nine Chrome fields, AND across fields, OR within arrays; an explicit empty array matches nothing; a document filter excludes contexts without that field.
- `documentUrl` and `documentOrigin` use the extension's actual scheme (`webkit-extension://` until the scheme decision). Do not translate them to `chrome-extension://` in this plan.

- [ ] **Step 4: Correct `getBackgroundPage`**

In `webkit-differences.js`'s `afterSurface`:

- MV3 page: reject/callback with `"You do not have a background page."`.
- MV3 worker: leave `getBackgroundPage` absent.
- MV2: convert WebKit's `null` to the same Chrome error; return the page when it exists.

- [ ] **Step 5: Update the claims and run**

Claim `runtime.getContexts` `bridged` with the TAB/developer-tools/documentId limits, and `runtime.getBackgroundPage` `patched` (MV2 only). Run:

```bash
TEST_RUNNER_ZIGZAG_TEST_VAULT=memory xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag \
  -only-testing:ZigzagTests/ExtensionBridgeTests \
  -only-testing:ZigzagTests/ExtensionScriptTests \
  -only-testing:ZigzagTests/ExtensionCompatibilityTests
git add Zigzag/Extensions/BridgeNamespaces.swift Zigzag/Resources/Extensions/bridge.js \
  Zigzag/Resources/Extensions/webkit-differences.js Zigzag/Resources/Extensions/compatibility.json \
  ZigzagTests/ExtensionBridgeTests.swift ZigzagTests/ExtensionScriptTests.swift
git commit -m "getContexts and getBackgroundPage answer as Chrome does, or say why they cannot"
```

---

### Task 9: Full gate and pull request

**Files:**
- No source changes unless the gate exposes one.

- [ ] **Step 1: Regenerate and run the full gate**

```bash
xcodegen generate
TEST_RUNNER_ZIGZAG_TEST_VAULT=memory xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag 2>&1 | tail -30
```

Expected: everything passes except the known headless `SettingsLayoutTests` failure recorded in Task 0. If another suite fails, fix it before continuing.

- [ ] **Step 2: Commit the regenerated project if it changed**

```bash
git add Zigzag.xcodeproj/project.pbxproj
git commit -m "The project lists the truth-layer files"
```

- [ ] **Step 3: Push and open one PR**

```bash
git push -u fork feat/extension-truth
gh pr create --repo ZigaoWang/zigzag --base main --head Lakeland97:feat/extension-truth \
  --title "The extension compatibility framework tells the truth" --body-file <body>
```

The body is code and explanation only: the generated universe, the claim overlay, honest callback failures, the claims-driven install sheet, MV2 prelude parity and honest contexts. No changelog, test counts, CI reports or checklists.

---

## Self-Review

**Spec coverage**

- Generated universe + claim overlay: Tasks 1–3.
- Chrome-shaped failure: Tasks 4–5.
- Install report from claims: Task 6.
- MV2 prelude parity: Task 7.
- `getContexts` / `getBackgroundPage`: Task 8.
- Tests keep universe, claims, surface and report in step: Tasks 2, 3, 4, 6, 8.
- No new per-extension shims: Global Constraints; Task 5 only classifies existing stubs.
- Private windows and permissions untouched: Global Constraints; Task 8 omits private contexts.

**Type consistency**

- `CompatibilityLimit.text` is used by Task 6.
- `ExtensionCompatibility.shared.limits(forPermissions:manifestKeys:)` is produced in Task 3 and consumed in Task 6.
- `ChromeUniverse` is produced in Task 1 and consumed in Tasks 2 and 3.
- `overlaySignature` and `writeOverlayManifest` are produced in Task 7 and used only there.

**Review Focus tests**

- Claim grants: Task 3 permission tests; overlay is never read by `ExtensionBridge.allows`.
- Partial namespace overclaim: Tasks 2 and 3.
- `lastError` leakage: Task 4.
- MV2 identity/CSP: Task 7.
- Private contexts: Task 8.
- Report regressions: Task 6.
