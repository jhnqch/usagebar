import AppKit
import UsageCore

/// The status item's title: `✳ 61% · ⌘ 13%`, each number coloured by level.
enum MenuBarText {
    static func attributed(_ label: MenuBarLabel) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        func part(_ part: LabelPart) -> NSAttributedString {
            NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: Palette.menuBarText(part.level)])
        }
        let title = NSMutableAttributedString(string: "✳ ", attributes: plain)
        title.append(part(label.claude))
        title.append(NSAttributedString(string: " · ⌘ ", attributes: plain))
        title.append(part(label.codex))
        return title
    }

    static func accessibilityLabel(_ label: MenuBarLabel) -> String {
        "Usage. Claude \(label.claude.text). Codex \(label.codex.text)."
    }
}
