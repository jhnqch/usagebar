import Foundation

/// OpenAI's API prices for the models Codex runs, in dollars per million
/// tokens: what Codex usage would have cost through the API.
///
/// Source: OpenAI's pricing page, https://developers.openai.com/api/docs/pricing
/// (Standard tier: the "Flagship models" table and its "All models" list,
/// and "Specialized models" for gpt-5.3-codex), read on 2026-10-11. The
/// models are the ones Codex offers (its `models_cache.json`) that the page
/// prices. Codex's hidden `codex-auto-review` and `gpt-reserve` have no
/// public price, so they show tokens only. Update by hand when prices change.
///
/// - The page splits input three ways: "Input tokens are either Input,
///   Cached Input, or Cache Write and writes are not an additive fee". Cache
///   writes go in the 5-minute slot (Codex has one cache). gpt-5.5 and
///   gpt-5.3-codex have no cache-write price, so their writes cost the same
///   as input.
/// - "Output prices include visible output tokens and reasoning tokens."
/// - Long context (over 272K input tokens) has its own rates, but the page
///   gives them only for GPT-6-Astra, GPT-6.1-Sol, GPT-6-Luna and
///   GPT-5.6-Sol. Codex's context window is 258,400 tokens today, so no
///   Codex request reaches them yet.
/// - Not modelled: the Batch, Flex, Fast and Ultrafast tiers (every recorded
///   turn has `service_tier: null`) and the 10% regional-processing uplift.
extension PriceTable {
    public static let codex = PriceTable(models: [
        price("gpt-6-astra", "GPT-6-Astra", "astra", input: 10, cached: 1, write: 12.5, output: 50,
              long: (20, 2, 25, 75)),
        price("gpt-6.1-sol", "GPT-6.1-Sol", "sol", input: 2, cached: 0.10, write: 2.5, output: 10,
              long: (4, 0.20, 5, 15)),
        price("gpt-6-sol", "GPT-6-Sol", "sol", input: 2, cached: 0.20, write: 2.5, output: 10),
        price("gpt-6-luna", "GPT-6-Luna", "luna", input: 0.10, cached: 0.01, write: 0.125, output: 0.50,
              long: (0.20, 0.02, 0.25, 0.75)),
        price("gpt-5.6-sol", "GPT-5.6-Sol", "sol", input: 4, cached: 0.40, write: 5, output: 20,
              long: (8, 0.80, 10, 30)),
        price("gpt-5.6-terra", "GPT-5.6-Terra", "terra", input: 2, cached: 0.20, write: 2.5, output: 12),
        price("gpt-5.6-luna", "GPT-5.6-Luna", "luna", input: 0.20, cached: 0.02, write: 0.25, output: 1.20),
        price("gpt-5.5", "GPT-5.5", "gpt", input: 5, cached: 0.50, write: nil, output: 30),
        price("gpt-5.3-codex", "GPT-5.3-Codex", "codex", input: 1.75, cached: 0.175, write: nil, output: 14),
    ])

    /// Input over this many tokens is priced at the long-context rates.
    private static let longContextThreshold = 272_000

    private static func rates(input: Double, cached: Double, write: Double?, output: Double) -> TokenRates {
        TokenRates(input: input, cacheWrite5m: write ?? input, cacheWrite1h: write ?? input, cacheRead: cached, output: output)
    }

    private static func price(
        _ id: String, _ name: String, _ family: String,
        input: Double, cached: Double, write: Double?, output: Double,
        long: (input: Double, cached: Double, write: Double, output: Double)? = nil
    ) -> ModelPrice {
        ModelPrice(
            id: id, name: name, family: family,
            rates: rates(input: input, cached: cached, write: write, output: output),
            longContext: long.map {
                LongContextRates(threshold: longContextThreshold,
                                 rates: rates(input: $0.input, cached: $0.cached, write: $0.write, output: $0.output))
            }
        )
    }
}
