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
            if let reset = meter.resetText {
                Text(reset).font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            if let usage = meter.usageText {
                Text(usage).font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.muted)
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
