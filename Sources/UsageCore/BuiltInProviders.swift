/// The providers UsageBar ships, in display order.
public enum BuiltInProviders {
    public static let all: [any Provider.Type] = [ClaudeProvider.self, CodexProvider.self]

    /// What the Providers menu lists and detection checks, in display order.
    public static let catalog: [ProviderInfo] = [ClaudeProvider.info, CodexProvider.info]
}

extension ClaudeProvider {
    /// Claude shows when Claude Code is set up: its config directory or its
    /// binary in one of the places its installers put it.
    public static let info = ProviderInfo(id: "claude", name: "Claude", inMenuBarByDefault: true) { home, environment in
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
    public static let info = ProviderInfo(id: "codex", name: "Codex", inMenuBarByDefault: true) { home, environment in
        [
            environmentPath("CODEX_HOME", environment),
            environmentPath("USAGEBAR_CODEX", environment),
            "\(home)/.codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ].compactMap(\.self)
    }
}
