import SwiftUI
import UsageCore

/// Layout A: Claude and Codex stacked, every meter visible, no tabs.
struct PopoverView: View {
    var snapshot: UsageSnapshot
    var onRefresh: () -> Void = {}
    var onQuit: () -> Void = {}

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        VStack(alignment: .leading, spacing: 14) {
            SectionView(title: "Claude", symbol: "asterisk", section: snapshot.claude)
            Rectangle().fill(palette.divider).frame(height: 1)
            SectionView(title: "Codex", symbol: "apple.terminal", section: snapshot.codex)
            FooterView(onRefresh: onRefresh, onQuit: onQuit)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 16))
        .frame(width: 340)
        .foregroundStyle(palette.text)
        .background(palette.popover)
    }
}

private struct SectionView: View {
    var title: String
    var symbol: String
    var section: ServiceSection

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 15)
                Text(title).font(.system(size: 13, weight: .semibold))
                if let plan = section.plan {
                    Text(plan)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.muted)
                        .padding(.horizontal, 5)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.border, lineWidth: 1))
                }
                Spacer(minLength: 8)
                if let updated = section.updatedText {
                    Text(updated).font(.system(size: 11)).foregroundStyle(palette.muted)
                }
            }
            ForEach(section.meters) { MeterView(meter: $0) }
            if let note = section.note {
                Text(note).font(.system(size: 11)).foregroundStyle(palette.muted)
            }
        }
    }
}

private struct MeterView: View {
    var meter: Meter

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meter.label)
                Spacer()
                Text(meter.percentText)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(palette.text(meter.level))
            }
            .font(.system(size: 12))
            Capsule()
                .fill(palette.track)
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(palette.fill(meter.level))
                            .frame(width: geo.size.width * meter.fraction)
                    }
                }
                .clipShape(Capsule())
            if let reset = meter.resetText {
                Text(reset).font(.system(size: 11)).foregroundStyle(palette.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FooterView: View {
    var onRefresh: () -> Void
    var onQuit: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        HStack {
            Button(action: onRefresh) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                    Text("Refresh")
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(palette.button, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .keyboardShortcut("r")
            Spacer()
            Button(action: onQuit) {
                Text("Quit")
                    .foregroundStyle(palette.muted)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(palette.divider).frame(height: 1) }
    }
}
