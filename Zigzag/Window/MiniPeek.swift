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

    private var mode: MiniPeekMode { modeProvider() }

    /// A URL Peek in `opener`'s tab: a Mini of its own, docked over that tab's page. False when the window cannot hold
    /// one now; the caller falls back to the standalone Mini.
    @discardableResult
    func openURL(url: URL?, configuration: WKWebViewConfiguration?, opener: Tab?, by sender: Tab.LoadSender) -> Bool {
        guard mode != .off, let browser, browser.window != nil,
              let host = opener ?? browser.tabManager.selectedTab,
              let pane = Self.pane(of: browser) else { return false }
        close(hostTabID: host.id, animated: false)
        let controller = MiniWindowController.open(fromPage: url, configuration: configuration, opener: host,
                                                   in: browser, by: sender, dockedIn: browser)
        guard controller.isDockedPeek else {
            controller.window?.close()
            return false
        }
        record(host: host.id, content: .url(controller.tab), controller: controller, pane: pane)
        return true
    }

    /// A tab or pinned page lent to `host`'s viewport. The page stays a tab; the record's close returns it.
    @discardableResult
    func openBorrowed(_ content: Tab, host: Tab) -> Bool {
        guard mode != .off, let browser, browser.window != nil, !browser.tabManager.isPrivate,
              !content.isClosed, let url = content.url, !HistoryPage.isInternal(url),
              let pane = Self.pane(of: browser) else { return false }
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
        record(host: host.id, content: .borrowed(content), controller: controller, pane: pane)
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
                record.controller.hideDock()
                record.isShown = false
                records[id] = record
            }
        }
    }

    /// After the new page is in its card: the new selected tab's record comes back, without taking the keyboard.
    func didSelect(_ tab: Tab?) {
        guard mode == .keep, let tab, var record = records[tab.id], !record.isShown else { return }
        record.controller.showDock(focus: .leavesKeyboard)
        record.isShown = true
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

    /// The person dragged the Peek out of the page. Per-tab ownership ends; the Mini lives on as it is.
    func detach(_ controller: MiniWindowController) {
        remove(controller)
    }

    private func record(host: UUID, content: Content, controller: MiniWindowController, pane: NSRect) {
        controller.onPeekClosed = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.remove(controller)
        }
        controller.onPeekDetached = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.remove(controller)
        }
        records[host] = Record(hostTabID: host, content: content, controller: controller, isShown: true,
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
}
