import AppKit
import SwiftUI
import UsageCore

/// Layout-A colours, one light/dark pair per token.
struct Palette {
    var isDark: Bool

    init(_ scheme: ColorScheme) { isDark = scheme == .dark }

    var popover: Color { pick(0xF7F7F8, 0x2A2A2E) }
    var text: Color { pick(0x1D1D1F, 0xF2F2F5) }
    var muted: Color { pick(0x5F5F66, 0xABABB3) }
    var track: Color { pick(0xE2E2E6, 0x3D3D44) }
    var border: Color { isDark ? .white.opacity(0.14) : .black.opacity(0.12) }
    var divider: Color { isDark ? .white.opacity(0.09) : .black.opacity(0.08) }
    var button: Color { isDark ? .white.opacity(0.08) : .black.opacity(0.05) }
    /// Outline of a day still to come in the cost chart.
    var dash: Color { pick(0xC3C3CA, 0x5A5A63) }
    // Snapshot-mode backdrop and menu bar strip.
    var wall: Color { pick(0x7A8A99, 0x1B2530) }
    var menuBar: Color { pick(0xECECEF, 0x232327) }

    func fill(_ level: Level) -> Color {
        switch level {
        case .normal: pick(0x2563EB, 0x5B93FF)
        case .warning: pick(0xF08A1C, 0xF5A142)
        case .maxed: pick(0xD93A30, 0xFF6B5E)
        }
    }

    /// A model's colour in the cost chart, by its slot: Opus, Fable, Sonnet,
    /// Haiku (for Codex: Astra, Terra, Sol, Luna), then extra models, then a
    /// shared grey. The categorical
    /// palette from the dataviz skill, in its validated order (adjacent
    /// pairs separable under colour-vision deficiency, light and dark,
    /// against this popover's surfaces).
    func series(_ slot: Int) -> Color {
        let steps: [(UInt32, UInt32)] = [
            (0x2A78D6, 0x3987E5), // blue: Opus
            (0xEB6834, 0xD95926), // orange: Fable
            (0x1BAF7A, 0x199E70), // aqua: Sonnet
            (0xEDA100, 0xC98500), // yellow: Haiku
            (0xE87BA4, 0xD55181), // magenta
            (0x008300, 0x008300), // green
            (0x6250D6, 0x9085E9), // violet
            (0xE34948, 0xE66767), // red
            (0x8E8E96, 0x7A7A82), // grey: any further model
        ]
        let step = steps[min(max(slot, 0), steps.count - 1)]
        return pick(step.0, step.1)
    }

    func text(_ level: Level) -> Color {
        Color(nsColor: Self.levelText(level, dark: isDark))
    }

    private func pick(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: .hex(isDark ? dark : light))
    }

    /// Text colour for a level: the default text colour when normal, orange
    /// from 90%, red at 100%.
    static func levelText(_ level: Level, dark: Bool) -> NSColor {
        switch level {
        case .normal: .hex(dark ? 0xF2F2F5 : 0x1D1D1F)
        case .warning: .hex(dark ? 0xF7B162 : 0xA24F00)
        case .maxed: .hex(dark ? 0xFF8F84 : 0xB42318)
        }
    }

    /// The level colour for the real menu bar, resolved against the menu
    /// bar's own (light or dark) appearance when drawn.
    static func menuBarText(_ level: Level) -> NSColor {
        if level == .normal { return .labelColor }
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
            return levelText(level, dark: dark == .darkAqua || dark == .vibrantDark)
        }
    }
}

extension NSColor {
    static func hex(_ rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
