import AppKit

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
        get { MiniPeekMode(rawValue: defaults.string(forKey: key) ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: key) }
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
