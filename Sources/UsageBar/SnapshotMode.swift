import AppKit
import SwiftUI
import UsageCore

/// `UsageBar --snapshot <fixture.json> <out.png> [--screen-height <pt>]`:
/// renders the menu bar text and the popover for a fixture, light and dark
/// side by side, then exits. With `--screen-height`, the popover is capped
/// as the app caps it on a screen with that much visible height: light
/// shows its sections scrolled to the top, dark scrolled to the bottom.
enum SnapshotMode {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    @MainActor
    static func render(fixturePath: String, outputPath: String, screenHeight: CGFloat? = nil) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let fixture = try Fixture.decode(data)
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)

        let scene: AnyView
        if let screenHeight {
            let cap = PopoverFit.maxHeight(visibleHeight: screenHeight)
            print(measure(snapshot, cap: cap, screenHeight: screenHeight))
            scene = AnyView(HStack(alignment: .top, spacing: 0) {
                SnapshotScene(snapshot: snapshot, height: .cappedPreview(cap, atBottom: false), screenHeight: screenHeight)
                    .environment(\.colorScheme, .light)
                SnapshotScene(snapshot: snapshot, height: .cappedPreview(cap, atBottom: true), screenHeight: screenHeight)
                    .environment(\.colorScheme, .dark)
            })
        } else {
            scene = AnyView(HStack(alignment: .top, spacing: 0) {
                SnapshotScene(snapshot: snapshot).environment(\.colorScheme, .light)
                SnapshotScene(snapshot: snapshot).environment(\.colorScheme, .dark)
            })
        }
        let renderer = ImageRenderer(content: scene)
        renderer.scale = 2
        guard
            let image = renderer.cgImage,
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw Failure(description: "could not render the popover") }
        try png.write(to: URL(fileURLWithPath: outputPath))
    }

    /// Lays out the popover the app shows, capped, in an offscreen window,
    /// and reports its height and how far its scroll view scrolls.
    /// `ImageRenderer` can't draw a scroll view, so this is the check that
    /// the picture's clipping matches the real thing.
    @MainActor
    private static func measure(_ snapshot: UsageSnapshot, cap: CGFloat, screenHeight: CGFloat) -> String {
        func host(_ height: PopoverView.Height) -> NSHostingController<some View> {
            let host = NSHostingController(rootView: PopoverView(snapshot: snapshot, height: height))
            host.sizingOptions = .preferredContentSize
            return host
        }
        let full = host(.full)
        _ = full.view
        full.view.layoutSubtreeIfNeeded()
        let capped = host(.capped(cap))
        let window = NSWindow(contentViewController: capped)
        window.setContentSize(capped.preferredContentSize)
        capped.view.layoutSubtreeIfNeeded()
        var line = "screen \(Int(screenHeight)) pt visible: popover \(Int(capped.preferredContentSize.height)) pt"
            + " (cap \(Int(cap)), full height \(Int(full.preferredContentSize.height)))"
        if let scroll = scrollView(in: capped.view), let document = scroll.documentView {
            line += "; scroll view shows \(Int(scroll.contentView.bounds.height)) of \(Int(document.frame.height)) pt"
        }
        return line
    }

    @MainActor
    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }
}

/// The menu bar strip with the status item text, and the popover under it.
/// Given a screen height, the scene is that screen: the menu bar, then its
/// visible height.
private struct SnapshotScene: View {
    var snapshot: UsageSnapshot
    var height: PopoverView.Height = .full
    var screenHeight: CGFloat? = nil

    @Environment(\.colorScheme) private var scheme

    private static let menuBarHeight: CGFloat = 28

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
            .frame(height: Self.menuBarHeight)
            .background(palette.menuBar)

            PopoverView(snapshot: snapshot, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.border, lineWidth: 1))
                .compositingGroup()
                .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
                .padding([.horizontal, .bottom], 20)
        }
        .frame(height: screenHeight.map { Self.menuBarHeight + $0 }, alignment: .top)
        .overlay(alignment: .bottomLeading) {
            if let screenHeight, case let .cappedPreview(cap, atBottom) = height {
                Text("\(Int(screenHeight)) pt screen · popover capped at \(Int(cap)) pt · \(atBottom ? "scrolled to the bottom" : "at the top")")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(8)
            }
        }
        .background(palette.wall)
    }

    private var menuBarText: Text {
        let palette = Palette(scheme)
        return snapshot.menuBar.parts.enumerated().reduce(Text("")) { text, element in
            let (index, part) = element
            let value = Text(part.value.text).foregroundStyle(palette.text(part.value.level))
            return Text("\(text)\(index == 0 ? "" : " · ")\(part.symbol) \(value)")
        }
    }
}
