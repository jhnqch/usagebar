import SwiftUI
import UsageCore

/// Layout A: every provider's section stacked, every meter visible, no tabs.
struct PopoverView: View {
    var snapshot: UsageSnapshot
    var height: Height = .full
    var onShowProviders: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onQuit: () -> Void = {}

    /// How the popover fits its screen.
    enum Height: Equatable {
        /// Everything at full height, with no scroll view: snapshot mode,
        /// whose `ImageRenderer` can't draw one.
        case full
        /// At most this tall. The sections scroll inside it; the footer
        /// stays in view.
        case capped(CGFloat)
        /// Snapshot mode's picture of `capped`: the sections clipped as the
        /// scroll view shows them, scrolled to the top or to the bottom.
        case cappedPreview(CGFloat, atBottom: Bool)
    }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        VStack(spacing: 0) {
            switch height {
            case .full:
                sections
            case .capped:
                ScrollView(.vertical) { sections }
                    .scrollBounceBehavior(.basedOnSize)
            case let .cappedPreview(_, atBottom):
                ScrollPreview(atBottom: atBottom) {
                    sections
                    Capsule().fill(palette.muted.opacity(0.55))
                }
                .clipped()
            }
            FooterView(onShowProviders: onShowProviders, onRefresh: onRefresh, onQuit: onQuit)
                .padding(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
        }
        .frame(width: 340)
        .frame(maxHeight: maxHeight)
        .foregroundStyle(palette.text)
        .background(palette.popover)
    }

    private var maxHeight: CGFloat? {
        switch height {
        case .full: nil
        case let .capped(height), let .cappedPreview(height, _): height
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let empty = snapshot.emptyText {
                EmptyStateView(text: empty)
            }
            ForEach(Array(snapshot.sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    Rectangle().fill(Palette(scheme).divider).frame(height: 1)
                }
                SectionView(section: section)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
    }
}

/// Snapshot mode's stand-in for a scroll view (which `ImageRenderer` can't
/// draw): the content at its full height, pinned to the top or the bottom
/// of the space it's given, and an overlay scroller thumb sized and placed
/// as AppKit's would be. Takes two views: the content, then the thumb.
private struct ScrollPreview: Layout {
    var atBottom: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let content = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? content.width, height: min(proposal.height ?? content.height, content.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let content = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: atBottom ? bounds.maxY - content.height : bounds.minY),
            proposal: ProposedViewSize(width: bounds.width, height: content.height)
        )
        let inset: CGFloat = 3
        let track = bounds.height - 2 * inset
        let thumb = CGSize(width: 6, height: max(track * bounds.height / max(content.height, 1), 24))
        subviews[1].place(
            at: CGPoint(x: bounds.maxX - inset - thumb.width, y: atBottom ? bounds.maxY - inset - thumb.height : bounds.minY + inset),
            proposal: ProposedViewSize(thumb)
        )
    }
}

private struct SectionView: View {
    var section: ProviderSection

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 15)
                Text(section.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).layoutPriority(2)
                if let plan = section.plan {
                    Text(plan)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(palette.muted)
                        .padding(.horizontal, 5)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.border, lineWidth: 1))
                }
                Spacer(minLength: 8)
                if let updated = section.updatedText {
                    Text(updated).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).layoutPriority(1)
                }
            }
            ForEach(section.rows) { row in
                switch row {
                case let .meter(meter): MeterView(meter: meter)
                case let .credit(credit): CreditMeterView(meter: credit)
                case let .value(value): ValueLineView(line: value)
                }
            }
            if let note = section.note {
                Text(note).font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            if let chart = section.chart {
                CostChartView(chart: chart)
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
                .overlay { tick(palette: palette) }
            resetAndPrediction(palette: palette)
            if let usage = meter.usageText {
                Text(usage).font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The pace tick: a thin mark across the bar, a little taller than it,
    /// where the window's elapsed time has reached.
    @ViewBuilder
    private func tick(palette: Palette) -> some View {
        if let elapsed = meter.elapsed {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 1)
                    .fill(palette.text)
                    .frame(width: Self.tickWidth, height: Self.tickHeight)
                    .position(
                        x: min(max(geo.size.width * elapsed, Self.tickWidth / 2), geo.size.width - Self.tickWidth / 2),
                        y: geo.size.height / 2
                    )
            }
            .accessibilityElement()
            .accessibilityLabel(meter.elapsedText ?? "")
        }
    }

    private static let tickWidth: CGFloat = 2
    private static let tickHeight: CGFloat = 12

    /// The reset time and the pace prediction: on one line when both fit,
    /// otherwise the prediction under the reset time.
    @ViewBuilder
    private func resetAndPrediction(palette: Palette) -> some View {
        let reset = meter.resetText.map { Text($0).foregroundStyle(palette.muted) }
        let prediction = meter.prediction.map {
            Text($0.text).foregroundStyle($0.isAhead ? palette.text(.warning) : palette.muted)
        }
        if reset != nil || prediction != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    reset
                    Spacer(minLength: 10)
                    prediction
                }
                VStack(alignment: .leading, spacing: 4) {
                    reset
                    prediction
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
        }
    }
}

/// Credit left of a total: the label and "$12.40 left of $20", a bar filled
/// by what's used, and when it resets.
private struct CreditMeterView: View {
    var meter: CreditMeter

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meter.label)
                Spacer()
                Text(meter.valueText)
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

/// A balance or spend row: the label, and the amount on the right, with
/// its detail ("¥100 topped up · ¥10 granted") muted underneath.
private struct ValueLineView: View {
    var line: ValueLine

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(line.label)
                Spacer()
                Text(line.valueText).fontWeight(.semibold).monospacedDigit()
            }
            .font(.system(size: 12))
            if let detail = line.detailText {
                Text(detail)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Palette(scheme).muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The weekly cost chart: a bar per day stacked by model, days to come as
/// dashed slots, and a legend with each model's dollars and tokens.
private struct CostChartView: View {
    var chart: CostChart

    @Environment(\.colorScheme) private var scheme

    static let barHeight: CGFloat = 64

    var body: some View {
        let palette = Palette(scheme)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(chart.title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Text(chart.rangeText).font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.muted)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(chart.days) { day in
                    DayColumn(day: day, maxDollars: chart.maxDollars)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(chart.legend) { row in
                    HStack(spacing: 7) {
                        swatch(row.series, palette: palette)
                        Text(row.name)
                        Spacer(minLength: 8)
                        Text(row.valueText).monospacedDigit().foregroundStyle(palette.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
                HStack(spacing: 7) {
                    Color.clear.frame(width: 8, height: 8)
                    Text("Total").fontWeight(.medium)
                    Spacer(minLength: 8)
                    Text(chart.totalText).monospacedDigit().fontWeight(.medium)
                }
                .accessibilityElement(children: .combine)
            }
            .font(.system(size: 11))
        }
        .padding(.top, 4)
    }

    /// The model's colour; a dashed outline for a model with no price,
    /// which has no bar.
    @ViewBuilder
    private func swatch(_ series: Int?, palette: Palette) -> some View {
        if let series {
            RoundedRectangle(cornerRadius: 2).fill(palette.series(series)).frame(width: 8, height: 8)
        } else {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(palette.muted, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                .frame(width: 8, height: 8)
        }
    }
}

private struct DayColumn: View {
    var day: CostChart.Day
    var maxDollars: Double

    @Environment(\.colorScheme) private var scheme

    /// Space between stacked segments.
    private static let gap: CGFloat = 2

    var body: some View {
        let palette = Palette(scheme)
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width * 0.7
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    bar(palette: palette)
                        .frame(width: width)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: CostChartView.barHeight)
            Text(day.label)
                .font(.system(size: 10, weight: day.isToday ? .bold : .regular))
                .foregroundStyle(day.isToday ? palette.text : palette.muted)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .help(day.detailText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.detailText)
    }

    @ViewBuilder
    private func bar(palette: Palette) -> some View {
        if day.isFuture {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(palette.dash, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .frame(height: CostChartView.barHeight)
        } else if day.dollars <= 0 || maxDollars <= 0 {
            RoundedRectangle(cornerRadius: 1).fill(palette.track).frame(height: 2)
        } else {
            let stack = day.stack(barHeight: CostChartView.barHeight, maxDollars: maxDollars, gap: Self.gap)
            VStack(spacing: stack.gap) {
                ForEach(Array(zip(day.segments, stack.heights).reversed().enumerated()), id: \.offset) { _, pair in
                    RoundedRectangle(cornerRadius: min(2, pair.1 / 2))
                        .fill(palette.series(pair.0.series))
                        .frame(height: pair.1)
                }
            }
        }
    }
}

/// What the popover shows when no provider is on.
private struct EmptyStateView: View {
    var text: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 12, weight: .semibold))
                Text("No providers").font(.system(size: 13, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The footer's Providers button: pops up the Providers menu
/// (`ProvidersMenu`) under the pointer.
private struct ProvidersButton: View {
    var onShow: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: onShow) {
            HStack(spacing: 4) {
                Text("Providers")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Providers")
    }
}

private struct FooterView: View {
    var onShowProviders: () -> Void
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
            ProvidersButton(onShow: onShowProviders)
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
