import AppKit
import WebKit

/// What a ⇧-click does: nothing new (`off`), or a Mini docked over the page that closes on a tab switch
/// (`close`), or the same with the old setting's name (`keep`). One Peek per window either way; `keep` is kept so an
/// older build's setting still turns the Peek on, not a second lifecycle.
enum MiniPeekMode: String, CaseIterable {
    case off, close, keep
}

/// The one switch for the docked Peek. It lives in `UserDefaults` with no Settings UI, so a build can turn it on
/// without a second build; absence means `off`, today's standalone Mini.
enum MiniPeekSettings {
    static let key = "MiniPeekMode"
    /// Injectable, so tests never write the settings of the build they run in.
    static var defaults: UserDefaults = .standard

    static var mode: MiniPeekMode {
        get { mode(in: defaults) }
        set { setMode(newValue, in: defaults) }
    }

    static func mode(in defaults: UserDefaults) -> MiniPeekMode {
        MiniPeekMode(rawValue: defaults.string(forKey: key) ?? "") ?? .off
    }

    static func setMode(_ mode: MiniPeekMode, in defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: key)
    }
}

/// What opening a Peek does with the keyboard: the first open takes it, a re-show leaves it where it was.
enum MiniPeekFocus {
    case takesKeyboard, leavesKeyboard
}

/// The Peek's rules, kept pure: when a window can hold one, when its host tab is the one on screen, and when leaving
/// the page or changing Space ends it.
enum MiniPeekPolicy {
    /// A Peek opens only over a window the person is in: key, visible, not minimized, and on the Space in front.
    static func shouldDock(mode: MiniPeekMode, windowIsKey: Bool, windowIsVisible: Bool,
                           windowIsMiniaturized: Bool, windowIsOnActiveSpace: Bool) -> Bool {
        mode != .off && windowIsKey && windowIsVisible && !windowIsMiniaturized && windowIsOnActiveSpace
    }

    /// A Peek belongs to its host tab: it shows only while that tab is the window's selected tab.
    static func isVisible(hostTabID: UUID?, selectedTabID: UUID?) -> Bool {
        guard let hostTabID, let selectedTabID else { return false }
        return hostTabID == selectedTabID
    }

    /// The old Peek's rule: a selection change ends it. `keep` is the old setting's name, not a second rule now.
    static func closesOnSelectionChange(mode: MiniPeekMode) -> Bool { mode != .off }

    /// A real Space change ends the old Peek. The Space change that comes with entering or leaving full screen is the
    /// transition's, not the person's.
    static func spaceChangeCloses(mode: MiniPeekMode, phase: FullScreenPhase) -> Bool {
        mode != .off && !phase.isMoving
    }
}

/// The one Peek a browser window owns: one Mini and one content page, over the host tab it opened from. A second
/// ⇧-click replaces it, as the old Peek did; there is no per-tab record and no dormant window.
@MainActor
final class MiniPeekHost {
    enum Content {
        case url(Tab)

        var tab: Tab {
            switch self {
            case .url(let tab): tab
            }
        }
    }

    struct Record {
        let hostTabID: UUID
        let content: Content
        let controller: MiniWindowController
        /// The one Peek is on screen while it exists, as the old Peek was.
        var isShown: Bool { true }
    }

    weak var browser: BrowserWindowController?
    private(set) var record: Record?

    /// The Mini the window is showing, if one is open.
    var shown: MiniWindowController? { record?.controller }
    /// The one Peek, keyed by its host tab, for the debug bridge and the tests.
    var records: [UUID: Record] { record.map { [$0.hostTabID: $0] } ?? [:] }
    /// The one switch, read at each decision. Tests inject it; production reads `MiniPeekSettings.mode`.
    var modeProvider: () -> MiniPeekMode = { MiniPeekSettings.mode }
    /// App activation, the window's deminiaturize, and the active Space's changes: the host re-docks or closes.
    private var appTokens: [NSObjectProtocol] = []
    private var spaceTokens: [NSObjectProtocol] = []
    private var isObserving = false
    /// Entering or leaving full screen changes Space as it goes: that one is the transition's, not the person's.
    private var isFullScreenTransitioning = false

    private var mode: MiniPeekMode { modeProvider() }

    /// A URL Peek in `opener`'s tab: a Mini of its own, docked over that tab's page. False when the window cannot hold
    /// one now; the caller falls back to the standalone Mini.
    @discardableResult
    func openURL(url: URL?, configuration: WKWebViewConfiguration?, opener: Tab?, by sender: Tab.LoadSender) -> Bool {
        guard mode != .off, let browser, browser.window != nil,
              let host = opener ?? browser.tabManager.selectedTab,
              Self.pane(of: browser) != nil else { return false }
        startObserving()
        // One Peek per window: a second ⇧-click replaces the first, even from another tab.
        closeShown(animated: false)
        let controller = MiniWindowController.open(fromPage: url, configuration: configuration, opener: host,
                                                   in: browser, by: sender, dockedIn: browser)
        guard controller.isDockedPeek else {
            controller.window?.close()
            return false
        }
        record(host: host, content: .url(controller.tab), controller: controller)
        return true
    }

    /// Before the new page draws: a Peek from another tab or Space goes first, with its dim, so the new page is never
    /// shown under it. The old Peek's rule, for every mode now.
    func willSelect(_ tab: Tab?) {
        guard mode != .off else {
            windowClosing()
            return
        }
        guard let record, record.hostTabID != tab?.id else { return }
        close(record, animated: false)
    }

    /// The page moved or resized under the Peek: it re-fits; no viewport change detaches.
    func browserLayoutChanged() {
        guard mode != .off, let record else { return }
        record.controller.dockLayoutChanged()
    }

    /// The tab list changed: a host or content tab that closed, or moved to another window, ends the Peek.
    func tabsChanged() {
        guard let browser, let record else { return }
        let host = browser.tabManager.tab(with: record.hostTabID)
        if host == nil || host?.shownBy !== browser.tabManager || record.content.tab.isClosed {
            close(record, animated: false)
        }
    }

    /// The mode changed at runtime: off and close both end the one Peek; `keep` is the same rule now.
    func modeChanged() {
        closeShown(animated: false)
    }

    /// The window is going: the page goes with it.
    func windowClosing() {
        closeShown(animated: false)
        stopObserving()
    }

    /// Full screen moving: the transition's Space change is not the person's, so re-dock once it lands.
    func fullScreenChanged(_ phase: FullScreenPhase) {
        switch phase {
        case .entering, .exiting:
            isFullScreenTransitioning = true
        case .fullScreen, .windowed:
            isFullScreenTransitioning = false
            redockShown()
        }
    }

    /// The Space in front changed. The old Peek ends when its browser is left behind; a transition's own Space change
    /// is ignored.
    private func activeSpaceChanged() {
        guard !isFullScreenTransitioning, let browser, let window = browser.window else { return }
        if window.isOnActiveSpace {
            redockShown()
        } else if MiniPeekPolicy.spaceChangeCloses(mode: mode, phase: browser.browserWindow.fullScreenPhase) {
            closeShown(animated: false)
        }
    }

    /// Zigzag came back. The Peek was behind its window all along: put it back on the page, no refade.
    private func appBecameActive() {
        guard let browser, browser.window?.isOnActiveSpace == true else { return }
        redockShown()
    }

    /// Puts the one Peek back at the page's current frame.
    private func redockShown() {
        guard mode != .off, let record else { return }
        record.controller.redock()
    }

    private func startObserving() {
        guard !isObserving, let browser, let window = browser.window else { return }
        isObserving = true
        appTokens = [
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appBecameActive() }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification,
                                                   object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.redockShown() }
            },
        ]
        spaceTokens = [
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.activeSpaceChanged() }
            },
        ]
    }

    private func stopObserving() {
        appTokens.forEach(NotificationCenter.default.removeObserver)
        appTokens = []
        spaceTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        spaceTokens = []
        isObserving = false
    }

    /// Closes the one Peek, key or not, as ⌘W, the command bar, or the debug bridge asks.
    @discardableResult
    func closeShown(animated: Bool = true) -> Bool {
        guard let record else { return false }
        close(record, animated: animated)
        return true
    }

    /// Keeps the one Peek, as ⌘O does.
    func keepShown() {
        record?.controller.openInZigzag()
    }

    /// Esc reaching the browser first: the embedded Peek has no window of its own to be key, so it always goes.
    /// The monitor that calls this has already checked the event belongs to this browser window.
    func escapePressed() -> Bool {
        guard mode != .off, record != nil else { return false }
        return closeShown(animated: true)
    }

    private func record(host: Tab, content: Content, controller: MiniWindowController) {
        controller.peekHostTab = host
        controller.onPeekClosed = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.remove(controller)
        }
        controller.onPeekDetached = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.remove(controller)
        }
        record = Record(hostTabID: host.id, content: content, controller: controller)
    }

    private func remove(_ controller: MiniWindowController) {
        guard record?.controller === controller else { return }
        record = nil
    }

    private func close(_ record: Record, animated: Bool) {
        if self.record?.controller === record.controller { self.record = nil }
        if record.controller.isDockedPeek {
            record.controller.closePeek(focusBack: false, animated: animated)
        } else if record.controller.holdsPage {
            record.controller.window?.close()
        }
    }

    /// The page card's frame on screen: the whole split/tile area, after the sidebar and top bar.
    static func pane(of browser: BrowserWindowController) -> NSRect? {
        guard let window = browser.window else { return nil }
        let pane = window.convertToScreen(browser.root.convert(browser.root.cardFrame, to: nil))
        guard pane.width > 1, pane.height > 1 else { return nil }
        return pane
    }

    #if DEBUG
    /// `minipeekstate`: the one Peek this window owns, with the Mini's own state inside.
    var debugState: [[String: Any]] {
        func rect(_ r: NSRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }
        guard let record else { return [] }
        let frame = record.controller.window?.frame ?? .zero
        let pane = record.controller.debugDockPane ?? .zero
        return [["hostTab": record.hostTabID.uuidString, "contentTab": record.content.tab.id.uuidString,
                 "borrowed": false, "shown": true, "suspended": false,
                 "frame": rect(frame), "pane": rect(pane), "mini": record.controller.debugState]]
    }
    #endif
}
