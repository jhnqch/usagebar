import Foundation
import UsageCore

/// The text `--claude-usage` prints: replies, tokens by kind and dollars per
/// model, then the totals.
enum ClaudeUsageReport {
    static func text(_ entries: [UsageEntry], since: Date, prices: PriceTable) -> String {
        let recent = entries.filter { $0.timestamp >= since }
        var lines = ["since \(since.formatted(.iso8601))", "model\treplies\tinput\twrite5m\twrite1h\tread\toutput\ttotal\tdollars"]
        func row(_ name: String, _ entries: [UsageEntry]) -> String {
            let tokens = entries.reduce(TokenCounts()) { sum, entry in
                TokenCounts(
                    input: sum.input + entry.tokens.input,
                    cacheWrite5m: sum.cacheWrite5m + entry.tokens.cacheWrite5m,
                    cacheWrite1h: sum.cacheWrite1h + entry.tokens.cacheWrite1h,
                    cacheRead: sum.cacheRead + entry.tokens.cacheRead,
                    output: sum.output + entry.tokens.output
                )
            }
            let dollars = entries.reduce(0.0) { $0 + (prices.price(for: $1.model)?.dollars($1) ?? 0) }
            return [name, "\(entries.count)", "\(tokens.input)", "\(tokens.cacheWrite5m)", "\(tokens.cacheWrite1h)",
                    "\(tokens.cacheRead)", "\(tokens.output)", "\(tokens.total)", String(format: "%.2f", dollars)]
                .joined(separator: "\t")
        }
        for (model, entries) in Dictionary(grouping: recent, by: \.model).sorted(by: { $0.key < $1.key }) {
            lines.append(row(model, entries))
        }
        lines.append(row("TOTAL", recent))
        return lines.joined(separator: "\n")
    }
}
