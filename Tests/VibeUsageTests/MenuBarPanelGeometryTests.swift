import AppKit
import Testing
@testable import VibeUsage

struct MenuBarPanelGeometryTests {
    @Test func rightAlignsPanelBelowStatusItem() {
        let point = MenuBarPanelGeometry.topLeftPoint(
            anchorFrame: NSRect(x: 1_300, y: 877, width: 24, height: 23),
            panelSize: NSSize(width: 520, height: 620),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 877),
            topGap: 6,
            edgeInset: 8
        )

        #expect(point.x == 804)
        #expect(point.y == 871)
    }

    @Test func clampsPanelToLeftEdgeOfSecondaryDisplay() {
        let point = MenuBarPanelGeometry.topLeftPoint(
            anchorFrame: NSRect(x: -1_910, y: 1_057, width: 24, height: 23),
            panelSize: NSSize(width: 520, height: 620),
            visibleFrame: NSRect(x: -1_920, y: 0, width: 1_920, height: 1_057),
            topGap: 6,
            edgeInset: 8
        )

        #expect(point.x == -1_912)
        #expect(point.y == 1_051)
    }

    @Test func keepsPanelInsideShortVisibleFrame() {
        let point = MenuBarPanelGeometry.topLeftPoint(
            anchorFrame: NSRect(x: 990, y: 700, width: 24, height: 23),
            panelSize: NSSize(width: 520, height: 620),
            visibleFrame: NSRect(x: 0, y: 90, width: 1_000, height: 610),
            topGap: 6,
            edgeInset: 8
        )

        #expect(point.x == 472)
        #expect(point.y == 700)
    }
}

// MARK: - Popover dismissal trigger

extension MenuBarPanelGeometryTests {
    /// The popover closes when focus lands on another application. Our own
    /// activation is the "user came back" direction, and an unknown bundle id
    /// is not evidence of a switch — the regression this pins: the app used to
    /// dismiss on `applicationWillResignActive`, which also fires when our own
    /// Settings window closes and flips the activation policy.
    @Test
    func popoverDismissesOnlyForAnotherApplication() {
        #expect(MenuBarController.shouldDismissPopover(
            forActivatedBundleID: "com.apple.finder",
            ownBundleID: "ai.vibecafe.vibe-usage"
        ))
        #expect(MenuBarController.shouldDismissPopover(
            forActivatedBundleID: "ai.vibecafe.vibe-usage",
            ownBundleID: "ai.vibecafe.vibe-usage"
        ) == false)
        #expect(MenuBarController.shouldDismissPopover(
            forActivatedBundleID: nil,
            ownBundleID: "ai.vibecafe.vibe-usage"
        ) == false)
    }
}
