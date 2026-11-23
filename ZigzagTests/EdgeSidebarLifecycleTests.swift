import AppKit
import Testing
@testable import Zigzag

/// The edge sidebar's lens lifecycle (#363/#365): the panel and the lens are one session, each dismissal says what
/// it closes, and the lens joins another app's Space without bringing Zigzag forward.
@MainActor
struct EdgeSidebarLifecycleTests {
    @Test func thePanelStaysWhileTheLensIsHeld() {
        #expect(EdgeSidebarLayout.keepsPanelOnActivation(holdsForPeek: true))
        #expect(!EdgeSidebarLayout.keepsPanelOnActivation(holdsForPeek: false))
        // The panel taking the keyboard with the pointer on it is the panel working, not the browser coming forward.
        #expect(EdgeSidebarLayout.keepsPanelOnActivation(holdsForPeek: false, panelFocused: true, pointerOnPanel: true))
        #expect(!EdgeSidebarLayout.keepsPanelOnActivation(holdsForPeek: false, panelFocused: true, pointerOnPanel: false))
        #expect(!EdgeSidebarLayout.keepsPanelOnActivation(holdsForPeek: false, panelFocused: false, pointerOnPanel: true))
    }

    @Test func aSidebarActionClosesOnlyTheLens() {
        for reason in [EdgeLensReason.sameTab, .sidebarClick, .escape] {
            #expect(EdgeLensPolicy.dismissal(for: reason) == .lensOnly)
        }
    }

    @Test func aClosedWindowTakesTheSidebarWithTheLens() {
        for reason in [EdgeLensReason.windowClose, .featureOff] {
            #expect(EdgeLensPolicy.hidesSidebar(after: reason, pointerInEdgeZone: true, panelCanShow: true))
        }
    }

    @Test func anotherAppLeavesTheSidebarToItsProximity() {
        #expect(!EdgeLensPolicy.hidesSidebar(after: .altTab, pointerInEdgeZone: true, panelCanShow: true))
        #expect(EdgeLensPolicy.hidesSidebar(after: .altTab, pointerInEdgeZone: false, panelCanShow: true))
    }

    @Test func theLensJoinsTheSpaceWithoutActivating() {
        #expect(EdgePopoutPolicy.ordersFrontRegardless(floating: true))
    }

    @Test func aSpaceChangeKeepsTheLens() {
        #expect(EdgePeekRouting.keepsLensOnSpaceChange(peekVisible: true))
        #expect(!EdgePeekRouting.keepsLensOnSpaceChange(peekVisible: false))
    }

    @Test func aPageOpenedFromTheLensStaysInTheLens() {
        #expect(EdgePeekRouting.newPage(peekVisible: true) == .peek)
        #expect(EdgePeekRouting.newPage(peekVisible: false) == .browser)
    }

    /// The mirror is made after the window's sidebar was set up, so its own bottom row has to be filled before the
    /// first show: otherwise a second space only appears after switching to it by another means.
    @Test func theMirrorHasItsSpacesBeforeTheFirstSwitch() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let current = Library.shared.spaces[0].id
        if Library.shared.spaces.count < 2 { _ = Library.shared.addSpace(name: "Other") }
        let manager = TabManager(spaceID: current)
        defer { manager.invalidate() }
        let controller = BrowserWindowController(tabManager: manager,
                                                 frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        let (mirror, _) = controller.edgeSidebarForDisplay()
        controller.prepareEdgeSidebar()
        #expect(mirror.hasSpaceKeys)
    }

    /// The bar above the page may hold the window's address, but the edge card has no bar: it keeps its own field,
    /// star and navigation controls, and lays them out.
    @Test func theMirrorKeepsItsAddressWhenTheWindowBarHoldsIt() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let current = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: current)
        defer { manager.invalidate() }
        let controller = BrowserWindowController(tabManager: manager,
                                                 frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        controller.sidebar.holdsAddress = false
        let (mirror, _) = controller.edgeSidebarForDisplay()
        controller.prepareEdgeSidebar()
        mirror.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        mirror.layoutSubtreeIfNeeded()
        #expect(mirror.holdsAddress)
        #expect(mirror.addressButtons.allSatisfy { !$0.isHidden })
        #expect(mirror.address.frame.height > 0)
        #expect(mirror.backButton.frame.width > 0)
        #expect(mirror.expandButton.frame.maxX <= mirror.backButton.frame.minX)
    }
}
