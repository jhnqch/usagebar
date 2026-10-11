import Foundation

/// UsageBar's side of the JSON-RPC conversation with `codex app-server`
/// over stdio. Pure: the caller writes `send` lines to the process's stdin
/// and passes each stdout line to `receive`.
///
/// The conversation only ever sends `initialize`, `initialized` and
/// `account/rateLimits/read`, and declines every request the server makes
/// (including `account/chatgptAuthTokens/refresh`), so it never touches
/// Codex's login tokens. app-server refreshes its own login.
public struct CodexAppServerConversation: Sendable {
    /// One step of the conversation.
    public struct Step: Equatable, Sendable {
        /// Lines to write to app-server's stdin, in order.
        public var send: [Data] = []
        /// A new Codex reading, from a read response or a push.
        public var limits: CodexLimits?
        /// An error app-server returned, for the log.
        public var failure: String?
    }

    private let clientVersion: String
    private var nextID = 1
    private var initializeID: Int?
    private var pendingReads: Set<Int> = []
    /// True once the `initialize` handshake has completed.
    public private(set) var isReady = false

    public init(clientVersion: String = "0.1.0") {
        self.clientVersion = clientVersion
    }

    /// The first line to send after starting the process: `initialize`.
    public mutating func start() -> [Data] {
        let id = takeID()
        initializeID = id
        return [encode(Outgoing(id: id, method: "initialize", params: InitializeParams(clientVersion: clientVersion)))]
    }

    /// Asks for a fresh reading. Sends nothing until the handshake completes
    /// (the handshake asks for one itself).
    public mutating func requestRateLimits() -> [Data] {
        isReady ? [readRequest()] : []
    }

    /// Handles one line of app-server's stdout, received at `now`.
    public mutating func receive(_ line: Data, at now: Date) -> Step {
        guard let message = try? JSONDecoder().decode(IncomingMessage.self, from: line) else { return Step() }
        return receive(message, at: now)
    }

    mutating func receive(_ message: IncomingMessage, at now: Date) -> Step {
        switch (message.id, message.method) {
        case let (id?, method?):
            // A request from the server. UsageBar handles none of them.
            return Step(send: [encode(ErrorReply(id: id, message: "UsageBar does not handle \(method)"))])
        case let (id?, nil):
            return response(id: id, message, at: now)
        case let (nil, method?) where method == "account/rateLimits/updated":
            return Step(limits: message.pushedRateLimits?.codexLimits(capturedAt: now))
        default:
            return Step()
        }
    }

    private mutating func response(id: RequestID, _ message: IncomingMessage, at now: Date) -> Step {
        guard case let .number(number) = id else { return Step() }
        if number == initializeID {
            initializeID = nil
            if let error = message.errorMessage {
                return Step(failure: "initialize failed: \(error)")
            }
            isReady = true
            return Step(send: [encode(Outgoing<Empty>(id: nil, method: "initialized", params: nil)), readRequest()])
        }
        guard pendingReads.remove(number) != nil else { return Step() }
        if let error = message.errorMessage {
            return Step(failure: "account/rateLimits/read failed: \(error)")
        }
        return Step(limits: message.readResult?.codexBucket?.codexLimits(capturedAt: now))
    }

    private mutating func readRequest() -> Data {
        let id = takeID()
        pendingReads.insert(id)
        return encode(Outgoing(id: id, method: "account/rateLimits/read", params: ReadParams()))
    }

    private mutating func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(value)) ?? Data()) + Data("\n".utf8)
    }
}

// MARK: - Wire messages
//
// app-server speaks JSON-RPC 2.0 with the `"jsonrpc"` field left off.

/// A JSON-RPC id: app-server uses numbers for ours, and may use strings.
enum RequestID: Codable, Hashable, Sendable {
    case number(Int)
    case string(String)

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let number = try? c.decode(Int.self) {
            self = .number(number)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .number(number): try c.encode(number)
        case let .string(string): try c.encode(string)
        }
    }
}

private struct Outgoing<Params: Encodable>: Encodable {
    var id: Int?
    var method: String
    var params: Params?
}

private struct Empty: Encodable {}

private struct InitializeParams: Encodable {
    struct ClientInfo: Encodable {
        var name = "usagebar"
        var title = "UsageBar"
        var version: String
    }

    var clientInfo: ClientInfo

    init(clientVersion: String) {
        clientInfo = ClientInfo(version: clientVersion)
    }
}

private struct ReadParams: Encodable {
    /// Background polls don't need the reset-credit details.
    var excludeResetCreditDetails = true
}

private struct ErrorReply: Encodable {
    struct Body: Encodable {
        var code = -32601
        var message: String
    }

    var id: RequestID
    var error: Body

    init(id: RequestID, message: String) {
        self.id = id
        error = Body(message: message)
    }
}

/// Any line from app-server: a response, a notification or a request.
/// Only the parts UsageBar reads are decoded, each one tolerantly.
struct IncomingMessage: Decodable {
    var id: RequestID?
    var method: String?
    var errorMessage: String?
    var readResult: RateLimitsReadResult?
    var pushedRateLimits: AppServerRateLimits?

    private enum CodingKeys: String, CodingKey {
        case id, method, result, error, params
    }

    private struct ErrorBody: Decodable {
        var message: String?
    }

    private struct PushParams: Decodable {
        var rateLimits: AppServerRateLimits?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rateLimits = try? c.decodeIfPresent(AppServerRateLimits.self, forKey: .rateLimits)
        }

        private enum CodingKeys: String, CodingKey { case rateLimits }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(RequestID.self, forKey: .id)
        method = try? c.decodeIfPresent(String.self, forKey: .method)
        if c.contains(.error) {
            let body = try? c.decode(ErrorBody.self, forKey: .error)
            errorMessage = body?.message ?? "unknown error"
        }
        readResult = try? c.decodeIfPresent(RateLimitsReadResult.self, forKey: .result)
        pushedRateLimits = (try? c.decodeIfPresent(PushParams.self, forKey: .params))?.rateLimits
    }
}

/// The result of `account/rateLimits/read`.
struct RateLimitsReadResult: Decodable {
    /// The backward-compatible single-bucket view.
    var rateLimits: AppServerRateLimits?
    /// The multi-bucket view keyed by limit id, e.g. `codex`.
    var rateLimitsByLimitId: [String: AppServerRateLimits]?

    private enum CodingKeys: String, CodingKey {
        case rateLimits, rateLimitsByLimitId
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rateLimits = try? c.decodeIfPresent(AppServerRateLimits.self, forKey: .rateLimits)
        rateLimitsByLimitId = (try? c.decodeIfPresent([String: Lenient<AppServerRateLimits>].self, forKey: .rateLimitsByLimitId))?
            .compactMapValues(\.value)
    }

    /// The `codex` bucket: from the multi-bucket view when present, else
    /// the single-bucket view.
    var codexBucket: AppServerRateLimits? {
        rateLimitsByLimitId?["codex"] ?? rateLimits
    }
}

/// A rate-limit snapshot as app-server reports it (camelCase).
struct AppServerRateLimits: Decodable {
    var limitId: String?
    var planType: String?
    var primary: RateLimitWindow?
    var secondary: RateLimitWindow?

    private enum CodingKeys: String, CodingKey {
        case limitId, planType, primary, secondary
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limitId = try? c.decodeIfPresent(String.self, forKey: .limitId)
        planType = try? c.decodeIfPresent(String.self, forKey: .planType)
        primary = try? c.decodeIfPresent(RateLimitWindow.AppServer.self, forKey: .primary)?.window
        secondary = try? c.decodeIfPresent(RateLimitWindow.AppServer.self, forKey: .secondary)?.window
    }

    func codexLimits(capturedAt: Date) -> CodexLimits? {
        RateLimitWindow.codexLimits(limitID: limitId, plan: planType, windows: [primary, secondary], capturedAt: capturedAt)
    }
}

/// How long to wait before restarting app-server after it exits: doubling
/// from `initial` up to `maximum`, back to `initial` once it's healthy.
public struct RestartBackoff: Sendable {
    private let initial: Duration
    private let maximum: Duration
    private var next: Duration

    public init(initial: Duration = .seconds(1), maximum: Duration = .seconds(300)) {
        self.initial = initial
        self.maximum = maximum
        next = initial
    }

    public mutating func nextDelay() -> Duration {
        defer { next = min(next * 2, maximum) }
        return next
    }

    public mutating func reset() {
        next = initial
    }
}
