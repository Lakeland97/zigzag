# Firefox Extension Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Firefox WebExtensions (`.xpi`) at the same framework level as Chrome extensions: install, import, a Promise `browser.*` facade, a Firefox API universe and claims overlay, and honest install-sheet lines.

**Architecture:** One package pipeline with a recorded `kind`. An XPI is read with the existing `PackageZip`, its Firefox manifest normalized once at extract time, and the existing overlay writer injects the prelude. A per-package `firefox-polyfill.js` wraps the finished `chrome` surface in Promises. A second generated universe and claim overlay use the existing model and validator.

**Tech Stack:** Swift 6 (MainActor by default), WebKit's `WKWebExtension`, JavaScriptCore for surface tests, Python 3 for the universe generator, `@types/firefox-webext-browser` 143.0.1.

**Spec:** `docs/superpowers/specs/2026-11-18-firefox-extension-support-design.md`

## Global Constraints

- Branch `feat/firefox-extensions` is stacked on PR A of the Chrome truth layer; do not open its PR until the five current PRs are merged.
- Swift 6, default actor isolation MainActor, deployment target macOS 15.4.
- No per-extension shims, IDs, or branches.
- The claims overlay is report-only: never grants a permission, never widens site access, never writes state.
- A `partial` permission row adds no install-sheet line (PR A's rule); only `unsupported`/`deprecated` rows do, plus raw names for unclaimed permissions.
- No English prose in either JSON; catalog keys only. Every key has `en` and `zh-Hans` values, following `docs/i18n/glossary.md`.
- Do not edit `Zigzag.xcodeproj/project.pbxproj` in a task; integration regenerates once.
- No push, no PR, no subagents inside a task.
- Commit identity `Lakeland97 <mcshadowuniverse@gmail.com>`; no vendor or co-author trailers.

## Review Focus

- An XPI whose `manifest.json` is not at the root, or whose entries escape the folder: must be refused without writing outside the staging folder.
- A Firefox MV3 package with `background.scripts`: script order must be preserved and the generated worker must load the prelude before any of them.
- A Firefox extension calling `browser.*` with an argument a Chrome API would reject: the Promise must reject with `{message}`, not hang or return `undefined`.
- The same gecko ID installed twice, or an XPI replaced on disk: one record, one data store, no duplicate rows — and a different gecko ID is a different extension.
- An extension that feature-detects `browser` or `storage.local.setAccessLevel`: a Firefox package gets the facade, a Chrome package does not; an absent storage member stays `undefined`.
- Chinese install-sheet text must never be lowercased at sentence joins; an English-only rule must not leak into `zh-Hans`.

---

### Task 1: Firefox API universe and generator

**Files:**
- Create: `scripts/firefox-api.py`
- Create: `Zigzag/Resources/Extensions/firefox-api.json`
- Test: `ZigzagTests/FirefoxUniverseTests.swift`

**Interfaces:**
- Produces: the JSON shape `chrome-api.json` already has — `{ "<namespace>": { "constants": {}, "enums": {}, "events": {}, "functions": {} } }` — for [API surface task] to point `api-surface.js` at.
- Produces: `FIREFOX_TYPES_VERSION = "143.0.1"` in the script, and `--check` comparing a regenerated document with the committed one.

- [ ] **Step 1: Write the failing test**

`FirefoxUniverseTests` (one test, mirroring `ChromeUniverseTests`):
- `firefox-api.json` parses and has at least 100 namespaces.
- `storage` has `local`, `sync`, `session` areas (objects), each with `get`/`set` functions.
- `runtime.functions` contains `getBrowserInfo` and `getPlatformInfo`.
- `sidebarAction` exists; `_manifest` does not.
- No key begins with `browser.`.

- [ ] **Step 2: Run it and see it fail**

Run: `ZZ_REPO=$PWD ZZ_REBUILD=1 <runner> FirefoxUniverseTests`
Expected: FAIL because `firefox-api.json` does not exist.

- [ ] **Step 3: Write `scripts/firefox-api.py`**

Mirror `scripts/chrome-api.py`'s download/pin/`--check`/error style, but parse the Firefox grammar: top-level `declare namespace browser.<ns> {` blocks; `function name(...)`; `const NAME: type`; `WebExtEvent<...>` members as events; `interface StorageArea` methods as the `storage` area objects. Skip `browser._manifest`. Derive enum value names the way `enum_key` does. Download the pinned tarball and read `firefox-webext-browser/index.d.ts`. `--check` regenerates in memory and names the first differing path.

- [ ] **Step 4: Generate and run the test**

Run: `python3 scripts/firefox-api.py` then the test command from Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

`The Firefox API universe is generated and checked`

---

### Task 2: XPI package

**Files:**
- Create: `Zigzag/Extensions/XPIPackage.swift`
- Test: `ZigzagTests/XPIPackageTests.swift`

**Interfaces:**
- Produces:
```swift
nonisolated struct XPIPackage {
    enum Failure: Error, Equatable { case missingManifest, manifestNotAtRoot, unsafeName(String), tooLarge, damaged }
    let manifest: [String: Any]
    let firefoxID: String?
    let hasSignature: Bool
    init(_ data: Data) throws
    func unpack(into folder: URL) throws
}
```
- Consumes: `PackageZip.entries(_:)`, `PackageZip.unpack(_:into:)`, `PackageZip.safePath(_:)`.

- [ ] **Step 1: Write the failing tests**

`XPIPackageTests`:
- a minimal XPI (built with the test zip helper that `CRXPackageTests` already uses, or a tiny builder added there) yields its manifest and `hasSignature == false`;
- `browser_specific_settings.gecko.id` is read; the legacy `applications.gecko.id` is read too;
- a package with `META-INF/mozilla.rsa` has `hasSignature == true`;
- a zip with no root `manifest.json` fails `.missingManifest`; one whose manifest is under a folder fails `.manifestNotAtRoot`;
- a traversal entry fails with `.unsafeName`.

- [ ] **Step 2: Run and see them fail**

Expected: FAIL, `XPIPackage` is undefined.

- [ ] **Step 3: Implement `XPIPackage`**

Read entries with `PackageZip`; require exactly one root `manifest.json`; decode it as `[String: Any]`; `firefoxID` reads `browser_specific_settings.gecko.id`, then `applications.gecko.id`; `hasSignature` checks for `META-INF/mozilla.rsa`; `unpack` delegates to `PackageZip.unpack` and never writes to the source.

- [ ] **Step 4: Run the tests**

Expected: PASS.

- [ ] **Step 5: Commit**

`An XPI is read and unpacked with the package rules`

---

### Task 3: Firefox manifest normalization

**Files:**
- Create: `Zigzag/Extensions/FirefoxManifest.swift`
- Test: `ZigzagTests/FirefoxManifestTests.swift`

**Interfaces:**
- Produces:
```swift
nonisolated enum FirefoxManifest {
    static func firefoxID(_ manifest: [String: Any]) -> String?
    static func normalized(_ manifest: [String: Any]) -> [String: Any]
    static func workerSource(scripts: [String]) -> String
}
```

- [ ] **Step 1: Write the failing tests**

`FirefoxManifestTests`:
- MV3 with `background.scripts: ["a.js", "b.js"]` gains `background.service_worker == "zigzag-firefox-worker.js"`, keeps the scripts key, and `workerSource` is `importScripts("a.js", "b.js");` in order, escaping quotes.
- MV2 with `background.scripts` is unchanged.
- `sidebar_action` with `default_panel` gains `side_panel.default_path` and keeps `default_title`/`default_icon`.
- MV3 host patterns in `permissions` move to `host_permissions`; API names stay; the same for optional.
- MV3 string CSP becomes `{extension_pages: ...}`; MV2 is unchanged.
- MV2 string `web_accessible_resources` become MV3 objects; MV3 is unchanged.
- Normalizing twice is idempotent, and the input dictionary is not mutated.

- [ ] **Step 2: Run and see them fail**

Expected: FAIL, `FirefoxManifest` is undefined.

- [ ] **Step 3: Implement `FirefoxManifest`**

Value-type transforms on copies. A host pattern is a string containing `://` or equal to `<all_urls>`; API permissions stay. Side panel mapping reads `default_panel` (string). Do not touch `browser_specific_settings`.

- [ ] **Step 4: Run the tests**

Expected: PASS.

- [ ] **Step 5: Commit**

`A Firefox manifest is normalized for WebKit once`

---

### Task 4: Store kind and XPI install

**Files:**
- Modify: `Zigzag/Extensions/ExtensionStore.swift` (`Package`, `PreparedInstall`, install paths, overlay prelude)
- Modify: `Zigzag/Extensions/ExtensionReport.swift` (kind)
- Test: `ZigzagTests/FirefoxInstallTests.swift`

**Interfaces:**
- Produces: `enum ExtensionKind: String, Codable, Sendable { case chromium, firefox }`.
- Produces: `Package.kind: String` (default `"chromium"` when absent), `Package.firefoxID: String?`.
- Produces: `static func prepareInstallXPI(at: URL) async -> Result<PreparedInstall, InstallError>` and `static func installXPI(at: URL, in: Profile) async -> Result<String, InstallError>`.
- Produces: `PreparedInstall.kind: ExtensionKind`; `ExtensionReport(extension:manifest:id:kind:)` (in this task the kind only selects the existing Chrome overlay; Task 6 adds the Firefox overlay and wording).
- Consumes: `XPIPackage`, `FirefoxManifest`, `PackageZip`, `WKWebExtension`.

- [ ] **Step 1: Write the failing tests**

`FirefoxInstallTests` (use a temp profile and an XPI fixture):
- installing an XPI records `kind == "firefox"`, the gecko ID, and a 32-character opaque ID (`a...p` alphabet);
- two XPIs with the same gecko ID produce one record; reinstall replaces the version;
- a Chrome/unpacked record with no `kind` reads as `"chromium"`;
- an XPI whose manifest WebKit cannot read fails `.unsupported`, and its staging folder is removed;
- the normalized manifest on disk has the generated worker for MV3 scripts.

- [ ] **Step 2: Run and see them fail**

Expected: FAIL, `installXPI` is undefined.

- [ ] **Step 3: Implement**

`prepareInstallXPI`: read `XPIPackage`, compute the opaque ID (gecko ID hashed with SHA-256 to 32 chars when present, else the file path hash), extract to staging, write `FirefoxManifest.normalized`, verify with `WKWebExtension(resourceBaseURL:)`, and return a `PreparedInstall` with `kind .firefox` and its report. `finishInstall` saves `Package(version:kind:firefoxID:)`, preserving an existing record's kind when it is absent. Write the polyfill later; the prelude composition here only needs to know the kind.

- [ ] **Step 4: Run the tests**

Expected: PASS.

- [ ] **Step 5: Commit**

`A Firefox package keeps its kind, ID and manifest through install`

---

### Task 5: Promise `browser.*` facade

**Files:**
- Create: `Zigzag/Resources/Extensions/firefox-polyfill.js`
- Modify: `Zigzag/Extensions/ExtensionBridge.swift` (load it and append it to `afterCompatibility`)
- Modify: `Zigzag/Extensions/ExtensionStore.swift` (only if the contrast between the two preludes needs a comment; no code path change)
- Test: `ZigzagTests/FirefoxSurfaceTests.swift`

**Interfaces:**
- Produces: `ExtensionBridgeScript.firefoxPolyfill: String`, appended after the surface in `afterCompatibility`.
- The facade is **self-gated**: it builds `browser` only when `chrome.runtime.getManifest()` carries `browser_specific_settings` or `applications`. The prelude is injected per profile, not per package, so a kind selector cannot be used; the manifest is the package's own signature. A Chrome manifest with neither key gets no `browser` from Zigzag.

- [ ] **Step 1: Write the failing tests** (JavaScriptCore, following `ExtensionScriptTests`)

- `browser.tabs.query({})` returns a Promise and resolves with the bridge's answer.
- A failing `browser.*` call rejects with an object whose `message` is the bridge's error text.
- `browser.runtime.getManifest()` returns the object directly, not a Promise.
- `browser.runtime.id` is the manifest's gecko ID.
- `browser.runtime.getBrowserInfo()` resolves `{name: "Zigzag", vendor: "Lakeland97"}`; `getPlatformInfo()` resolves `os: "mac"`.
- `browser.runtime.onMessage.addListener(fn)` is the same event object as `chrome.runtime.onMessage`'s and registration works.
- Self-gating: with a manifest carrying `browser_specific_settings`, evaluating the polyfill builds `browser`; with a Chrome-shaped manifest and no Firefox keys, pre-existing `browser` is left exactly as it was.

- [ ] **Step 2: Run and see them fail**

Expected: FAIL, no `browser` facade.

- [ ] **Step 3: Implement `firefox-polyfill.js` and wire it**

Build `browser` lazily over `chrome`; return early unless the manifest has `browser_specific_settings` or `applications`; cache wrappers; the sync list is exactly `runtime.getManifest`, `runtime.getURL`, `runtime.id`, `i18n.getMessage`, `i18n.getUILanguage`, `i18n.getAcceptLanguages`; events (`addListener` and `removeListener`) pass through; missing members stay missing. Rejections normalize to `{message}`. Append the polyfill after the surface in `afterCompatibility`, so every extension page and background gets it; the manifest gate keeps it out of Chrome packages.

- [ ] **Step 4: Run the tests**

Expected: PASS.

- [ ] **Step 5: Commit**

`A Firefox extension gets a Promise browser facade over the same surface`

---

### Task 6: Firefox claims overlay

**Files:**
- Create: `Zigzag/Resources/Extensions/firefox-compatibility.json`
- Modify: `Zigzag/Extensions/ExtensionCompatibility.swift` (`ExtensionKind`, loader, validator wiring)
- Modify: `Zigzag/Extensions/ExtensionReport.swift`, `ExtensionSheet.swift`, `SettingsView.swift`, `ImportExtensionViews.swift` (pass the kind)
- Modify: `Zigzag/Resources/Localizable.xcstrings`
- Test: `ZigzagTests/FirefoxCompatibilityTests.swift`

**Interfaces:**
- Produces: `ExtensionCompatibility.shared(for: .firefox)`; `CompatibilityOverlay.load(kind:)`; the overlay selection inside `ExtensionReport` and the sheet.
- Consumes: `ExtensionKind` from Task 4, the universe from Task 1 and the model/validator from PR A.

- [ ] **Step 1: Write the failing tests**

- the Firefox overlay validates with zero diagnostics against `firefox-api.json`;
- every Firefox permission named in the seeded `permissions` map has a row; supported rows are silent, unsupported rows have one line with a catalog key, and partial rows are silent (PR A's rule);
- `runtime.getBrowserInfo` and `getPlatformInfo` are `emulated` with `js:` implementations;
- `contextualIdentities`, `browserSettings`, `pkcs11`, `dns`, `theme` are `unsupported` with reasons and groups;
- every catalog key has `en` and a `zh-Hans` value;
- a Firefox install sheet for the fixture XPI names its unsupported permissions and does not add lines for `storage`, `tabs` or `menus`;
- a Chrome package still uses `compatibility.json` (cross-check one claim).

- [ ] **Step 2: Run and see them fail**

Expected: FAIL, the overlay is missing.

- [ ] **Step 3: Seed the overlay and thread the kind**

Start from the API matrix: `native` for the namespaces WebKit answers directly; `patched`/`bridged` for the names Zigzag's bridge already answers (`history`, `bookmarks`, `downloads`, `proxy`, `topSites`, `idle`, `userScripts`, `tabCapture` audio); `emulated` for `storage` sync/managed, `getBrowserInfo`, `getPlatformInfo`, the Promise facade; `unsupported` for the list above with reasons/groups; every permission row follows PR A's noise rule. Reuse existing catalog keys where the wording is identical; add Firefox-only keys with en + zh-Hans. Thread `kind` from the record through `ExtensionReport` to the sheet and Settings.

- [ ] **Step 4: Run the tests**

Expected: PASS. Run `ExtensionCompatibilityTests`, `ExtensionSecurityTests`, `LocalizationTests` too.

- [ ] **Step 5: Commit**

`Firefox limits are claimed, and its sheet words them`

---

### Task 7: Import from Firefox and the UI surface

**Files:**
- Create: `Zigzag/Import/FirefoxImporter.swift`
- Modify: `Zigzag/Import/ImportView.swift`, `ImportExtensionViews.swift`, `ImportCoordinator.swift`
- Modify: `Zigzag/Extensions/ExtensionSheet.swift`, `Zigzag/Settings/SettingsView.swift` (kind label, gecko ID)
- Modify: `Zigzag/Resources/Localizable.xcstrings`
- Test: `ZigzagTests/FirefoxImportTests.swift`

**Interfaces:**
- Produces:
```swift
nonisolated enum FirefoxImporter {
    struct Found: Sendable, Hashable { let firefoxID: String?; let name: String; let version: String; let path: URL; var source: String = "" }
    static func profiles() -> [URL]
    static func found() -> [Found]
    static func found(inProfile: URL) -> [Found]
}
```
- Consumes: `XPIPackage`, `ExtensionStore.installXPI`.

- [ ] **Step 1: Write the failing tests**

- a temp profile with `extensions/a@b.xpi` yields one `Found` with its manifest's name/version and gecko ID;
- a non-XPI file and a folder are ignored; a malformed XPI is skipped without throwing;
- two profiles with the same gecko ID yield one entry;
- the import row installs through `installXPI` and the record's kind is `firefox`;
- the extension file picker allows `.xpi` as well as `.crx`/folders;
- a Firefox extension row says "Firefox" and its gecko ID; a Chrome row does not.

- [ ] **Step 2: Run and see them fail**

Expected: FAIL, no Firefox import.

- [ ] **Step 3: Implement the importer and UI**

Scan `~/Library/Application Support/Firefox/Profiles` (each subfolder's `extensions`), read XPIs, sort by name. Add the Firefox section to the Import window beside Chrome/Arc/Safari; each row installs with the same review sheet. Extend the extension-file picker's allowed types. Add the kind label and ID to the Settings row. Localize the new strings in en and zh-Hans.

- [ ] **Step 4: Run the tests**

Expected: PASS. Run `LocalizationTests` too.

- [ ] **Step 5: Commit**

`Firefox extensions import from a profile, and read as Firefox`

---

## Integration (controller, not a task)

- [ ] Regenerate `Zigzag.xcodeproj` once (`xcodegen generate`); revert renderer `Info.plist` churn; commit.
- [ ] Run the full local gate (all default and extension suites) with the two known environment failures only.
- [ ] Whole-branch review on the net diff; one fix wave; one scoped re-review.
- [ ] After the five current PRs merge: rebase onto `main`, regenerate the project, rerun the gate, open one PR with code and explanation only.
