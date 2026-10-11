import Foundation

/// Usage priced in API-equivalent dollars: the session line and the weekly
/// chart.
enum UsageCost {
    static let fiveHours: TimeInterval = 5 * 60 * 60

    /// "$4.12 · 1.9M tokens this session" for the current 5-hour window
    /// (its reset minus 5 hours, up to now), or nil without a reading. Once
    /// the reset has passed, the next session started after it, so it counts
    /// from the reset until fresh numbers arrive.
    static func session(_ usage: [UsageEntry], window: LimitReading?, now: Date, prices: PriceTable) -> String? {
        guard let window else { return nil }
        let start = window.resetsAt > now ? window.resetsAt - fiveHours : window.resetsAt
        let entries = usage.filter { $0.timestamp >= start }
        let total = Total(entries, prices: prices)
        return "\(total.text) this session"
    }

    /// Dollars and tokens for some replies. Models missing from the price
    /// table add tokens but no dollars.
    struct Total {
        var dollars: Double = 0
        var tokens: Int = 0

        init(_ entries: [UsageEntry], prices: PriceTable) {
            for entry in entries {
                dollars += prices.price(for: entry.model)?.dollars(entry) ?? 0
                tokens += entry.tokens.total
            }
        }

        /// "$412 · 756M tokens"
        var text: String { "\(UsageCost.dollarText(dollars)) · \(UsageCost.tokenText(tokens)) tokens" }
    }

    /// "$3.05" below $10, then whole dollars: "$41", "$412", "$1,234".
    static func dollarText(_ dollars: Double) -> String {
        if dollars < 9.995 {
            return "$" + String(format: "%.2f", max(dollars, 0))
        }
        return "$" + Int(dollars.rounded()).formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// "950", "8.2K", "820K", "2.3M", "756M", "1.2B".
    static func tokenText(_ tokens: Int) -> String {
        let value = Double(tokens)
        func scaled(_ unit: Double, _ suffix: String) -> String {
            let x = value / unit
            return (x < 9.95 ? String(format: "%.1f", x) : String(Int(x.rounded()))) + suffix
        }
        switch tokens {
        case ..<1_000: return String(max(tokens, 0))
        case ..<999_500: return scaled(1_000, "K")
        case ..<999_500_000: return scaled(1_000_000, "M")
        default: return scaled(1_000_000_000, "B")
        }
    }
}
