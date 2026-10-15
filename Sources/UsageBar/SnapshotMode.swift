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
        let snapshot = UsageEngine.snapshot(
            from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone, selection: fixture.selection
        )

        // The Providers menu as the app would build it for this fixture,
        // with the fixture's providers on and taken as detected (a key
        // provider's key as saved). The example key provider is listed
        // only when the fixture shows it.
        let shownIDs = Set(fixture.readings.providers.map(\.id))
        let catalog = BuiltInProviders.catalog
            + BuiltInProviders.fixtureOnly.filter { shownIDs.contains($0.id) }.map { $0.info }
        let detected = Set(fixture.selection?.enabled ?? catalog.map(\.id))
        var settings = ProviderSettings()
        for info in catalog where fixture.selection.map({ !$0.menuBar.contains(info.id) }) ?? false {
            settings.setInMenuBar(false, for: info.id)
        }
        // The options of the providers the fixture shows are drawn on.
        for info in catalog where shownIDs.contains(info.id) {
            for option in info.options {
                settings.setOption(true, option.id, for: info.id)
            }
        }
        let menu = ProvidersMenu.make(
            settings.menuItems(catalog, detected: detected), actions: .init(setEnabled: { _, _ in }, setInMenuBar: { _, _ in })
        )
        print("Providers menu:\n" + ProvidersMenu.describe(menu))

        // The key window of the first key provider the fixture shows, else
        // the first one listed.
        let keyed = catalog.first { $0.usesKey && shownIDs.contains($0.id) } ?? catalog.first(where: \.usesKey)
        if let keyed {
            let keyPath = (outputPath as NSString).deletingPathExtension + "-key.png"
            let api = (BuiltInProviders.keyAPIs + BuiltInProviders.fixtureOnly).first { $0.id == keyed.id }
            try renderKeyWindow(name: keyed.name, hint: api?.keyHint, to: keyPath)
            print("Key window: \(keyPath)")
        }

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

    /// The key window in its two looks: light with a key typed and tested,
    /// dark with a saved key that was rejected. AppKit draws the secure
    /// field and buttons, so this caches real views rather than using
    /// `ImageRenderer`. The typed key is an obviously fake placeholder.
    @MainActor
    private static func renderKeyWindow(name: String, hint: String?, to path: String) throws {
        func image(hasKey: Bool, typed: String, status: APIKeyView.Status, appearance: NSAppearance.Name) -> NSBitmapImageRep? {
            let actions = APIKeyActions(save: { _ in }, remove: {}, test: { _ in .connected }, hasKey: { hasKey })
            let view = NSHostingView(rootView: APIKeyView(name: name, hint: hint, actions: actions, typed: typed, status: status))
            view.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.title = "\(name) API key"
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            guard let frame = window.contentView?.superview else { return nil }
            frame.layoutSubtreeIfNeeded()
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            return rep
        }
        guard
            let light = image(hasKey: false, typed: "fake-key-for-snapshot", status: .tested(.connected), appearance: .aqua),
            let dark = image(hasKey: true, typed: "", status: .tested(.rejected), appearance: .darkAqua),
            let lightImage = light.cgImage, let darkImage = dark.cgImage
        else { throw Failure(description: "could not render the key window") }
        let gap = 40, pad = 30
        let width = lightImage.width + darkImage.width + gap + 2 * pad
        let height = max(lightImage.height, darkImage.height) + 2 * pad
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure(description: "could not render the key window") }
        context.setFillColor(CGColor(red: 0.45, green: 0.5, blue: 0.58, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(lightImage, in: CGRect(x: pad, y: height - pad - lightImage.height, width: lightImage.width, height: lightImage.height))
        context.draw(darkImage, in: CGRect(x: pad + lightImage.width + gap, y: height - pad - darkImage.height,
                                           width: darkImage.width, height: darkImage.height))
        guard let composed = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:])
        else { throw Failure(description: "could not render the key window") }
        try png.write(to: URL(fileURLWithPath: path))
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

    /// The status item's title from the same runs the app styles, or the
    /// neutral icon when there are none.
    private var menuBarText: Text {
        let palette = Palette(scheme)
        if snapshot.menuBar.runs.isEmpty {
            return Text(Image(systemName: "gauge.with.dots.needle.33percent"))
        }
        return snapshot.menuBar.runs.reduce(Text("")) { text, run in
            let piece = run.level.map { Text(run.text).foregroundStyle(palette.text($0)) } ?? Text(run.text)
            return Text("\(text)\(piece)")
        }
    }
}
