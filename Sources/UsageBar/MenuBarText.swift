import AppKit
import UsageCore

/// The status item's title: `✳ 61% · ⌘ 13%`, each number coloured by level.
enum MenuBarText {
    static func attributed(_ label: MenuBarLabel) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let title = NSMutableAttributedString()
        for (index, part) in label.parts.enumerated() {
            title.append(NSAttributedString(string: (index == 0 ? "" : " · ") + part.symbol + " ", attributes: plain))
            title.append(NSAttributedString(
                string: part.value.text, attributes: [.font: font, .foregroundColor: Palette.menuBarText(part.value.level)]
            ))
        }
        return title
    }

    static func accessibilityLabel(_ label: MenuBarLabel) -> String {
        label.accessibilityText
    }
}
