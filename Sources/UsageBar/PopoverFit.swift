import AppKit
import Observation

/// How tall the popover may be. It hangs from the menu bar, so it gets the
/// screen's visible height (under the menu bar, above the Dock) less room
/// for its arrow and a gap above the bottom edge. Past that, its sections
/// scroll.
@MainActor
@Observable
final class PopoverFit {
    var maxHeight: CGFloat = PopoverFit.maxHeight(on: NSScreen.main)

    /// The popover's arrow and a gap at the bottom.
    static let margin: CGFloat = 40
    /// Never squeeze it below this, however small the screen.
    static let minimum: CGFloat = 240

    static func maxHeight(visibleHeight: CGFloat) -> CGFloat {
        max(visibleHeight - margin, minimum)
    }

    static func maxHeight(on screen: NSScreen?) -> CGFloat {
        // With no screen at all, don't cap it.
        guard let screen else { return .greatestFiniteMagnitude }
        return maxHeight(visibleHeight: screen.visibleFrame.height)
    }
}
