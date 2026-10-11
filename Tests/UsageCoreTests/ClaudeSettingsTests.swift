import Foundation
import Testing
import UsageCore

/// The status line installer's edit to Claude Code's `settings.json`.
@Suite("Status line installer")
struct ClaudeSettingsTests {
    let command = "/Users/user/Applications/UsageBar.app/Contents/Helpers/usagebar-statusline"

    @Test("adds statusLine after the other settings, leaving every other byte as it was")
    func addsStatusLine() throws {
        let settings = """
        {
          "model": "opus",
          "permissions": {
            "allow": ["Bash(git status)", "Read(./{a,b}/**)"]
          },
          "env": { "statusLine": "not the setting", "QUOTE": "say \\"}\\"" }
        }

        """
        let result = try ClaudeSettings.installingStatusLine(command: command, into: settings)
        #expect(result == .updated("""
        {
          "model": "opus",
          "permissions": {
            "allow": ["Bash(git status)", "Read(./{a,b}/**)"]
          },
          "env": { "statusLine": "not the setting", "QUOTE": "say \\"}\\"" },
          "statusLine": {
            "type": "command",
            "command": "/Users/user/Applications/UsageBar.app/Contents/Helpers/usagebar-statusline"
          }
        }

        """))
    }

    @Test("with no settings yet, or an empty object, the settings become just the status line", arguments: [nil, "", "  \n", "{}", "{ }\n"])
    func emptySettings(settings: String?) throws {
        let result = try ClaudeSettings.installingStatusLine(command: command, into: settings)
        guard case let .updated(text) = result else { Issue.record("expected an update, got \(result)"); return }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object.keys.sorted() == ["statusLine"])
        #expect(object["statusLine"] as? [String: String] == ["type": "command", "command": command])
        #expect(text.contains("\n  \"statusLine\": {\n    \"type\": \"command\",\n"))
    }

    @Test("settings on one line stay on one line")
    func oneLine() throws {
        let result = try ClaudeSettings.installingStatusLine(command: command, into: #"{"model":"opus","n":[1,{"x":null}],"ok":true}"#)
        #expect(result == .updated(#"{"model":"opus","n":[1,{"x":null}],"ok":true, "statusLine": { "type": "command", "command": ""# + command + #"" }}"#))
    }

    @Test("a statusLine that already runs the command is left alone, extra fields and all")
    func alreadyInstalled() throws {
        let settings = #"{"statusLine": {"type": "command", "command": ""# + command + #"", "padding": 2}}"#
        #expect(try ClaudeSettings.installingStatusLine(command: command, into: settings) == .alreadyInstalled)
    }

    @Test("a different statusLine is a conflict and nothing changes")
    func conflict() throws {
        let settings = """
        {
          "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" },
          "model": "opus"
        }
        """
        #expect(try ClaudeSettings.installingStatusLine(command: command, into: settings) == .conflict(existing: "~/.claude/statusline.sh"))
        #expect(try ClaudeSettings.installingStatusLine(command: command, into: #"{"statusLine": "odd"}"#) == .conflict(existing: #""odd""#))
    }

    @Test("replacing swaps only the statusLine value")
    func replacing() throws {
        let settings = """
        {
          "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" },
          "model": "opus"
        }
        """
        let result = try ClaudeSettings.installingStatusLine(command: command, into: settings, replacing: true)
        #expect(result == .updated("""
        {
          "statusLine": {
            "type": "command",
            "command": "\(command)"
          },
          "model": "opus"
        }
        """))
    }

    @Test("a settings file that isn't a JSON object is refused", arguments: ["[]", "not json", "{\"a\": 1,}", "\"text\""])
    func notAnObject(settings: String) {
        #expect(throws: ClaudeSettings.NotAnObject.self) {
            try ClaudeSettings.installingStatusLine(command: command, into: settings)
        }
    }

    @Test("the command is the executable's path, quoted for the shell when it needs to be")
    func shellCommand() {
        #expect(ClaudeSettings.shellCommand(forExecutable: command) == command)
        #expect(ClaudeSettings.shellCommand(forExecutable: "/Users/me/My Apps/UsageBar.app/x") == "'/Users/me/My Apps/UsageBar.app/x'")
        #expect(ClaudeSettings.shellCommand(forExecutable: "/tmp/it's/x") == #"'/tmp/it'\''s/x'"#)
    }
}
