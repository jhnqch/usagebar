import Foundation

/// Claude's API prices, in dollars per million tokens.
///
/// Source: Anthropic's pricing page,
/// https://platform.claude.com/docs/en/about-claude/pricing (Model pricing,
/// Fast mode pricing and Long context pricing), read on 2026-10-10, and
/// checked against the model list in the `claude-api` skill (cached
/// 2026-10-06). The two disagree on one rate: the skill gives Sonnet 5.5's
/// cache reads as $0.20, the pricing page as $0.10 (0.05x input); this table
/// follows the pricing page. Update by hand when prices change.
///
/// - Cache writes are 1.25x input for the 5-minute cache and 2x for the
///   1-hour cache. Cache reads are 0.1x input, except 0.05x on Opus 5.5 and
///   Sonnet 5.5 and 0.025x on Fable 5.1 and Mythos 5.1.
/// - Fast mode (Opus 5.5, Opus 5, Opus 4.8) has its own input and output
///   rates; the cache multipliers apply on top of them.
/// - Haiku 5.5 charges more for a prompt over 100,000 tokens, cache reads
///   and writes included.
/// - US-only inference (`inference_geo: "us"`) costs 1.1x on Claude 4.6 and
///   later; `ModelPrice.dollars` applies it.
/// - Not modelled: batch pricing, which Claude Code doesn't use, and the
///   pre-4.6 long-context premium on Sonnet 4.5 and 4.
extension PriceTable {
    public static let claude = PriceTable(models: [
        price("claude-fable-5-1", "Fable 5.1", "fable", input: 10, cacheRead: 0.25, output: 50),
        price("claude-fable-5", "Fable 5", "fable", input: 10, cacheRead: 1, output: 50),
        price("claude-opus-5-5", "Opus 5.5", "opus", input: 4, cacheRead: 0.20, output: 20,
              fast: rates(input: 8, cacheRead: 0.40, output: 40)),
        price("claude-opus-5", "Opus 5", "opus", input: 5, cacheRead: 0.50, output: 25,
              fast: rates(input: 10, cacheRead: 1, output: 50)),
        price("claude-opus-4-8", "Opus 4.8", "opus", input: 5, cacheRead: 0.50, output: 25,
              fast: rates(input: 10, cacheRead: 1, output: 50)),
        price("claude-opus-4-7", "Opus 4.7", "opus", input: 5, cacheRead: 0.50, output: 25),
        price("claude-opus-4-6", "Opus 4.6", "opus", input: 5, cacheRead: 0.50, output: 25),
        price("claude-opus-4-5", "Opus 4.5", "opus", input: 5, cacheRead: 0.50, output: 25),
        price("claude-opus-4-1", "Opus 4.1", "opus", input: 15, cacheRead: 1.50, output: 75),
        price("claude-opus-4-0", "Opus 4", "opus", input: 15, cacheRead: 1.50, output: 75),
        price("claude-opus-4", "Opus 4", "opus", input: 15, cacheRead: 1.50, output: 75),
        price("claude-sonnet-5-5", "Sonnet 5.5", "sonnet", input: 2, cacheRead: 0.10, output: 10),
        price("claude-sonnet-5", "Sonnet 5", "sonnet", input: 2, cacheRead: 0.20, output: 10),
        price("claude-sonnet-4-6", "Sonnet 4.6", "sonnet", input: 3, cacheRead: 0.30, output: 15),
        price("claude-sonnet-4-5", "Sonnet 4.5", "sonnet", input: 3, cacheRead: 0.30, output: 15),
        price("claude-sonnet-4-0", "Sonnet 4", "sonnet", input: 3, cacheRead: 0.30, output: 15),
        price("claude-sonnet-4", "Sonnet 4", "sonnet", input: 3, cacheRead: 0.30, output: 15),
        price("claude-haiku-5-5", "Haiku 5.5", "haiku", input: 0.10, cacheRead: 0.01, output: 0.50,
              longContext: LongContextRates(threshold: 100_000, rates: rates(input: 0.50, cacheRead: 0.05, output: 2.50))),
        price("claude-haiku-4-5", "Haiku 4.5", "haiku", input: 1, cacheRead: 0.10, output: 5),
        price("claude-3-5-haiku", "Haiku 3.5", "haiku", input: 0.80, cacheRead: 0.08, output: 4),
        price("claude-mythos-5-1", "Mythos 5.1", "mythos", input: 10, cacheRead: 0.25, output: 50),
        price("claude-mythos-5", "Mythos 5", "mythos", input: 10, cacheRead: 1, output: 50),
    ])

    /// Rates with the standard cache-write multipliers: 1.25x input for the
    /// 5-minute cache, 2x for the 1-hour cache.
    private static func rates(input: Double, cacheRead: Double, output: Double) -> TokenRates {
        TokenRates(input: input, cacheWrite5m: input * 1.25, cacheWrite1h: input * 2, cacheRead: cacheRead, output: output)
    }

    private static func price(
        _ id: String, _ name: String, _ family: String,
        input: Double, cacheRead: Double, output: Double,
        longContext: LongContextRates? = nil, fast: TokenRates? = nil
    ) -> ModelPrice {
        ModelPrice(id: id, name: name, family: family,
                   rates: rates(input: input, cacheRead: cacheRead, output: output),
                   longContext: longContext, fast: fast)
    }
}
