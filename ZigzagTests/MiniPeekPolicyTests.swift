import AppKit
import Foundation
import Testing
@testable import Zigzag

/// The docked Peek's switch and its pure rules, before anything is built on them.
@Suite(.serialized)
struct MiniPeekPolicyTests {
    private let suiteName = "wang.zigao.zigzag.tests.minipeek"

    /// Runs `body` with a defaults suite of its own: no test writes the build's settings, or another suite's.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test func modeDefaultsOff() {
        withDefaults { defaults in
            #expect(MiniPeekSettings.mode(in: defaults) == .off)
        }
    }

    @Test func modeRoundTrips() {
        withDefaults { defaults in
            for mode in MiniPeekMode.allCases {
                MiniPeekSettings.setMode(mode, in: defaults)
                #expect(defaults.string(forKey: MiniPeekSettings.key) == mode.rawValue)
                #expect(MiniPeekSettings.mode(in: defaults) == mode)
            }
            // Anything else in the setting is the safe default, not a crash or a hidden Peek.
            defaults.set("something else", forKey: MiniPeekSettings.key)
            #expect(MiniPeekSettings.mode(in: defaults) == .off)
        }
    }

    @Test func docksOnlyInAFrontWindow() {
        #expect(MiniPeekPolicy.shouldDock(mode: .keep, windowIsKey: true, windowIsVisible: true,
                                          windowIsMiniaturized: false, windowIsOnActiveSpace: true))
        #expect(MiniPeekPolicy.shouldDock(mode: .close, windowIsKey: true, windowIsVisible: true,
                                          windowIsMiniaturized: false, windowIsOnActiveSpace: true))
        #expect(!MiniPeekPolicy.shouldDock(mode: .off, windowIsKey: true, windowIsVisible: true,
                                           windowIsMiniaturized: false, windowIsOnActiveSpace: true))
        for front in [
            (key: false, visible: true, miniaturized: false, active: true),
            (key: true, visible: false, miniaturized: false, active: true),
            (key: true, visible: true, miniaturized: true, active: true),
            (key: true, visible: true, miniaturized: false, active: false),
        ] {
            #expect(!MiniPeekPolicy.shouldDock(mode: .keep, windowIsKey: front.key, windowIsVisible: front.visible,
                                                windowIsMiniaturized: front.miniaturized,
                                                windowIsOnActiveSpace: front.active))
        }
    }

    @Test func visibleOnlyForTheSelectedHost() {
        let a = UUID(), b = UUID()
        #expect(MiniPeekPolicy.isVisible(hostTabID: a, selectedTabID: a))
        #expect(!MiniPeekPolicy.isVisible(hostTabID: a, selectedTabID: b))
        #expect(!MiniPeekPolicy.isVisible(hostTabID: nil, selectedTabID: a))
        #expect(!MiniPeekPolicy.isVisible(hostTabID: a, selectedTabID: nil))
        #expect(!MiniPeekPolicy.isVisible(hostTabID: nil, selectedTabID: nil))
    }

    @Test func everyModeWithAPeekClosesOnSelectionChange() {
        #expect(MiniPeekPolicy.closesOnSelectionChange(mode: .close))
        #expect(MiniPeekPolicy.closesOnSelectionChange(mode: .keep))
        #expect(!MiniPeekPolicy.closesOnSelectionChange(mode: .off))
    }

    @Test func spaceChangePolicy() {
        // The old Peek closed on a real Space change, but not on the one entering or leaving full screen brings.
        #expect(MiniPeekPolicy.spaceChangeCloses(mode: .close, phase: .windowed))
        #expect(MiniPeekPolicy.spaceChangeCloses(mode: .close, phase: .fullScreen))
        #expect(!MiniPeekPolicy.spaceChangeCloses(mode: .close, phase: .entering))
        #expect(!MiniPeekPolicy.spaceChangeCloses(mode: .close, phase: .exiting))
        #expect(MiniPeekPolicy.spaceChangeCloses(mode: .keep, phase: .windowed))
        #expect(!MiniPeekPolicy.spaceChangeCloses(mode: .off, phase: .windowed))
    }
}
