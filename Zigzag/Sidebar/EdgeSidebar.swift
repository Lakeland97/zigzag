import AppKit

/// What the edge preview shows for a row.
enum EdgeLensPolicy {
    /// Pages the panel previews: the web, local files, and Zigzag's own pages, which are served by a scheme handler
    /// and so are pages like any other. A page that doesn't work in the panel's little window is listed as blocked
    /// rather than by refusing its scheme, so each one can be judged on its own.
    static func previews(url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if internalSchemes.contains(scheme) { return !blockedInternalPages.contains(url.host() ?? "") }
        return ["http", "https", "file"].contains(scheme)
    }

    /// Schemes Zigzag serves itself.
    static let internalSchemes: Set<String> = ["zigzag"]
    /// Zigzag's own pages the panel's window doesn't show well. Empty until one is found: Settings and History are
    /// ordinary pages, so they're previewed with everything else.
    static let blockedInternalPages: Set<String> = []

    /// A running page is lent to the preview; one asleep or not loaded yet shows a card, so a hover never wakes it.
    static func showsLivePage(isLoaded: Bool, isAsleep: Bool) -> Bool { isLoaded && !isAsleep }
}

/// The rest on a row before its page comes out beside the panel.
enum EdgePreviewHoverPolicy {
    static let dwell: TimeInterval = 0.2
    static let check: TimeInterval = 0.05
    static let movement: CGFloat = 2
    /// Off the rows and the page this long, the page folds back.
    static let leave: TimeInterval = 0.18

    static func rests(now: TimeInterval, since: TimeInterval, moved: Bool) -> Bool {
        !moved && now - since >= dwell
    }
}

/// Where and when the screen's edge brings the sidebar out over other apps (#363).
enum EdgeSidebarLayout {
    /// How close to the screen's side the pointer has to be: pushed against it.
    static let edgeWidth: CGFloat = 2
    /// Kept clear at the screen's top and bottom corners, which are the system's hot corners.
    static let cornerReserve: CGFloat = Tokens.Space.x6
    /// How long the pointer rests against the edge before the panel comes out.
    static let dwell: TimeInterval = 0.25
    /// How long the pointer can be off the panel before it goes back.
    static let leaveDelay: TimeInterval = 0.15
    /// Room beside the card for a menu from it and its submenu.
    static let menuRoom: CGFloat = 480

    /// The panel: the visible frame's height, `width` wide against the screen's edge, never wider than the screen.
    static func frame(in visible: NSRect, width: CGFloat, onRight: Bool) -> NSRect {
        let width = min(max(width, 0), visible.width)
        return NSRect(x: onRight ? visible.maxX - width : visible.minX, y: visible.minY, width: width, height: visible.height)
    }

    /// The page's share of the screen beside the sidebar.
    static let pageShare: CGFloat = 1.0 / 3.0
    static func pageWidth(in visible: NSRect) -> CGFloat { floor(visible.width * pageShare) }

    /// The panel's width: the sidebar and its gutter, and the page and its gutters while a page is out.
    static func width(sidebar: CGFloat, page: Bool, inset: CGFloat, in visible: NSRect) -> CGFloat {
        sidebar + inset + (page ? pageWidth(in: visible) + inset * 2 : 0)
    }

    /// The page beside the sidebar card, as tall as the card.
    static func pageFrame(in bounds: NSRect, sidebar: CGFloat, inset: CGFloat, onRight: Bool) -> NSRect {
        let width = max(0, bounds.width - sidebar - inset * 3)
        return NSRect(x: onRight ? inset : sidebar + inset * 2, y: inset, width: width,
                      height: max(0, bounds.height - inset * 2))
    }

    /// Against the screen's outer side edge, clear of the menu bar, a bottom Dock, the corners and other displays.
    static func opens(at point: NSPoint, screen: NSRect, visible: NSRect, onRight: Bool, screens: [NSRect]) -> Bool {
        let atEdge = onRight ? point.x >= screen.maxX - edgeWidth : point.x < screen.minX + edgeWidth
        let low = max(visible.minY, screen.minY + cornerReserve)
        let high = min(visible.maxY, screen.maxY - cornerReserve)
        guard atEdge, point.y >= low, point.y <= high else { return false }
        let beyond = NSPoint(x: onRight ? screen.maxX + 1 : screen.minX - 1, y: point.y)
        return !screens.contains { $0 != screen && $0.contains(beyond) }
    }

    /// The pointer is on the panel or just around it.
    static func keeps(at point: NSPoint, panel: NSRect) -> Bool {
        panel.insetBy(dx: -Tokens.Space.x2, dy: -Tokens.Space.x2).contains(point)
    }

    /// The Dock and Stage Manager's strip own their side of the screen: the edge never opens there.
    static func sideIsFree(onRight: Bool, dockSide: String, stageManager: Bool) -> Bool {
        let side = onRight ? "right" : "left"
        if dockSide == side { return false }
        // Stage Manager's strip is on the left, or on the right when the Dock is on the left.
        return !(stageManager && (dockSide == "left" ? "right" : "left") == side)
    }

    /// Only while another app is in front, with no mouse button down.
    static func canShow(appIsActive: Bool, buttonsPressed: Bool) -> Bool {
        !appIsActive && !buttonsPressed
    }

    /// How long an activation change settles before it may put the panel away.
    static let focusGrace: TimeInterval = 0.12
}

/// The sidebar at the screen's edge (#363): the last browser window's sidebar, over other apps.
@MainActor
final class EdgeSidebar {
    static let shared = EdgeSidebar()

    static let defaultsKey = "EdgeSidebar"

    #if DEBUG
    /// The debug bridge keeps the panel out with the pointer elsewhere.
    static var debugHoldsOpen = false
    /// Where tests put the pointer, on screen. While set, rows' own hover reports, which follow the real mouse, are
    /// left out.
    static var debugPointer: NSPoint?

    /// Tells the panel the pointer has moved since the space switch, which a test cannot do by moving a real mouse.
    /// A space switch leaves the rows quiet until the pointer moves, so without this a test's hover would be taken for
    /// the one the switch already had and ignored.
    func debugPointerMoved() {
        hoverQuietUntil = 0
        pointerAtSwitch = nil
    }
    /// Whether tests count the page as having the keyboard, which a test host behind other apps can't give it.
    static var debugPageHasKeyboard: Bool?
    #endif

    /// Whether the page beside the panel has the keyboard.
    private func pageHasKeyboard(_ mini: MiniWindowController) -> Bool {
        #if DEBUG
        if let has = Self.debugPageHasKeyboard { return has }
        #endif
        return mini.window?.isKeyWindow == true
    }

    /// The pointer on screen: every read of it here comes through this.
    private var pointer: NSPoint {
        #if DEBUG
        if let point = Self.debugPointer { return point }
        #endif
        return NSEvent.mouseLocation
    }

    /// Off until turned on in Settings › Appearance.
    static var isOn: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// The last non-private browser window that was in front: its sidebar is the one that comes out.
    private weak var target: BrowserWindowController?
    private var panel: EdgeSidebarPanel?
    private var host: EdgeSidebarHost?
    private(set) var isShowing = false
    private var shownOnRight = false
    /// The visible frame the panel is on, and the panel's frame without a menu's room.
    private var shownVisible: NSRect = .zero
    private var cardPanelFrame: NSRect = .zero
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var dwellTimer: Timer?
    private var followTimer: Timer?
    /// When the pointer left the panel, while it's on its way back.
    private var leftAt: TimeInterval?
    /// Counts shows, so a slide back only orders out the panel it hid.
    private var generation = 0
    /// An activation change waiting to settle.
    private var activationWork: DispatchWorkItem?
    /// The page beside the sidebar: a docked Mini borrowing the row's page, or showing its card.
    private var preview: MiniWindowController?
    private var previewTab: Tab?
    private var previewWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    /// Counts hovers, so a rest check left from the row before can't preview it.
    private var hoverCheck = 0
    /// The window's list while the panel is out: a closed page or a space switch puts the preview away.
    private var managerToken: SignalToken?
    /// When Zigzag last switched space with the panel out: its own switch also reads as a macOS Space change.
    private var spaceSwitchAt: TimeInterval = 0
    /// Until this passes, rows report the hover they had before the switch and it is not taken as asking for a page.
    /// A pointer that moves ends the wait at once: only a pointer still where the switch found it is held off.
    private var hoverQuietUntil: TimeInterval = 0
    /// Where the pointer was at the switch, to tell a hover it already had from one it asks for by moving.
    private var pointerAtSwitch: NSPoint?
    /// The space the preview is showing, so a switch can tell which way through the list it went: the change itself
    /// carries no direction, and by the time it arrives the window's space is already the new one.
    private var previewSpaceID: UUID?
    /// The panel's frame while a page is out.
    private var previewPanelFrame: NSRect = .zero
    /// A menu from the panel is open: the page, a window above the panel, is ordered out so it can't cover it.
    private var menuCoversPage = false

    /// The page beside the panel, if one is out.
    var pagePreview: MiniWindowController? { preview }

    private init() {}

    // MARK: The switch

    /// Turns the edge on or off; off, nothing watches the pointer and the mirror goes.
    func setOn(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.defaultsKey)
        on ? start() : stop()
    }

    /// At launch: listens only if the switch is on.
    func startIfOn() {
        if Self.isOn { start() }
    }

    private func start() {
        guard monitor == nil else { return }
        // Mouse moves need no permission; key events would.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemPutsAway() }
        })
        // A pick brings Zigzag forward, and so does anything else: the panel has done its job. A click into the
        // preview's page brings Zigzag forward too, and keeps the panel.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activationChanged() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activationChanged() }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Zigzag's own space switch also reads as a macOS Space change, and the panel has just kept its page.
                // A person's switch still puts it away.
                guard let self, ProcessInfo.processInfo.systemUptime > self.spaceSwitchAt + 1.0 else { return }
                self.systemPutsAway()
            }
        })
        if let key = WindowManager.shared.keyController, Self.comesOut(for: key) { target = key }
    }

    /// Whether a window's sidebar may come out at the edge: one of your windows, never a private one or the AI Apps
    /// window, shown or parked, which WindowManager keeps out of yours too.
    static func comesOut(for controller: BrowserWindowController) -> Bool {
        !controller.tabManager.isPrivate && WindowManager.shared.controllers.contains { $0 === controller }
    }

    /// Another Space or a display change puts the panel away; a held one stays.
    private func systemPutsAway() {
        #if DEBUG
        if Self.debugHoldsOpen { return }
        #endif
        hide(animated: false)
    }

    /// The preview's Mini takes the keyboard a moment after a click activates Zigzag, so the verdict waits.
    private func activationChanged() {
        guard isShowing else { return }
        #if DEBUG
        if Self.debugHoldsOpen { return }
        #endif
        activationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.activationWork = nil
                guard self.isShowing else { return }
                if NSApp.isActive, self.preview?.window?.isKeyWindow == true { return }
                self.hide(animated: false)
            }
        }
        activationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EdgeSidebarLayout.focusGrace, execute: work)
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        cancelDwell()
        hide(animated: false)
        target?.discardEdgeSidebar()
        target = nil
    }

    /// The last of your browser windows to become key; a private window's sidebar never comes out at the edge, nor
    /// the AI Apps window's.
    func noteFocused(_ controller: BrowserWindowController) {
        guard monitor != nil, Self.comesOut(for: controller), target !== controller else { return }
        hide(animated: false)
        target?.discardEdgeSidebar()
        target = controller
    }

    func windowClosed(_ controller: BrowserWindowController) {
        guard target === controller else { return }
        hide(animated: false)
        target = nil
    }

    /// The panel's window, so a menu in it can tell where it is.
    func isPanel(_ window: NSWindow?) -> Bool { window != nil && window === panel }

    // MARK: The pointer

    private func moved() {
        guard !isShowing, !NSApp.isActive else { return }
        if target == nil, let key = WindowManager.shared.keyController, Self.comesOut(for: key) { target = key }
        guard let target, atEdge(target: target) else { return cancelDwell() }
        guard dwellTimer == nil else { return }
        let timer = Timer(timeInterval: EdgeSidebarLayout.dwell, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dwelled() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    /// The pointer against the edge now, on a side no part of macOS uses.
    private func atEdge(target: BrowserWindowController) -> Bool {
        let point = pointer
        let onRight = target.edgeSidebarOnRight
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              EdgeSidebarLayout.opens(at: point, screen: screen.frame, visible: screen.visibleFrame, onRight: onRight,
                                      screens: NSScreen.screens.map(\.frame)) else { return false }
        // Read only at the edge: the Dock's side and Stage Manager change rarely.
        let dock = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String ?? "bottom"
        let stage = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool ?? false
        return EdgeSidebarLayout.sideIsFree(onRight: onRight, dockSide: dock, stageManager: stage)
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
    }

    private func dwelled() {
        dwellTimer = nil
        guard !isShowing, let target, atEdge(target: target),
              EdgeSidebarLayout.canShow(appIsActive: NSApp.isActive, buttonsPressed: NSEvent.pressedMouseButtons != 0),
              let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
        else { return }
        show(on: screen.visibleFrame, for: target)
    }

    private func follow() {
        guard isShowing, let panel else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // A pressed button, a menu from the panel or a sheet keeps it out.
        var held = NSEvent.pressedMouseButtons != 0 || MenuPanel.current != nil
            || RunLoop.current.currentMode == .eventTracking || NSApp.modalWindow != nil
            || host?.overlay.subviews.isEmpty == false
        #if DEBUG
        if Self.debugHoldsOpen { held = true }
        #endif
        // The menu's room goes with the menu; the page's room stays while a page is out.
        let frame = preview == nil ? cardPanelFrame : previewPanelFrame
        if MenuPanel.current == nil, panel.frame != frame { panel.setFrame(frame, display: true) }
        if MenuPanel.current == nil, menuCoversPage {
            menuCoversPage = false
            preview?.layoutInDock()
        }
        // The panel gets no mouse moves with another app in front, so the preview's strip follows from here.
        let point = pointer
        preview?.pointerMoved(toScreen: point)
        followPreviewPointer()
        if held || EdgeSidebarLayout.keeps(at: point, panel: frame) {
            leftAt = nil
            return
        }
        guard let leftAt else { leftAt = now; return }
        if now - leftAt > EdgeSidebarLayout.leaveDelay { hide() }
    }

    // MARK: The preview

    /// A row rested on in the panel: its page comes out beside the sidebar. Nil, off the rows: the page goes unless
    /// the pointer is on it.
    func hover(_ tab: Tab?, in controller: BrowserWindowController) {
        previewWork?.cancel()
        previewWork = nil
        guard isShowing, target === controller else {
            closePreview(animated: false, panelStays: false)
            return
        }
        closeWork?.cancel()
        closeWork = nil
        hoverCheck += 1
        // Right after a space switch the rows report where the pointer already was, and that would bring a page out
        // over the blank the switch just landed on. Only a pointer that has really moved counts as asking for one.
        guard hoverQuietUntil <= ProcessInfo.processInfo.systemUptime || pointerMovedSinceSwitch() else {
            if tab == nil { schedulePreviewClose() }
            return
        }
        // Rows report leaving and arriving in either order: the row under the pointer counts. A row of the space just
        // left, still sliding out, is no row.
        let shown = { (tab: Tab?) in tab.flatMap { Self.isInShownSpace($0, of: controller) ? $0 : nil } }
        guard let tab = shown(tab) ?? shown(pageOnRow(at: pointer)) else {
            schedulePreviewClose()
            return
        }
        guard tab !== previewTab || preview == nil else { return }
        guard !tab.isPrivate, EdgeLensPolicy.previews(url: tab.url) else {
            schedulePreviewClose(evenOnRows: true)
            return
        }
        scheduleHoverCheck(tab: tab, in: controller, pointer: pointer,
                           since: ProcessInfo.processInfo.systemUptime, token: hoverCheck)
    }

    /// Whether the pointer has moved since the switch: the quiet window ends at the first real movement, and a hover
    /// that arrives without one is the pointer still resting where the switch found it.
    private func pointerMovedSinceSwitch() -> Bool {
        let now = pointer
        guard let last = pointerAtSwitch else { return true }
        let moved = abs(now.x - last.x) > EdgePreviewHoverPolicy.movement
            || abs(now.y - last.y) > EdgePreviewHoverPolicy.movement
        if moved { hoverQuietUntil = 0 }
        return moved
    }

    /// A sidebar row's own hover report, from the real mouse's tracking areas.
    func rowHovered(_ tab: Tab?, in controller: BrowserWindowController) {
        #if DEBUG
        if Self.debugPointer != nil { return }
        #endif
        hover(tab, in: controller)
    }

    /// Esc in the panel puts the page away first.
    @discardableResult
    func dismissPreview() -> Bool {
        guard preview != nil else { return false }
        closePreview()
        return true
    }

    #if DEBUG
    /// A row's preview without the rest or the pointer, for tests and the debug bridge.
    func previewNow(_ tab: Tab, in controller: BrowserWindowController) {
        guard isShowing, target === controller else { return }
        previewWork?.cancel()
        previewWork = nil
        closeWork?.cancel()
        closeWork = nil
        hoverCheck += 1
        showPreview(tab, in: controller)
    }
    #endif

    /// A pointer crossing rows previews nothing; one that stops on a row does after a short rest.
    private func scheduleHoverCheck(tab: Tab, in controller: BrowserWindowController, pointer: NSPoint,
                                    since: TimeInterval, token: Int) {
        let work = DispatchWorkItem { [weak self, weak tab, weak controller] in
            MainActor.assumeIsolated {
                guard let self, let tab, let controller, self.isShowing, self.target === controller,
                      self.hoverCheck == token else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let point = self.pointer
                let moved = abs(point.x - pointer.x) > EdgePreviewHoverPolicy.movement
                    || abs(point.y - pointer.y) > EdgePreviewHoverPolicy.movement
                if EdgePreviewHoverPolicy.rests(now: now, since: since, moved: moved) {
                    self.previewWork = nil
                    self.showPreview(tab, in: controller)
                } else {
                    self.scheduleHoverCheck(tab: tab, in: controller, pointer: point, since: moved ? now : since,
                                            token: token)
                }
            }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EdgePreviewHoverPolicy.check, execute: work)
    }

    /// The row's page in a docked Mini beside the sidebar, folding in over the page before it. A page that isn't
    /// running shows its card instead, and stays asleep.
    private func showPreview(_ tab: Tab, in controller: BrowserWindowController) {
        guard isShowing, !menuCoversPage, let panel, let host, !tab.isPrivate, EdgeLensPolicy.previews(url: tab.url),
              Self.isInShownSpace(tab, of: controller), preview?.tab !== tab else { return }
        // Which space the page belongs to, so a later switch knows which way through the list it moved.
        previewSpaceID = controller.tabManager.currentSpaceID
        let live = EdgeLensPolicy.showsLivePage(isLoaded: tab.isLoaded, isAsleep: tab.isAsleep)
        let previous = preview
        // The panel takes its full width first, so the page is laid out once at its final size.
        let sidebar = controller.edgeSidebarWidth
        let wide = EdgeSidebarLayout.width(sidebar: sidebar, page: true, inset: host.inset, in: shownVisible)
        previewPanelFrame = EdgeSidebarLayout.frame(in: shownVisible, width: wide, onRight: shownOnRight)
        host.cardWidth = sidebar
        host.pageShowing = true
        panel.setFrame(previewPanelFrame, display: true)
        host.layoutSubtreeIfNeeded()
        // The blank a space switch left in the panel is not a row's page: the row's own takes its place in the same
        // window, so the switch keeps one preview rather than folding a blank away and building another.
        if let previous, previous.ownPageURL != nil, previous.retarget(to: tab, deferPage: !live) {
            if !live { installAsleepClick(on: previous, tab: tab, controller: controller) }
            previewTab = tab
            return
        }
        guard let mini = MiniWindowController.openPreview(of: tab, from: controller, dockedIn: self,
                                                           reveal: false, deferPage: !live) else {
            if previous == nil { narrowPanel() }
            return
        }
        if !live { installAsleepClick(on: mini, tab: tab, controller: controller) }
        mini.onInPageMiniClosed = { [weak self, weak mini] in self?.previewClosed(mini) }
        mini.onInPageMiniDetached = { [weak self, weak mini] in self?.previewDetached(mini) }
        preview = mini
        previewTab = tab
        mini.layoutInDock(force: true)
        mini.revealDockedPage(fromRight: shownOnRight) { [weak self, weak previous] in
            // The page before stays under the fold until it is covered.
            guard let previous else { return }
            previous.onInPageMiniClosed = nil
            previous.onInPageMiniDetached = nil
            previous.closeInPage(focusBack: self?.pageHasKeyboard(previous) == true, animated: false)
        }
    }

    /// A click on a sleeping row's card wakes its page in the same pill. Choosing the tab through the window's list
    /// would bring the browser forward and take the panel away, which is the opposite of what the click asks for, so
    /// the tab is selected here and its page is built in the preview where it already is.
    private func installAsleepClick(on mini: MiniWindowController, tab: Tab, controller: BrowserWindowController) {
        mini.showAsleepCard { [weak self, weak controller, weak tab, weak mini] in
            guard let self, let controller, let tab, let mini, self.isShowing else { return }
            controller.tabManager.select(tab)
            mini.wakeInPlace()
        }
    }

    /// The page folds back after a moment unless the pointer is on it, or still among the rows: a crossing from one row
    /// to the next is not leaving them. `evenOnRows`: the row under the pointer has no page to show, so the pointer
    /// being on a row is not a reason to keep one out.
    private func schedulePreviewClose(evenOnRows: Bool = false) {
        closeWork?.cancel()
        closeWork = nil
        guard preview != nil else { return }
        // After a space switch the panel holds the blank page: there is no row's page to close, and closing would
        // narrow the panel and undo what the switch just put in place.
        guard preview?.ownPageURL == nil else { return }
        let start = pointer
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.closeWork = nil
                let point = self.pointer
                // A pointer still on its way somewhere, from the page to a row say, hasn't left: the page goes once it
                // stops off the rows and the page.
                let moving = abs(point.x - start.x) > EdgePreviewHoverPolicy.movement
                    || abs(point.y - start.y) > EdgePreviewHoverPolicy.movement
                guard EdgeHoverRouting.closesAfterNilHover(pointerOverRows: !evenOnRows && self.rowNear(point) != nil,
                                                           pointerOverPreview: self.pointerIsOnPage(point),
                                                           stillMoving: !evenOnRows && moving) else { return }
                self.closePreview()
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EdgePreviewHoverPolicy.leave, execute: work)
    }

    /// Leaving the page for the gutter or the sidebar's empty part, no row reports it: the pointer is watched.
    private func followPreviewPointer() {
        #if DEBUG
        if Self.debugHoldsOpen, Self.debugPointer == nil { return }
        #endif
        guard preview != nil, closeWork == nil, previewWork == nil, MenuPanel.current == nil,
              NSEvent.pressedMouseButtons == 0, let panel else { return }
        // The blank a space switch landed on is not a page to leave: it stays until a row asks for its own.
        guard preview?.ownPageURL == nil else { return }
        let point = pointer
        guard panel.frame.contains(point), !pointerIsOnPage(point), rowNear(point) == nil else { return }
        schedulePreviewClose()
    }

    /// Whether the point is on the page beside the sidebar.
    private func pointerIsOnPage(_ point: NSPoint) -> Bool {
        if preview?.window?.frame.contains(point) == true { return true }
        guard let panel, let host, host.pageShowing else { return false }
        return panel.convertToScreen(host.convert(host.pageFrame, to: nil)).contains(point)
    }

    /// The tab row in the panel at a point on screen, or within a row's gap of it, so the gap between two rows counts.
    private func rowNear(_ point: NSPoint) -> TabRowView? {
        guard isShowing, let panel, let host, let container = host.container, panel.frame.contains(point) else { return nil }
        let inWindow = panel.convertPoint(fromScreen: point)
        guard host.cardFrame.contains(host.convert(inWindow, from: nil)) else { return nil }
        let reach = Tokens.Sidebar.rowGap + 1
        for dy in [0, reach, -reach] {
            let probe = NSPoint(x: inWindow.x, y: inWindow.y + dy)
            var view = host.hitTest(host.superview?.convert(probe, from: nil) ?? probe)
            while let current = view, current !== container {
                if let row = current as? TabRowView { return row }
                view = current.superview
            }
        }
        return nil
    }

    /// The page of the tab row right under a point on screen: a split's or tile group's part, or the row's own.
    private func pageOnRow(at point: NSPoint) -> Tab? {
        guard let panel, let host, panel.frame.contains(point) else { return nil }
        let inWindow = panel.convertPoint(fromScreen: point)
        var view = host.hitTest(host.superview?.convert(inWindow, from: nil) ?? inWindow)
        while let current = view, current !== host {
            if let row = current as? TabRowView, row.tab != nil {
                let inRow = row.convert(inWindow, from: nil)
                return row.isSplit ? row.page(at: inRow) : row.tab
            }
            view = current.superview
        }
        return nil
    }

    /// Puts the page away; the panel narrows to the sidebar and stays out. `animated`: the page folds back first.
    /// `panelStays`: a page with the keyboard hands it to the panel, not to the browser window behind.
    private func closePreview(animated: Bool = true, panelStays: Bool = true) {
        previewWork?.cancel()
        previewWork = nil
        closeWork?.cancel()
        closeWork = nil
        guard let mini = preview, !mini.isLeavingDock else { return }
        preview = nil
        previewTab = nil
        // The page a switch left is this window's alone, and it goes with the window: nothing to keep for next time.
        mini.clearOwnPage()
        let focusBack = panelStays && pageHasKeyboard(mini)
        if animated {
            mini.closeInPage(focusBack: focusBack, animated: true)
        } else {
            mini.onInPageMiniClosed = nil
            mini.onInPageMiniDetached = nil
            mini.closeInPage(focusBack: focusBack, animated: false)
            narrowPanel()
        }
    }

    /// The preview closed itself (Esc, its close button, Open in Zigzag) or finished folding away.
    private func previewClosed(_ closing: MiniWindowController?) {
        if let closing, let preview, preview !== closing { return }
        let movedOut = preview?.pageMovedOut == true
        preview = nil
        previewTab = nil
        narrowPanel()
        if movedOut { hide(animated: false) }
    }

    /// Expand took the page into a window of its own: the panel's job is done.
    private func previewDetached(_ closing: MiniWindowController?) {
        if let closing, let preview, preview !== closing { return }
        preview = nil
        previewTab = nil
        narrowPanel()
        hide(animated: false)
    }

    private func narrowPanel() {
        previewPanelFrame = .zero
        guard isShowing, let host, let panel else { return }
        host.pageShowing = false
        if let target { host.cardWidth = target.edgeSidebarWidth }
        panel.setFrame(cardPanelFrame, display: true)
    }

    /// A tab of the space the panel's list shows; a favorite belongs to every space.
    private static func isInShownSpace(_ tab: Tab, of controller: BrowserWindowController) -> Bool {
        tab.isFavorite || tab.spaceID == controller.tabManager.currentSpaceID
    }

    private func managerChanged(_ change: TabManager.Change) {
        if change == .space {
            // The row it came from is no longer on screen: a rest begun on a row of the space left never brings that
            // row's page out. The sidebar stays either way.
            hoverCheck += 1
            // A page still folding back goes home now too, rather than showing through the switch.
            for mini in MiniWindowController.all where mini.isLeavingDock && mini.isDocked(in: self) { mini.endBorrowingNow() }
            if isShowing {
                spaceSwitchAt = ProcessInfo.processInfo.systemUptime
                pointerAtSwitch = pointer
                hoverQuietUntil = spaceSwitchAt + 0.6
                // The preview itself stays: the page it borrowed goes home and it shows the new space's blank.
                handOverToBlank()
            } else if preview == nil {
                narrowPanel()
            }
            return
        }
        guard preview != nil else { return }
        switch change {
        case .space:
            break
        case .structure:
            if previewTab?.isClosed == true { closePreview(animated: false) }
        case .selection, .content:
            break
        }
        if change == .structure, preview != nil, previewTab?.isClosed == true { closePreview(animated: false) }
    }

    /// A space switch with the panel out: the page belongs to the space that was left, so the preview stops showing
    /// it, but the preview itself stays. The same docked Mini is pointed at the blank page, in the same wide frame,
    /// so nothing closes, folds or narrows on the way: the panel is a list and a page, and only the list changed.
    ///
    /// Without a page out there is nothing to hand over, and the panel keeps its narrow frame: the next hover in the
    /// new space's list brings a page out as it always would.
    /// Whether the switch moved to a later space in the window's list, which is the side its blank folds in from.
    /// A space that is new to the list, or one whose predecessor is unknown (the panel was just put out), has no
    /// direction to show; the sidebar's own side is used then, as a row's page uses it.
    private func spaceSwitchCameFromRight(to window: BrowserWindowController?, was previous: UUID?) -> Bool {
        let fromRight = shownOnRight
        guard let window, let previous, previous != window.tabManager.currentSpaceID else { return fromRight }
        let spaces = window.tabManager.listedSpaces
        guard let now = spaces.firstIndex(where: { $0.id == window.tabManager.currentSpaceID }),
              let then = spaces.firstIndex(where: { $0.id == previous }) else { return fromRight }
        return now > then
    }

    private func handOverToBlank() {
        guard isShowing, let host, let mini = preview, let panel else { return }
        previewWork?.cancel()
        previewWork = nil
        closeWork?.cancel()
        closeWork = nil
        // Its page goes back to the tab it belongs to, in the space that was left. The Mini stays, docked, showing
        // Zigzag's blank page: a real page, so the panel keeps a page rather than an empty room.
        mini.onInPageMiniClosed = nil
        mini.onInPageMiniDetached = nil
        // The page names the space being switched to, not the one being left. It is asked of the panel's own window,
        // never the key one: the Mini is a child window, so a page that looked the space up itself would be served the
        // wrong space's ground whenever another window holds the keyboard. The space's picture is named too, so the
        // page the Mini shows is the same empty page the window would show for that space.
        let switched = target.map { window -> URL in
            let isPrivate = window.tabManager.isPrivate
            let space = Library.shared.space(window.tabManager.currentSpaceID)
            return ViewportPage.blankURL(for: window.tabManager.currentSpaceID, isPrivate: isPrivate,
                                         picture: EmptyPage.picture(for: space, isPrivate: isPrivate))
        }
        // Which way the list was walked, so the blank arrives from the side the switch came from: the row swap's
        // fixed "out from the sidebar" would say the wrong thing here, because a space change has a direction of its
        // own. `fromRight` is how the fold is anchored, so a move to a later space comes from the right.
        let fromRight = spaceSwitchCameFromRight(to: target, was: previewSpaceID)
        // The window is held weakly and can be gone by the time its last change arrives. With no window there is no
        // space to name, and the plain blank is the only page that can't draw another space's ground.
        mini.showPage(switched ?? ViewportPage.blank, revealingFromRight: fromRight)
        previewSpaceID = target?.tabManager.currentSpaceID
        mini.onInPageMiniClosed = { [weak self, weak mini] in self?.previewClosed(mini) }
        mini.onInPageMiniDetached = { [weak self, weak mini] in self?.previewDetached(mini) }
        previewTab = nil
        let sidebar = host.cardWidth
        let wide = EdgeSidebarLayout.width(sidebar: sidebar, page: true, inset: host.inset, in: shownVisible)
        previewPanelFrame = EdgeSidebarLayout.frame(in: shownVisible, width: wide, onRight: shownOnRight)
        host.pageShowing = true
        panel.setFrame(previewPanelFrame, display: true)
        host.placeCard()
        host.layoutSubtreeIfNeeded()
    }

    // MARK: The panel

    func show(on visible: NSRect, for target: BrowserWindowController) {
        self.target = target
        let container = target.prepareEdgeSidebar()
        let onRight = target.edgeSidebarOnRight
        let panel = panel ?? makePanel()
        guard let host else { return }
        closePreview(animated: false, panelStays: false)
        host.pageShowing = false
        managerToken = target.tabManager.changed.observe { [weak self] change in
            MainActor.assumeIsolated { self?.managerChanged(change) }
        }
        host.onRight = onRight
        host.cardWidth = target.edgeSidebarWidth
        host.set(container)
        generation += 1
        cardPanelFrame = EdgeSidebarLayout.frame(in: visible, width: host.cardWidth + host.inset, onRight: onRight)
        shownVisible = visible
        panel.setFrame(cardPanelFrame, display: true)
        host.placeCard()
        isShowing = true
        shownOnRight = onRight
        leftAt = nil
        // The keyboard stays with the app in front until the panel is clicked.
        panel.orderFrontRegardless()
        let card = host.cardFrame
        Tokens.Motion.withoutAnimation { container.frame = card }
        Tokens.Motion.slide(container, fromOffsetX: (onRight ? 1 : -1) * (card.width + host.inset), curve: Tokens.Motion.edgeSlide)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    /// Puts the panel away; without the slide when Zigzag is coming forward.
    func hide(animated: Bool = true) {
        // No page is out, so there is no space for the next switch to measure from.
        previewSpaceID = nil
        followTimer?.invalidate()
        followTimer = nil
        activationWork?.cancel()
        activationWork = nil
        managerToken?.cancel()
        managerToken = nil
        menuCoversPage = false
        closePreview(animated: false, panelStays: false)
        guard isShowing, let panel else { return }
        isShowing = false
        generation += 1
        if MenuPanel.current?.window === panel { MenuPanel.current?.close(animated: false) }
        // A sheet, editor or the downloads list open in the panel goes with it, never left for its next time out.
        host?.overlay.subviews.forEach { ($0 as? FormSheet)?.close(); ($0 as? SpaceEditorPanel)?.close() }
        host?.overlay.subviews.forEach { $0.removeFromSuperview() }
        if DownloadsPanel.isOpen(in: panel) { DownloadsPanel.closeCurrent() }
        guard animated, let host, let container = host.container else { panel.orderOut(nil); return }
        let card = host.cardFrame
        let out = card.offsetBy(dx: (shownOnRight ? 1 : -1) * (card.width + host.inset), dy: 0)
        Tokens.Motion.withoutAnimation { container.frame = out }
        let duration = Tokens.Motion.slide(container, fromOffsetX: card.minX - out.minX, curve: Tokens.Motion.edgeTuck)
        guard duration > 0 else { panel.orderOut(nil); return }
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    /// A menu is opening in the panel: it widens on the inner side, the card staying put, so the menu isn't cut off.
    func makeRoomForMenu() {
        guard isShowing, let panel else { return }
        let width = max(cardPanelFrame.width + EdgeSidebarLayout.menuRoom, previewPanelFrame.width)
        panel.setFrame(EdgeSidebarLayout.frame(in: shownVisible, width: width, onRight: shownOnRight), display: true)
        menuCoversPage = true
        preview?.layoutInDock()
    }

    /// Downloads from the panel: the list in the panel's window, over the mirror's lane, not in the window behind.
    func showDownloads(from anchor: NSView, in controller: BrowserWindowController) {
        guard isShowing, let host, let target else { return }
        // The rows' edges in the card, as in the window.
        DownloadsPanel.show(from: anchor, in: controller, host: host, lane: host.cardFrame.insetBy(dx: Tokens.Sidebar.edge, dy: 0),
                            receding: target.edgeSidebar.map { [$0.list] } ?? [])
    }

    /// ⌘T with the panel clicked into: a new tab in the window, which comes forward.
    func newTab() { target?.newTabFromEdge() }

    /// Menu bar actions done where they are, the panel's list showing what they did. Every other one is done in the
    /// window, which comes forward, as for a menu item picked in the panel.
    static let actsInPanel: Set<Selector> = [
        #selector(BrowserWindowController.closeTab(_:)), #selector(BrowserWindowController.closeOtherTabs(_:)),
        #selector(BrowserWindowController.reloadPage(_:)), #selector(BrowserWindowController.reloadPageFromOrigin(_:)),
        #selector(BrowserWindowController.stopLoading(_:)), #selector(BrowserWindowController.nextSpace(_:)),
        #selector(BrowserWindowController.previousSpace(_:)), #selector(BrowserWindowController.selectSpaceByNumber(_:)),
    ]

    /// A menu bar shortcut pressed in the panel or in its page. `own` answers first: the panel's views, or the page's
    /// window and its Mini. The browser's own keys (`BrowserWindow.browserActions`) then go to the browser, as in its
    /// window, and to the app after that. False: the keys are left to the panel.
    func performKeyEquivalent(_ event: NSEvent, own: [NSResponder]) -> Bool {
        guard isShowing, let target, let item = BrowserWindow.menuItem(for: event, in: NSApp.mainMenu),
              let action = item.action else { return false }
        if let answer = own.first(where: { $0.responds(to: action) }) {
            if Self.validates(answer, item) { NSApp.sendAction(action, to: answer, from: item) }
            return true
        }
        guard BrowserWindow.browserActions.contains(NSStringFromSelector(action)) else { return false }
        if target.responds(to: action) {
            if target.validateMenuItem(item) {
                if !Self.actsInPanel.contains(action) { target.bringForwardForEdge() }
                NSApp.sendAction(action, to: target, from: item)
            }
            return true
        }
        guard let app = [NSApp.delegate as AnyObject?, NSApp].compactMap({ $0 as? NSObject }).first(where: { $0.responds(to: action) })
        else { return false }
        if Self.validates(app, item) { NSApp.sendAction(action, to: app, from: item) }
        return true
    }

    /// The responders a window's keys reach before the browser: its first responder up through its views, and with
    /// `viewsOnly` false the window and its controller too.
    static func responders(of window: NSWindow, viewsOnly: Bool) -> [NSResponder] {
        var found: [NSResponder] = []
        var responder = window.firstResponder
        while let current = responder, current !== window {
            found.append(current)
            responder = current.nextResponder
        }
        if !viewsOnly {
            found.append(window)
            if let controller = window.windowController { found.append(controller) }
        }
        return found
    }

    private static func validates(_ responder: AnyObject, _ item: NSMenuItem) -> Bool {
        if let validating = responder as? NSMenuItemValidation { return validating.validateMenuItem(item) }
        if let validating = responder as? NSUserInterfaceValidations { return validating.validateUserInterfaceItem(item) }
        return true
    }

    /// A menu item picked in the panel: the window comes forward with its sidebar out, where the item acts.
    func chose() {
        guard let target else { return }
        target.bringForwardForEdge()
        target.revealSidebarForEdge()
    }

    /// Where a sheet belongs while the panel is in use: over the panel, above its cards, not in the window behind.
    var sheetHost: NSView? { isShowing ? host?.overlay : nil }

    /// The panel's space name, where an editor opens when a menu bar command started it.
    var headerView: NSView? { isShowing ? target?.edgeSidebar?.list.headerView : nil }

    /// A sideways scroll over the panel's sidebar changes space, as in the window.
    private func intercept(_ event: NSEvent) -> Bool {
        guard event.type == .scrollWheel, isShowing, let host, let container = host.container else { return false }
        let point = host.convert(event.locationInWindow, from: nil)
        guard host.cardFrame.contains(point), host.hitTest(point)?.isDescendant(of: container) == true else { return false }
        return container.sidebar.handleSwipe(event)
    }

    private func makePanel() -> EdgeSidebarPanel {
        let panel = EdgeSidebarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Over other apps and full-screen apps, on every Space, out of Stage Manager and ⌘`.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setSeeThrough(shadow: false)
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // ⌘H hides Zigzag's windows, not the way back to them.
        panel.canHide = false
        panel.eventInterceptor = { [weak self] event in self?.intercept(event) ?? false }
        let host = EdgeSidebarHost()
        panel.contentView = host
        self.host = host
        self.panel = panel
        return panel
    }
}

/// The edge sidebar's panel: over another app without taking the front or the keyboard; a click in it takes the keyboard.
final class EdgeSidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var eventInterceptor: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if !isKeyWindow, event.type == .leftMouseDown || event.type == .rightMouseDown { makeKey() }
        if eventInterceptor?(event) == true { return }
        // Esc puts the page away, then the panel, unless a field is being edited.
        if event.type == .keyDown, event.keyCode == 53, !(firstResponder is NSTextView), MenuPanel.current == nil {
            if EdgeSidebar.shared.dismissPreview() { return }
            EdgeSidebar.shared.hide()
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "t" {
            EdgeSidebar.shared.newTab()
            return true
        }
        // A nonactivating panel gets no key equivalents from the menu bar by itself: the rest are routed here.
        if EdgeSidebar.shared.performKeyEquivalent(event, own: EdgeSidebar.responders(of: self, viewsOnly: true)) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The panel's content: the floating sidebar card, set off the screen's edge as it is from a window's.
final class EdgeSidebarHost: NSView {
    private(set) weak var container: SidebarContainer?
    let inset = Tokens.Metric.cardInset
    var onRight = false { didSet { placeCard() } }
    var cardWidth: CGFloat = 0 { didSet { placeCard() } }
    /// A page is out beside the card.
    var pageShowing = false
    /// The card as a place for sheets and editors: they open here, over it, not in the browser behind.
    let overlay = PassthroughView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = Tokens.Radius.card
        overlay.layer?.cornerCurve = .continuous
        overlay.layer?.masksToBounds = true
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The page's place beside the card.
    var pageFrame: NSRect {
        pageShowing ? EdgeSidebarLayout.pageFrame(in: bounds, sidebar: cardWidth, inset: inset, onRight: onRight) : .zero
    }

    /// Against the screen's edge, whatever room beside it a menu has.
    var cardFrame: NSRect {
        NSRect(x: onRight ? bounds.width - inset - cardWidth : inset, y: inset, width: cardWidth,
               height: max(0, bounds.height - inset * 2))
    }

    func set(_ container: SidebarContainer) {
        if self.container !== container {
            self.container?.removeFromSuperview()
            self.container = container
            container.autoresizingMask = []
        }
        if container.superview !== self { addSubview(container, positioned: .below, relativeTo: overlay) }
        placeCard()
    }

    func placeCard() {
        container?.frame = cardFrame
        // Sheets and editors over the panel are centered on the card, their dim inside its corners.
        overlay.frame = cardFrame
    }

    override func layout() {
        super.layout()
        placeCard()
    }

    /// A click beside the card puts the panel away; the gutter by a page that is out is part of the panel.
    override func mouseDown(with event: NSEvent) {
        if container?.frame.contains(convert(event.locationInWindow, from: nil)) != true {
            if pageShowing { return }
            EdgeSidebar.shared.hide()
            return
        }
        super.mouseDown(with: event)
    }
}

extension EdgeSidebar: MiniDockHosting {
    var dockParentWindow: NSWindow? { panel }
    var dockPageView: NSView { host ?? panel?.contentView ?? NSView() }
    var dockPageFrame: NSRect { host?.pageFrame ?? .zero }
    /// The page is its own pill beside the sidebar, floor to ceiling.
    func dockCardFrame(in page: NSRect) -> NSRect { page }
    var dockCardRadius: CGFloat { Tokens.Radius.large }
    var dockCardColor: NSColor? { Tokens.Color.cardBackground }
    var dockHasShadow: Bool { true }
    var dockSlidesPage: Bool { true }
    var dockFollowsParentLevel: Bool { true }
    var dockPageOnRight: Bool { shownOnRight }
    var dockIsCovered: Bool { !isShowing || host?.pageShowing != true || menuCoversPage }
    var dockIsFullScreen: Bool { false }

    /// No page behind it to dim.
    func dockShowDim(owner: AnyObject, onClick: @escaping () -> Void) -> MiniPeekDimView? { nil }
    func dockHideDim(owner: AnyObject) {}
    /// The panel keeps the keyboard while it stays out.
    func dockFocusPage() {
        guard isShowing, let panel else { return }
        panel.makeKey()
    }
}

/// Over the preview's room while the row's page isn't running: its name and why, on the card's own ground.
final class EdgeAsleepPageView: NSView {
    private let ground = ColorView(color: Tokens.Color.cardBackground)
    private let icon = NSImageView()
    private let title = Label("", font: Tokens.Font.title(), color: Tokens.Color.textPrimary)
    private let note = Label("", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
    /// What the card says, for tests.
    private(set) var shownTitle = ""
    private(set) var shownNote = ""
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: nil)
        icon.contentTintColor = Tokens.Color.textTertiary
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        note.alignment = .center
        note.usesSingleLineMode = false
        note.maximumNumberOfLines = 3
        note.lineBreakMode = .byWordWrapping
        [ground, icon, title, note].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The page is behind another app when it's clicked: the first click counts, anywhere on the card.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onClick != nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit != nil && onClick != nil ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { return super.mouseDown(with: event) }
        onClick()
    }

    /// The row's name and why its page isn't running. Reads the tab only; never wakes it.
    func show(tab: Tab) {
        shownTitle = tab.displayTitle
        shownNote = tab.notLoadedNote ?? ""
        title.stringValue = shownTitle
        note.stringValue = shownNote
        note.isHidden = shownNote.isEmpty
        setAccessibilityLabel([shownTitle, shownNote].filter { !$0.isEmpty }.joined(separator: ", "))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let width = max(0, min(Tokens.EmptyState.textWidth, bounds.width - Tokens.Space.x8))
        let iconSide = Tokens.Space.x8
        let titleHeight = title.lineHeight
        let noteHeight = note.isHidden ? 0 : ceil(note.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? note.lineHeight)
        let total = iconSide + Tokens.EmptyState.markGap + titleHeight + (note.isHidden ? 0 : Tokens.Space.x2 + noteHeight)
        var y = ((bounds.height - total) / 2).rounded()
        icon.frame = NSRect(x: (bounds.midX - iconSide / 2).rounded(), y: y, width: iconSide, height: iconSide)
        y = icon.frame.maxY + Tokens.EmptyState.markGap
        title.frame = NSRect(x: (bounds.midX - width / 2).rounded(), y: y, width: width, height: titleHeight)
        y = title.frame.maxY + Tokens.Space.x2
        note.frame = NSRect(x: (bounds.midX - width / 2).rounded(), y: y, width: width, height: noteHeight)
    }
}
