# Mini Peek

The Mini that lives inside a browser page, for a ⇧-clicked link. Off by default (`MiniPeekMode`); one Peek per browser window.

- With the Peek on, ⇧-clicking a link in a page → the link's page opens in a Mini over that page, not in a tab or a separate window.
  Test: MiniFromPageTests.dockedURLPeekLivesInTheBrowserPage
- A second ⇧-click in the same window → replaces the first Peek; there is never more than one.
  Test: MiniPeekHostTests.onePeekReplacesThePrevious
- The Peek's page is a real tab in the page's space and profile; a private window's Peek is private.
  Test: MiniFromPageTests.privateWindowPeekUsesThePrivateStore
- Esc, a click outside, ⌘W, the host tab closing, the content tab closing, a tab switch or a Space change → the Peek ends, and its page closes with it.
  Test: MiniPeekHostTests.hostAndContentCloseCleanup
  Test: MiniPeekHostTests.selectingAnotherTabClosesThePeek
  Test: MiniPeekHostTests.escapeClosesThePeek
- The first Peek opens with the keyboard; coming back on a tab switch leaves the keyboard where the switch put it.
  Test: MiniFromPageTests.openTakesKeyboard
  Test: MiniFromPageTests.leavesKeyboardDoesNot
- The strip's first control is expand, before Back; it is shown only while the Mini is in the page.
  Test: MiniFromPageTests.peekShowsExpandBeforeNavigation
- Expand → the same root, tab and web view become a titled window with traffic lights, at the page's frame; the page keeps its viewport and scroll, with no reload.
  Test: MiniFromPageTests.expandPromotesTheSameMiniAndPageToAWindow
  Test: MiniFromPageTests.expandKeepsThePagesFrameAndScrollPosition
- Mouse side buttons over the Peek → its own history, not the browser's.
  Test: MiniFromPageTests.sideButtonsGoToThePeekUnderThePointer
- A ⇧-click a site handles itself with `window.open` → still the Peek; a sized pop-up stays a sign-in window.
  Test: MiniPeekPolicyTests.aShiftClickThePageHandlesIsStillThePeek
- The docked Mini wears the Mini's own chrome, at the strip's size, over a rounded dim that lets clicks through when it goes.
  Test: MiniPeekHostTests.dockedPeekWearsTheFullMiniChrome
  Test: MiniPeekHostTests.dockedDimMatchesThePageAndLetsClicksThroughWhenItGoes
- The docked Mini follows the page's size and place; full screen, a Space change and a minimize re-dock it.
  Test: MiniPeekHostTests.viewportChangeRefitsThePeek
  Test: MiniPeekHostTests.fullscreenRedocksThePeek
  Test: MiniPeekHostTests.minimizeAndAppSwitchKeepThePeek
- The mode is off by default; with it off, a ⇧-click opens the standalone Mini as before.
  Test: MiniPeekPolicyTests.modeDefaultsOff
  Test: MiniPeekHostTests.modeOffShiftClickFallsBackToTheStandaloneMini
