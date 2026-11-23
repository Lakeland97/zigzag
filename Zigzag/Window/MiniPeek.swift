import AppKit
import WebKit

/// What a ⇧-click does: nothing new (`off`), or a Mini docked over the page that either closes on a tab switch
/// (`close`, the old Peek) or stays with its tab (`keep`).
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

/// What opening or re-showing a Peek does with the keyboard. The first open takes it; a tab switch back leaves it
/// where the switch put it.
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

    /// The old Peek's A/B: `close` puts every other record away when the selection changes; `keep` leaves them
    /// dormant for their tab.
    static func closesOnSelectionChange(mode: MiniPeekMode) -> Bool { mode == .close }

    /// Any part of the Mini outside the page takes it out of the page. A re-fit while the page changes size is not
    /// the person moving it, so it never detaches.
    static func detaches(frame: NSRect, viewport: NSRect, isAdjusting: Bool) -> Bool {
        !isAdjusting && !viewport.contains(frame)
    }

    /// A real Space change ends the old Peek's record. The Space change that comes with entering or leaving full
    /// screen is the transition's, not the person's.
    static func spaceChangeCloses(mode: MiniPeekMode, phase: FullScreenPhase) -> Bool {
        mode == .close && !phase.isMoving
    }
}

/// The Peeks one browser window owns: at most one per host tab, each with its own Mini and content page. The host
/// tab is the viewport the Peek is shown over; the content is the page it shows, a URL of its own or a tab lent to it.
@MainActor
final class MiniPeekHost {
    enum Content {
        case url(Tab)
        case borrowed(Tab)

        var tab: Tab {
            switch self {
            case .url(let tab), .borrowed(let tab): tab
            }
        }
    }

    struct Record {
        let hostTabID: UUID
        let content: Content
        let controller: MiniWindowController
        var isShown: Bool
        /// A borrowed page is back in its own tab while the record is hidden.
        var isSuspended: Bool
        var lastFrame: NSRect
        var lastPane: NSRect
    }

    weak var browser: BrowserWindowController?
    private(set) var records: [UUID: Record] = [:]
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
              let pane = Self.pane(of: browser) else { return false }
        startObserving()
        close(hostTabID: host.id, animated: false)
        let controller = MiniWindowController.open(fromPage: url, configuration: configuration, opener: host,
                                                   in: browser, by: sender, dockedIn: browser)
        guard controller.isDockedPeek else {
            controller.window?.close()
            return false
        }
        record(host: host, content: .url(controller.tab), controller: controller, pane: pane)
        return true
    }

    /// A tab or pinned page lent to `host`'s viewport. The page stays a tab; the record's close returns it.
    @discardableResult
    func openBorrowed(_ content: Tab, host: Tab) -> Bool {
        guard mode != .off, let browser, browser.window != nil, !browser.tabManager.isPrivate,
              !content.isClosed, let url = content.url, !HistoryPage.isInternal(url),
              let pane = Self.pane(of: browser) else { return false }
        startObserving()
        // ⇧-clicking the tab the window is already on has nothing to lend.
        guard content !== host else { return true }
        // A page can only be in one Peek: another record holding it goes first.
        for id in records.filter({ $0.value.content.tab === content }).map(\.key) {
            close(hostTabID: id, animated: false)
        }
        close(hostTabID: host.id, animated: false)
        _ = content.ensureWebView()
        guard content.pageHolder != nil else { return false }
        let controller = MiniWindowController.open(borrowing: content, from: browser, dockedIn: browser)
        guard controller.isDockedPeek else {
            controller.window?.close()
            return false
        }
        record(host: host, content: .borrowed(content), controller: controller, pane: pane)
        return true
    }

    /// Puts `new` in place of a record that is going away. The caller closes the old controller.
    func replace(_ record: Record, with new: Record) {
        guard records[record.hostTabID]?.controller === record.controller else { return }
        records[record.hostTabID] = new
    }

    /// Before the new page draws: the outgoing Peek's dim must be gone, and under `close` its record too.
    func willSelect(_ tab: Tab?) {
        guard mode != .off else {
            windowClosing()
            return
        }
        switch mode {
        case .off:
            windowClosing()
        case .close:
            for id in Array(records.keys) where id != tab?.id { close(hostTabID: id, animated: false) }
        case .keep:
            for id in Array(records.keys) where id != tab?.id {
                guard var record = records[id], record.isShown else { continue }
                record.lastFrame = record.controller.window?.frame ?? record.lastFrame
                record.lastPane = browser.flatMap { Self.pane(of: $0) } ?? record.lastPane
                switch record.content {
                case .url:
                    record.controller.hideDock()
                case .borrowed:
                    // The page goes back to its tab while the record waits: no blank tab, no reload on return.
                    record.controller.suspendDock()
                    record.isSuspended = true
                    record.controller.isPeekSuspended = true
                }
                record.isShown = false
                records[id] = record
            }
        }
    }

    /// After the new page is in its card: the new selected tab's record comes back, without taking the keyboard.
    func didSelect(_ tab: Tab?) {
        guard mode == .keep, let tab, var record = records[tab.id], !record.isShown else { return }
        switch record.content {
        case .url:
            record.controller.showDock(focus: .leavesKeyboard)
        case .borrowed:
            record.controller.resumeDock(focus: .leavesKeyboard)
            record.controller.isPeekSuspended = false
        }
        record.isShown = true
        record.isSuspended = false
        record.lastFrame = record.controller.window?.frame ?? record.lastFrame
        if let browser, let pane = Self.pane(of: browser) { record.lastPane = pane }
        records[tab.id] = record
    }

    /// The page moved or resized under the Peek: the shown ones re-fit; no viewport change detaches.
    func browserLayoutChanged() {
        guard mode != .off else { return }
        for record in records.values where record.isShown { record.controller.dockLayoutChanged() }
    }

    /// The tab list changed: a host or content tab that closed, or moved to another window, ends its record.
    func tabsChanged() {
        guard let browser else { return }
        for (id, record) in records {
            let host = browser.tabManager.tab(with: id)
            if host == nil || host?.shownBy !== browser.tabManager || record.content.tab.isClosed {
                close(hostTabID: id, animated: false)
            }
        }
    }

    /// The mode changed at runtime: off is the kill switch, close drops the dormant records, keep leaves them.
    func modeChanged() {
        switch mode {
        case .off:
            windowClosing()
        case .close:
            for (id, record) in Array(records) where !record.isShown { close(hostTabID: id, animated: false) }
        case .keep:
            break
        }
    }

    /// The window is going: every page goes back or closes with it.
    func windowClosing() {
        for id in Array(records.keys) { close(hostTabID: id, animated: false) }
        stopObserving()
    }

    /// Full screen moving: remember the transition's Space change, then re-dock once it lands. A failed transition is
    /// the windowed state and re-docks too.
    func fullScreenChanged(_ phase: FullScreenPhase) {
        switch phase {
        case .entering, .exiting:
            isFullScreenTransitioning = true
        case .fullScreen, .windowed:
            isFullScreenTransitioning = false
            redockShown()
        }
    }

    /// The Space in front changed. Under `keep` records stay and come back on their desktop; under `close` the old
    /// Peek goes when its browser is left behind. The transition's own Space change is ignored.
    private func activeSpaceChanged() {
        guard !isFullScreenTransitioning, let browser, let window = browser.window else { return }
        if window.isOnActiveSpace {
            redockShown()
        } else if MiniPeekPolicy.spaceChangeCloses(mode: mode, phase: browser.browserWindow.fullScreenPhase) {
            for (id, record) in Array(records) where record.isShown { close(hostTabID: id, animated: false) }
        }
    }

    /// Zigzag came back. The Peek was behind its window all along: put it back on the page, no refade.
    private func appBecameActive() {
        guard let browser, browser.window?.isOnActiveSpace == true else { return }
        redockShown()
    }

    /// Puts every shown Peek back as the browser's child at the page's current frame. Hidden records stay hidden.
    private func redockShown() {
        guard mode != .off else { return }
        for record in records.values where record.isShown { record.controller.redock() }
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
        appTokens.forEach { NotificationCenter.default.removeObserver($0) }
        appTokens = []
        spaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        spaceTokens = []
        isObserving = false
    }

    func close(hostTabID: UUID, animated: Bool) {
        guard let record = records.removeValue(forKey: hostTabID) else { return }
        if record.controller.isDockedPeek {
            record.controller.closePeek(focusBack: false, animated: animated)
        } else if record.controller.holdsPage {
            record.controller.window?.close()
        }
    }

    /// ⌘O: a URL Peek becomes a tab; a borrowed page returns to its tab. The controller closes and tells the host.
    func keep(hostTabID: UUID) {
        records[hostTabID]?.controller.openInZigzag()
    }

    /// The one record on screen: only the selected host tab's Peek is shown.
    var shown: Record? { records.values.first { $0.isShown } }

    /// Closes whatever Peek is on screen, key or not, as ⌘W or the debug bridge asks.
    func closeShown(animated: Bool = true) {
        guard let shown else { return }
        close(hostTabID: shown.hostTabID, animated: animated)
    }

    /// Keeps whatever Peek is on screen, as ⌘O does.
    func keepShown() {
        guard let shown else { return }
        keep(hostTabID: shown.hostTabID)
    }

    /// Esc reaching the browser first: the shown Peek, left visible but not key by a tab switch, still goes.
    /// The monitor that calls this has already checked the event belongs to this browser window.
    func escapePressed() -> Bool {
        guard mode != .off,
              let shown = records.values.first(where: { $0.isShown }),
              shown.controller.window?.isKeyWindow != true else { return false }
        close(hostTabID: shown.hostTabID, animated: true)
        return true
    }

    /// The person dragged the Peek out of the page. Per-tab ownership ends; the Mini lives on as it is.
    func detach(_ controller: MiniWindowController) {
        remove(controller)
    }

    private func record(host: Tab, content: Content, controller: MiniWindowController, pane: NSRect) {
        controller.peekHostTab = host
        controller.onPeekClosed = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.remove(controller)
        }
        controller.onPeekDetached = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.remove(controller)
        }
        records[host.id] = Record(hostTabID: host.id, content: content, controller: controller, isShown: true,
                                  isSuspended: false, lastFrame: controller.window?.frame ?? .zero, lastPane: pane)
    }

    private func remove(_ controller: MiniWindowController) {
        guard let id = records.first(where: { $0.value.controller === controller })?.key else { return }
        records[id] = nil
    }

    /// The page card's frame on screen: the whole split/tile area, after the sidebar and top bar.
    static func pane(of browser: BrowserWindowController) -> NSRect? {
        guard let window = browser.window else { return nil }
        let pane = window.convertToScreen(browser.root.convert(browser.root.cardFrame, to: nil))
        guard pane.width > 1, pane.height > 1 else { return nil }
        return pane
    }

    #if DEBUG
    /// `minipeekstate`: every record this window owns, with the Mini's own state inside.
    var debugState: [[String: Any]] {
        func rect(_ r: NSRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }
        return records.values.map { record in
            let frame = record.controller.window?.frame ?? .zero
            let pane = record.controller.debugDockPane ?? record.lastPane
            let borrowed: Bool
            if case .borrowed = record.content { borrowed = true } else { borrowed = false }
            return ["hostTab": record.hostTabID.uuidString, "contentTab": record.content.tab.id.uuidString,
                    "borrowed": borrowed, "shown": record.isShown, "suspended": record.isSuspended,
                    "frame": rect(frame), "pane": rect(pane), "mini": record.controller.debugState]
        }
    }
    #endif
}
