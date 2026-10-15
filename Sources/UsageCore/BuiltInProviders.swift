/// The providers UsageBar ships, in display order.
public enum BuiltInProviders {
    public static let all: [any Provider.Type] = [ClaudeProvider.self, CodexProvider.self] + keyAPIs.map { $0.providerType }

    /// The key providers UsageBar ships, in display order after `all`'s
    /// others. A new one goes here and nowhere else.
    public static let keyAPIs: [any KeyAPI.Type] = [OpenRouterAPI.self, DeepSeekAPI.self, MoonshotAPI.self, MoonshotChinaAPI.self, ZaiAPI.self, BigModelAPI.self, CopilotAPI.self]

    /// What the Providers menu lists and detection checks, in display order.
    public static let catalog: [ProviderInfo] = [ClaudeProvider.info, CodexProvider.info] + keyAPIs.map { $0.info }

    /// Providers only fixtures show: the example key provider, for tests and
    /// snapshot evidence. Never listed, polled or detected.
    public static let fixtureOnly: [any KeyAPI.Type] = [ExampleKeyAPI.self]
}

extension ClaudeProvider {
    /// Claude shows when Claude Code is set up: its config directory or its
    /// binary in one of the places its installers put it.
    public static let info = ProviderInfo(id: "claude", name: "Claude", inMenuBarByDefault: true, hasWindows: true) { home, environment in
        [
            environmentPath("CLAUDE_CONFIG_DIR", environment),
            "\(home)/.claude",
            "\(home)/.claude.json",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.npm-global/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ].compactMap(\.self)
    }
}

extension CodexProvider {
    /// Codex shows when its home directory exists or a `codex` binary is
    /// installed, including the one ChatGPT.app bundles.
    public static let info = ProviderInfo(id: "codex", name: "Codex", inMenuBarByDefault: true, hasWindows: true) { home, environment in
        [environmentPath("CODEX_HOME", environment), "\(home)/.codex"].compactMap(\.self) + executableCandidates(environment)
    }

    /// Where a `codex` binary may be, in order of preference: the one
    /// ChatGPT.app bundles first.
    private static func executableCandidates(_ environment: [String: String]) -> [String] {
        [
            environmentPath("USAGEBAR_CODEX", environment),
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ].compactMap(\.self)
    }

    /// The `codex` binary to run app-server with: `USAGEBAR_CODEX` when set
    /// (even if missing, to check the session-log fallback), else the first
    /// candidate that exists; nil when there's none.
    public static func executable(fileSystem: some FileSystem, environment: [String: String]) -> String? {
        if let override = environmentPath("USAGEBAR_CODEX", environment) { return override }
        return executableCandidates(environment).first { fileSystem.fileExists(atPath: $0) }
    }
}
