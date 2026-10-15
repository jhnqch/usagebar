import Foundation

/// An amount of money or of something counted, as a balance or spend row
/// shows it: "$12.40", "¥48.20", "1,234 requests".
public struct Amount: Equatable, Sendable {
    public var value: Double
    public var unit: Unit

    public init(_ value: Double, _ unit: Unit) {
        self.value = value
        self.unit = unit
    }

    public enum Unit: Equatable, Sendable {
        /// An ISO 4217 code: "USD", "CNY".
        case currency(String)
        /// Things counted, named as they read after the number: "requests".
        case count(String)

        public static let usd = Unit.currency("USD")
    }

    /// Currencies written with a symbol in front; any other reads "7.50 CHF".
    private static let symbols = ["USD": "$", "CNY": "¥", "EUR": "€", "GBP": "£", "JPY": "¥"]

    /// "$20", "$12.40", "−$3.25", "7.50 CHF", "1,234 requests", "2.5 credits".
    /// Money shows cents unless the amount is whole; counts show up to two
    /// decimals, dropping trailing zeros. Fixed format, not the user's
    /// locale, so a row reads the same in every fixture and test.
    public var text: String {
        let sign = value < 0 && Self.number(abs(value), cents: true) != "0.00" ? "−" : ""
        switch unit {
        case let .currency(code):
            let digits = Self.number(abs(value), cents: abs(value).rounded() != abs(value))
            if let symbol = Self.symbols[code.uppercased()] { return "\(sign)\(symbol)\(digits)" }
            return "\(sign)\(digits) \(code.uppercased())"
        case let .count(noun):
            let digits = Self.number(abs(value), cents: false, trimmed: true)
            return noun.isEmpty ? "\(sign)\(digits)" : "\(sign)\(digits) \(noun)"
        }
    }

    private static func number(_ value: Double, cents: Bool, trimmed: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.roundingMode = .halfEven
        formatter.minimumFractionDigits = cents ? 2 : 0
        formatter.maximumFractionDigits = cents || trimmed ? 2 : 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}
