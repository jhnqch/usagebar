import AppKit
import UsageCore

/// The status item's title: `✳ 61% · ⌘ 13%`, each number coloured by level.
/// `MenuBarLabel.runs` decides the pieces; this only styles them.
enum MenuBarText {
    static func attributed(_ label: MenuBarLabel) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let title = NSMutableAttributedString()
        for run in label.runs {
            let color = run.level.map(Palette.menuBarText) ?? NSColor.labelColor
            title.append(NSAttributedString(string: run.text, attributes: [.font: font, .foregroundColor: color]))
        }
        return title
    }

    static func accessibilityLabel(_ label: MenuBarLabel) -> String {
        label.accessibilityText
    }

    /// Shown alone when no provider has a part: nothing is on, or every
    /// part is turned off.
    static var neutralIcon: NSImage? {
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "UsageBar")
        image?.isTemplate = true
        return image
    }
}
