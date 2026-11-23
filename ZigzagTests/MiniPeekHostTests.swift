import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// The one Peek a window owns: replaced by a second ⇧-click, closed by its tab or Space, and gone with its pages.
@MainActor
struct MiniPeekHostTests {
    private func inWindow(_ titles: [String] = ["A", "B", "C"],
                          _ body: (BrowserWindowController, [Tab]) async throws -> Void) async rethrows {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tabs = titles.map { title in
            manager.newTab(url: URL(string: "https://example.com/\(title.lowercased())"), spaceID: space)
        }
        manager.select(tabs[0])
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.miniPeeks.modeProvider = { .keep }
        controller.window?.layoutIfNeeded()
        try await body(controller, tabs)
    }

    private func open(_ url: String, in controller: BrowserWindowController, from host: Tab) -> Bool {
        controller.miniPeeks.openURL(url: URL(string: url), configuration: nil, opener: host, by: .page)
    }

    @Test func onePeekReplacesThePrevious() async throws {
        try await inWindow { controller, tabs in
            #expect(open("https://example.com/first", in: controller, from: tabs[0]))
            let first = try #require(controller.miniPeeks.records[tabs[0].id]?.controller)
            let firstPage = first.tab
            #expect(controller.miniPeeks.records.count == 1)
            // A second Peek in the same tab replaces the first, as the old Peek did.
            #expect(open("https://example.com/second", in: controller, from: tabs[0]))
            #expect(controller.miniPeeks.records.count == 1)
            #expect(controller.miniPeeks.records[tabs[0].id]?.controller !== first)
            #expect(firstPage.isClosed)
            #expect(!MiniWindowController.all.contains { $0 === first })
            controller.miniPeeks.windowClosing()
            #expect(controller.miniPeeks.records.isEmpty)
        }
    }

    @Test func hostAndContentCloseCleanup() async throws {
        try await inWindow { controller, tabs in
            // The content tab closing ends its Peek.
            #expect(open("https://example.com/first", in: controller, from: tabs[0]))
            let content = try #require(controller.miniPeeks.records[tabs[0].id]?.content.tab)
            let controllerOfContent = try #require(controller.miniPeeks.records[tabs[0].id]?.controller)
            content.close()
            controller.miniPeeks.tabsChanged()
            #expect(controller.miniPeeks.records.isEmpty)
            #expect(!MiniWindowController.all.contains { $0 === controllerOfContent })

            // The host tab closing ends its Peek and its URL page, with no controller left.
            #expect(open("https://example.com/again", in: controller, from: tabs[0]))
            let page = try #require(controller.miniPeeks.records[tabs[0].id]?.content.tab)
            let peek = try #require(controller.miniPeeks.records[tabs[0].id]?.controller)
            controller.tabManager.close(tabs[0])
            controller.miniPeeks.tabsChanged()
            #expect(controller.miniPeeks.records.isEmpty)
            #expect(page.isClosed)
            #expect(!MiniWindowController.all.contains { $0 === peek })
        }
    }

    @Test func modeOffClosesThePeek() async throws {
        try await inWindow { controller, tabs in
            #expect(open("https://example.com/a", in: controller, from: tabs[0]))
            let page = try #require(controller.miniPeeks.records[tabs[0].id]?.content.tab)
            let peek = try #require(controller.miniPeeks.records[tabs[0].id]?.controller)
            controller.miniPeeks.modeProvider = { .off }
            controller.miniPeeks.modeChanged()
            #expect(controller.miniPeeks.records.isEmpty)
            #expect(page.isClosed)
            #expect(!MiniWindowController.all.contains { $0 === peek })
            #expect(controller.root.miniPeekDim == nil)
        }
    }

    @Test func selectingAnotherTabClosesThePeek() async throws {
        try await inWindow { controller, tabs in
            #expect(open("https://example.com/a", in: controller, from: tabs[0]))
            let page = try #require(controller.miniPeeks.records[tabs[0].id]?.content.tab)
            let peek = try #require(controller.miniPeeks.records[tabs[0].id]?.controller)
            #expect(peek.isDockShown && peek.isEmbeddedPeek)

            controller.tabManager.select(tabs[1])
            #expect(controller.miniPeeks.records.isEmpty)
            #expect(page.isClosed)
            #expect(!MiniWindowController.all.contains { $0 === peek })
            #expect(peek.overlay.window == nil)
            #expect(controller.root.miniPeekDim == nil)
            // The host tab's own page is still there; only the Peek's URL tab went with it.
            #expect(!tabs[0].isClosed)
            // The outgoing Peek's page no longer has the keyboard; the browser keeps it for the new tab.
            #expect(controller.tabManager.selectedTab === tabs[1])
            #expect(controller.window?.firstResponder !== peek.tab.webView)
            #expect(!tabs[1].isClosed)
        }
    }

    @Test func aSpaceChangeWithNoHostTabClosesThePeek() async throws {
        try await inWindow { controller, tabs in
            #expect(open("https://example.com/space", in: controller, from: tabs[0]))
            let page = try #require(controller.miniPeeks.records[tabs[0].id]?.content.tab)
            // A Space change settles on no tab from the old Space: the Peek goes before the new page draws.
            controller.miniPeeks.willSelect(nil)
            #expect(controller.miniPeeks.records.isEmpty)
            #expect(page.isClosed)
            #expect(!tabs[0].isClosed)
        }
    }

    @Test func explicitMiniStaysStandalone() async throws {
        try await inWindow { controller, tabs in
            let page = controller.openInMini(URL(string: "https://example.com/menu"), configuration: nil, opener: tabs[0])
            #expect(page != nil)
            let mini = try #require(MiniWindowController.all.last)
            #expect(!mini.isDockedPeek)
            #expect(controller.miniPeeks.records.isEmpty)
            mini.window?.close()
        }
    }

    @Test func modeOffShiftClickFallsBackToTheStandaloneMini() async throws {
        try await inWindow { controller, tabs in
            // The test defaults have no mode set: ⇧-click is today's standalone Mini.
            controller.open(URL(string: "https://example.com/plain")!, disposition: .miniPeek, opener: tabs[0], by: .page)
            let mini = try #require(MiniWindowController.all.last)
            #expect(!mini.isDockedPeek)
            #expect(controller.miniPeeks.records.isEmpty)
            mini.window?.close()
        }
    }

    @Test func closeModeClosesOnTabSwitch() async throws {
        try await inWindow { controller, tabs in
            controller.miniPeeks.modeProvider = { .close }
            #expect(open("https://example.com/close", in: controller, from: tabs[0]))
            let page = try #require(controller.miniPeeks.records[tabs[0].id]?.content.tab)
            let peek = try #require(controller.miniPeeks.records[tabs[0].id]?.controller)
            controller.tabManager.select(tabs[1])
            #expect(controller.miniPeeks.records.isEmpty)
            #expect(page.isClosed)
            #expect(!tabs[0].isClosed)
            #expect(!MiniWindowController.all.contains { $0 === peek })
            #expect(controller.root.miniPeekDim == nil)
        }
    }

    @Test func aSecondClickInAnotherPaneReplacesTheFirst() async throws {
        try await inWindow { controller, tabs in
            controller.tabManager.makeSplit(tabs[0], with: tabs[1])
            controller.tabManager.select(tabs[0])
            #expect(open("https://example.com/a", in: controller, from: tabs[0]))
            let first = try #require(controller.miniPeeks.records[tabs[0].id]?.controller)
            let firstPage = first.tab

            controller.tabManager.select(tabs[1])
            // The selection change closes the first Peek, as the old Peek did.
            #expect(controller.miniPeeks.records.isEmpty)
            #expect(firstPage.isClosed)
            #expect(!MiniWindowController.all.contains { $0 === first })
            #expect(open("https://example.com/b", in: controller, from: tabs[1]))
            let second = try #require(controller.miniPeeks.records[tabs[1].id]?.controller)
            #expect(controller.miniPeeks.records.count == 1)
            #expect(second.isEmbeddedPeek && second.overlay.window === controller.window)

            controller.tabManager.select(tabs[0])
            #expect(controller.miniPeeks.records.isEmpty)
            #expect(!MiniWindowController.all.contains { $0 === second })
        }
    }

    @Test func keepURLInsertsAfterTheOpener() async throws {
        try await inWindow { controller, tabs in
            #expect(open("https://example.com/keep", in: controller, from: tabs[0]))
            let page = try #require(controller.miniPeeks.records[tabs[0].id]?.content.tab)
            controller.miniPeeks.keepShown()
            for _ in 0..<200 where !controller.tabManager.tabs(in: controller.tabManager.currentSpaceID).contains(where: { $0 === page }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            let list = controller.tabManager.tabs(in: controller.tabManager.currentSpaceID)
            let at = try #require(list.firstIndex { $0 === tabs[0] })
            #expect(list.indices.contains(at + 1) && list[at + 1] === page)
            #expect(controller.tabManager.selectedTab === page)
            #expect(controller.miniPeeks.records.isEmpty)
            #expect(!page.isClosed)
        }
    }

    @Test func fullscreenRedocksThePeek() async throws {
        try await inWindow { controller, tabs in
            #expect(open("https://example.com/full", in: controller, from: tabs[0]))
            let mini = try #require(controller.miniPeeks.records[tabs[0].id]?.controller)
            let notification = Notification(name: NSWindow.willEnterFullScreenNotification, object: controller.window)

            controller.windowWillEnterFullScreen(notification)
            controller.windowDidEnterFullScreen(notification)
            #expect(mini.isDockedPeek && mini.isDockShown && mini.isEmbeddedPeek)
            #expect(mini.overlay.isDescendant(of: controller.root))
            #expect(controller.miniPeeks.records[tabs[0].id] != nil)

            // The full-screen page is larger: the Peek re-fits inside it, still docked.
            var frame = try #require(controller.window?.frame)
            frame.size = NSSize(width: 1400, height: 900)
            controller.window?.setFrame(frame, display: false)
            controller.root.needsLayout = true
            controller.root.layoutSubtreeIfNeeded()
            let rootFrame = try #require(mini.overlay.superview?.frame)
            #expect(controller.root.cardFrame.contains(rootFrame))

            controller.windowWillExitFullScreen(notification)
            controller.windowDidExitFullScreen(notification)
            #expect(mini.isDockedPeek && mini.isDockShown)
            controller.miniPeeks.windowClosing()
        }
    }

    @Test func minimizeAndAppSwitchKeepThePeek() async throws {
        try await inWindow { controller, tabs in
            #expect(open("https://example.com/space", in: controller, from: tabs[0]))
            let mini = try #require(controller.miniPeeks.records[tabs[0].id]?.controller)

            NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: controller.window)
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

            #expect(controller.miniPeeks.records[tabs[0].id] != nil)
            #expect(mini.isDockedPeek)
            #expect(MiniWindowController.all.contains { $0 === mini })
            controller.miniPeeks.windowClosing()
        }
    }

    @Test func windowCloseClosesThePeek() async throws {
        try await inWindow { controller, tabs in
            #expect(open("https://example.com/a", in: controller, from: tabs[0]))
            let page = try #require(controller.miniPeeks.records[tabs[0].id]?.content.tab)
            let peek = try #require(controller.miniPeeks.records[tabs[0].id]?.controller)
            controller.window?.close()
            #expect(controller.miniPeeks.records.isEmpty)
            #expect(page.isClosed)
            #expect(!MiniWindowController.all.contains { $0 === peek })
        }
    }

    @Test func dockedPeekWearsTheFullMiniChrome() async throws {
        try await inWindow { controller, tabs in
            #expect(open("https://example.com/chrome", in: controller, from: tabs[0]))
            let peek = try #require(controller.miniPeeks.records[tabs[0].id]?.controller)
            let state = peek.debugState
            // The page fills the Mini and the strip waits above it, as in the Mini.
            #expect(state["chromeOverlay"] as? Bool == true)
            #expect(state["chromeRevealed"] as? Bool == false)
            // The whole strip is there, not a reduced header.
            let frames = try #require(state["strip"] as? [String: [CGFloat]])
            for control in ["back", "forward", "reload", "space", "title", "site", "pin", "copy", "open"] {
                #expect((frames[control]?.first ?? 0) > 0, "\(control)")
            }
            // Keep on Top would lift the child off its browser: the pin says so and cannot be used.
            #expect(state["pinEnabled"] as? Bool == false)
            #expect(state["pinTip"] as? String == String(localized: "Not while docked", comment: "Tooltip on Zigzag Mini's Keep on Top pin while the Mini is docked over a page: the pin can't be used there."))
            // The debug bridge can see the record and the window it lives in.
            #expect(state["peekMode"] as? String != nil)
            #expect(state["hostTab"] as? String == tabs[0].id.uuidString)
            #expect(state["contentTab"] as? String == (controller.miniPeeks.records[tabs[0].id]?.content.tab.id.uuidString ?? ""))
            #expect(state["borrowed"] as? Bool == false)
            #expect(state["suspended"] as? Bool == false)
            #expect(state["embedded"] as? Bool == true)
            #expect((state["pane"] as? [CGFloat])?.count == 4)
            #expect((state["frame"] as? [CGFloat])?.count == 4)
            #expect((state["dim"] as? [CGFloat])?.count == 4)
            let record = try #require(controller.miniPeeks.debugState.first)
            #expect(record["hostTab"] as? String == tabs[0].id.uuidString)
            #expect(record["shown"] as? Bool == true)
            #expect(record["borrowed"] as? Bool == false)
            let window = try #require(peek.window)
            let level = window.level
            peek.toggleKeepOnTop()
            #expect(window.level == level)
            #expect(!KeepOnTop.isOn(window))
            controller.miniPeeks.windowClosing()
        }
    }

    @Test func dockedDimMatchesThePageAndLetsClicksThroughWhenItGoes() async throws {
        try await inWindow { controller, tabs in
            #expect(open("https://example.com/dim", in: controller, from: tabs[0]))
            let dim = try #require(controller.root.miniPeekDim as? MiniPeekDimView)
            #expect(dim.frame == controller.root.cardFrame)
            #expect(dim.layer?.cornerRadius == Tokens.Radius.card)
            #expect(dim.layer?.cornerCurve == .continuous)
            #expect(!dim.mouseDownCanMoveWindow)

            let peek = try #require(controller.miniPeeks.records[tabs[0].id]?.controller)
            peek.closePeek(animated: false)
            // The page behind is never left dimmed.
            #expect(controller.root.miniPeekDim == nil)
            #expect(dim.superview == nil)
            controller.miniPeeks.windowClosing()
        }
    }

    @Test func escapeClosesThePeek() async throws {
        try await inWindow { controller, tabs in
            #expect(open("https://example.com/escape", in: controller, from: tabs[0]))
            let peek = try #require(controller.miniPeeks.records[tabs[0].id]?.controller)
            let page = peek.tab
            #expect(controller.miniPeeks.escapePressed())
            #expect(controller.miniPeeks.records.isEmpty)
            for _ in 0..<200 where !page.isClosed { try await Task.sleep(for: .milliseconds(10)) }
            #expect(page.isClosed)
            #expect(!controller.miniPeeks.escapePressed())
        }
    }

    /// The fixed sidebar opens and closes: the page grows and shrinks under the Peek, which follows without closing.
    @Test func viewportChangeRefitsThePeek() async throws {
        try await inWindow { controller, tabs in
            #expect(open("https://example.com/fit", in: controller, from: tabs[0]))
            let mini = try #require(controller.miniPeeks.records[tabs[0].id]?.controller)
            // The fixed sidebar opens and closes: the page grows and shrinks under the Peek.
            controller.root.sidebarVisible = false
            controller.root.needsLayout = true
            controller.root.layoutSubtreeIfNeeded()
            #expect(mini.isDockedPeek)
            #expect(controller.miniPeeks.records[tabs[0].id] != nil)

            controller.root.sidebarVisible = true
            controller.root.needsLayout = true
            controller.root.layoutSubtreeIfNeeded()
            let rootFrame = try #require(mini.overlay.superview?.frame)
            #expect(mini.isDockedPeek)
            #expect(controller.root.cardFrame.contains(rootFrame))
            #expect(controller.root.miniPeekDim?.frame == controller.root.cardFrame)
            controller.miniPeeks.windowClosing()
        }
    }
}
