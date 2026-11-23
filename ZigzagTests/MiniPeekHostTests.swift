import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// The Peeks one window owns: one record per host tab, hidden with its tab and gone with its pages.
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

    @Test func oneRecordPerHostAndReplace() async throws {
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

    @Test func modeOffClosesAll() async throws {
        try await inWindow { controller, tabs in
            #expect(open("https://example.com/a", in: controller, from: tabs[0]))
            controller.tabManager.select(tabs[1])
            #expect(open("https://example.com/b", in: controller, from: tabs[1]))
            #expect(controller.miniPeeks.records.count == 2)
            let controllers = controller.miniPeeks.records.values.map(\.controller)
            controller.miniPeeks.modeProvider = { .off }
            controller.miniPeeks.modeChanged()
            #expect(controller.miniPeeks.records.isEmpty)
            #expect(controllers.allSatisfy { peek in !MiniWindowController.all.contains { $0 === peek } })
            #expect(controller.root.miniPeekDim == nil)
        }
    }

    @Test func willSelectHidesAndDidSelectShows() async throws {
        try await inWindow { controller, tabs in
            #expect(open("https://example.com/a", in: controller, from: tabs[0]))
            let page = try #require(controller.miniPeeks.records[tabs[0].id]?.content.tab)
            let peek = try #require(controller.miniPeeks.records[tabs[0].id]?.controller)
            let frame = try #require(peek.window?.frame)
            #expect(peek.isDockShown)

            controller.tabManager.select(tabs[1])
            #expect(controller.miniPeeks.records[tabs[0].id]?.isShown == false)
            #expect(peek.isDockShown == false)
            #expect(peek.window?.isVisible == false)
            #expect(controller.root.miniPeekDim == nil)
            #expect(MiniWindowController.all.contains { $0 === peek })

            controller.tabManager.select(tabs[0])
            #expect(controller.miniPeeks.records[tabs[0].id]?.isShown == true)
            #expect(peek.isDockShown && peek.window?.isVisible == true)
            #expect(controller.root.miniPeekDim != nil)
            // The same live page, at the same place: no reload, no jump.
            #expect(peek.tab === page)
            #expect(peek.window?.frame == frame)
            #expect(peek.debugState["focus"] as? String == "leavesKeyboard")
            controller.miniPeeks.windowClosing()
        }
    }

    @Test func modeOffLeavesTheShiftMeaningAlone() async throws {
        try await inWindow { controller, tabs in
            controller.miniPeeks.modeProvider = { .off }
            #expect(!controller.listPeek(tabs[1]))
            #expect(controller.miniPeeks.records.isEmpty)
            #expect(controller.tabManager.selectedTab === tabs[0])
        }
    }

    @Test func sidebarShiftOpensBorrowedPeek() async throws {
        try await inWindow { controller, tabs in
            #expect(controller.listPeek(tabs[1]))
            let record = try #require(controller.miniPeeks.records[tabs[0].id])
            guard case .borrowed(let content) = record.content else {
                Issue.record("The sidebar Peek should borrow the tab")
                return
            }
            #expect(content === tabs[1])
            #expect(record.isShown && record.controller.isDockedPeek)
            #expect(controller.root.miniPeekDim != nil)
            // The selected tab does not change, and the page is in the Peek, not its card.
            #expect(controller.tabManager.selectedTab === tabs[0])
            #expect(content.pageHolder?.window === record.controller.window)
            controller.miniPeeks.windowClosing()
        }
    }

    @Test func pinnedPageShiftOpensBorrowedPeek() async throws {
        try await inWindow { controller, tabs in
            let bookmark = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/pin")!,
                                                                   title: "Pin", to: controller.tabManager.currentSpaceID))
            controller.tabManager.openBookmark(bookmark)
            let pinned = try #require(controller.tabManager.bookmarkTab(for: bookmark.id))
            controller.tabManager.select(tabs[0])
            #expect(controller.listPeek(pinned))
            guard case .borrowed(let content)? = controller.miniPeeks.records[tabs[0].id]?.content else {
                Issue.record("The pinned page should be borrowed")
                return
            }
            #expect(content === pinned)
            #expect(controller.tabManager.selectedTab === tabs[0])
            controller.miniPeeks.windowClosing()
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
}
