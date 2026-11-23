import AppKit
import Testing
@testable import Zigzag

@MainActor
struct EdgePeekPreviewTests {
    @Test func thePreviewStaysAwayWhileThePeekIsOut() {
        #expect(EdgePeekPreviewPolicy.shouldShow(hovered: true, peekVisible: false))
        #expect(!EdgePeekPreviewPolicy.shouldShow(hovered: true, peekVisible: true))
        #expect(!EdgePeekPreviewPolicy.shouldShow(hovered: false, peekVisible: false))
    }

    @Test func theEdgePreviewKeepsItsPictureAreaForAPageWithANote() {
        // Pinned and tiled pages often arrive with a "not loaded" note. The edge card has a fixed frame, so if the
        // note measured after the card appeared, the picture would shrink under its entrance.
        let card = TabPreviewView(frame: NSRect(x: 0, y: 0, width: 236, height: 176))
        let tab = Tab(url: URL(string: "https://example.com/")!, title: "Example", spaceID: UUID())
        card.show(tab: tab, bookmark: nil)
        card.layoutSubtreeIfNeeded()
        let area = card.pictureArea
        #expect((card.declaredFooter ?? 0) > TabPreviewView.footerHeight)

        // The note goes when the page starts running; the picture stays where it first declared it.
        card.show(tab: nil, bookmark: nil)
        card.layoutSubtreeIfNeeded()
        #expect(card.pictureArea == area)
    }
}
