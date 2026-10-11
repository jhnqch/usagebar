import AppKit
import SwiftUI
import UsageCore

/// `UsageBar --snapshot <fixture.json> <out.png>`: renders the menu bar text
/// and the popover for a fixture, light and dark side by side, then exits.
enum SnapshotMode {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    @MainActor
    static func render(fixturePath: String, outputPath: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let fixture = try Fixture.decode(data)
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)

        let scene = HStack(alignment: .top, spacing: 0) {
            SnapshotScene(snapshot: snapshot).environment(\.colorScheme, .light)
            SnapshotScene(snapshot: snapshot).environment(\.colorScheme, .dark)
        }
        let renderer = ImageRenderer(content: scene)
        renderer.scale = 2
        guard
            let image = renderer.cgImage,
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw Failure(description: "could not render the popover") }
        try png.write(to: URL(fileURLWithPath: outputPath))
    }
}

/// The menu bar strip with the status item text, and the popover under it.
private struct SnapshotScene: View {
    var snapshot: UsageSnapshot

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        VStack(alignment: .trailing, spacing: 6) {
            HStack {
                Spacer()
                menuBarText
                    .font(.system(size: 13).monospacedDigit())
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(palette.text.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(palette.menuBar)

            PopoverView(snapshot: snapshot)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.border, lineWidth: 1))
                .compositingGroup()
                .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
                .padding([.horizontal, .bottom], 20)
        }
        .background(palette.wall)
    }

    private var menuBarText: Text {
        let palette = Palette(scheme)
        let label = snapshot.menuBar
        let claude = Text(label.claude.text).foregroundStyle(palette.text(label.claude.level))
        let codex = Text(label.codex.text).foregroundStyle(palette.text(label.codex.level))
        return Text("✳ \(claude) · ⌘ \(codex)")
    }
}
