# Contributing to UsageBar

Thanks for helping. Bug reports, fixes and new providers are all welcome. Please open an issue first for anything large, so we can agree on the approach before you write it.

## Build and test

You need macOS 26 and Swift 6.2 or later; the Command Line Tools are enough.

```sh
scripts/test.sh                      # the whole suite
scripts/test.sh --filter DeepSeek    # one suite (extra arguments go to `swift test`)
scripts/build.sh                     # packages ~/Applications/UsageBar.app
USAGEBAR_APP=/tmp/UsageBar.app scripts/build.sh   # package somewhere else
```

Use `scripts/test.sh`, not plain `swift test`. Without full Xcode, Swift Testing needs the Command Line Tools' framework and rpath flags, which the script adds.

## How the code is laid out

| Target | What it is |
|---|---|
| `Sources/UsageCore` | The **usage engine**. Pure code: raw readings (status line JSON, endpoint responses, app-server messages, log lines), a clock and the price tables in; a `UsageSnapshot` out (menu bar text, popover sections, meters, pace, charts, alerts to fire). No I/O. |
| `Sources/UsageBar` | The app: thin adapters (Keychain, network, subprocess, file watching) that feed the engine, and the SwiftUI popover that draws its snapshot. |
| `Sources/StatusLine` | `usagebar-statusline`, the command Claude Code runs after each reply. It also installs itself into a `settings.json`. |
| `Tests/UsageCoreTests` | Swift Testing tests against the engine. |
| `Fixtures` | Recorded or synthetic readings with a fixed clock, used by the tests and by snapshot mode. |

Tests go through the engine's public interface, with fixtures as input. Adapters stay thin enough to check by hand.

### Fixtures and snapshot mode

A fixture is JSON holding readings per provider id, a fixed `now`, a `timeZone` and, optionally, which providers are on:

```json
{
  "_comment": "Synthetic: built from the documented response shape, not recorded from a real key.",
  "now": "2026-10-10T14:40:00-07:00",
  "timeZone": "America/Los_Angeles",
  "readings": {
    "deepseek": [{ "receivedAt": "2026-10-10T14:38:00-07:00", "status": 200, "body": { … } }]
  },
  "providers": { "enabled": ["deepseek"], "menuBar": [] }
}
```

Render one to check a visual change:

```sh
~/Applications/UsageBar.app/Contents/MacOS/UsageBar --snapshot Fixtures/deepseek-balance.json out.png
```

It draws the popover in light and dark mode side by side, and prints the Providers menu. Attach before and after images to any pull request that changes what the popover looks like.

**Fixtures never hold credentials.** Record responses, never requests. Scrub account ids, emails and usernames. `KeyFixtureTests` fails if a fixture holds anything shaped like an API key or an `Authorization` header. Say in `_comment` whether a fixture is recorded or synthetic.

## Adding a provider

Most new providers read an HTTP API with the user's API key. Such a **key provider** is one type conforming to `KeyAPI` (in `Sources/UsageCore/KeyProvider.swift`) plus one line in `BuiltInProviders.keyAPIs`. Everything else comes for free: polling, back-off, "Key rejected" notes, the Keychain item, the key window with **Test connection**, the Providers menu entries, menu bar support and alerts for limit windows.

`ExampleKeyAPI` is a made-up provider with every kind of row, kept as a reference. The worked example below is DeepSeek (`Sources/UsageCore/DeepSeekAPI.swift`), the smallest real one.

### 1. Find a documented endpoint

Prefer a documented endpoint that a normal user API key can read. DeepSeek documents [`GET /user/balance`](https://api-docs.deepseek.com/api/get-user-balance):

```json
{ "is_available": true,
  "balance_infos": [{ "currency": "CNY", "total_balance": "110.00",
                      "granted_balance": "10.00", "topped_up_balance": "100.00" }] }
```

If the only option is undocumented, say so in the doc comment, the README and, if it's optional, a `KeyOption` the user turns on (as GitHub Copilot's quota meter does).

### 2. Write a fixture and a failing test

Add `Fixtures/deepseek-balance.json` (the shape above) and a test that reads it through the engine to what the popover shows:

```swift
@Test("each currency's balance is a row, with topped-up and granted as its detail")
func balance() throws {
    let fixture = try loadFixture("deepseek-balance")
    let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now,
                                        timeZone: fixture.timeZone, selection: fixture.selection)
    let section = try #require(snapshot["deepseek"])
    #expect(valueTexts(section) == ["Balance ¥110 · ¥100 topped up · ¥10 granted"])
}
```

Write the test before the code and watch it fail. Add fixtures for a rejected key (the real 401 body, from a made-up key) and for the odd cases the docs mention.

### 3. Implement `KeyAPI`

```swift
public enum DeepSeekAPI: KeyAPI {
    public static let id = "deepseek"            // never changes: names the Keychain item, settings and fixtures
    public static let name = "DeepSeek"
    public static let symbol = "◈"               // short menu bar glyph
    public static let systemImage = "fish"       // SF Symbol beside the section title
    public static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!
    public static let keyHint: String? = "Create a key at platform.deepseek.com/api_keys"

    public struct Reading: Equatable, Sendable { … }

    public static func reading(fromResponse body: Data, receivedAt: Date) -> Reading? { … }
    public static func report(_ reading: Reading?, clock: Clock) -> ProviderReport { … }
    public static func shift(_ reading: Reading, by offset: TimeInterval) -> Reading { reading }
}
```

- **`reading(fromResponse:receivedAt:)`** decodes tolerantly. A missing, renamed or mistyped field leaves only its own part of the reading nil, so only that row shows "—". Return nil only when nothing at all is readable. DeepSeek reads amounts as strings (as documented) or numbers, and drops a malformed `balance_infos` entry without losing the others.
- **`report(_:clock:)`** turns a reading into rows. With a nil reading, return the same rows showing "—". The row kinds:
  - `.window(LimitWindow)`: a limit that resets, with a percent and reset time. It gets a pace tick, a prediction, a share of the menu bar and the 90% and reset alerts. Set `hasLimitWindows = true` for a provider whose main rows are windows.
  - `.credit(CreditRow)`: "$12.40 left of $20", drawn as a meter.
  - `.value(ValueRow)`: a plain value such as "Balance ¥48.20" or "$3.10 this month".
- **`shift(_:by:)`** moves every date in the reading, so fixtures can be rebased to a new "now". DeepSeek's answer has no dates.
- Optional: `hosts` (when requests go to more than the endpoint's host), `authorization(key:)` (when the API doesn't want `Bearer <key>`, as z.ai doesn't), `fetch(_:)` (when one poll needs several requests, as GitHub Copilot's does), `interpret(_:)` (when errors arrive inside a 200, as z.ai's do) and `options`.

### 4. Register it

Add the type to `BuiltInProviders.keyAPIs` in display order. That's the only other file to touch.

### 5. Check it end to end

- `scripts/test.sh` passes.
- Render each new fixture with `--snapshot` and look at it in light and dark mode.
- If you have a real key, build the app, paste the key under **Providers**, and use **Test connection**. Say in the pull request whether you tried a real key, and never paste the key or a response containing account details into the PR.
- Add the provider to the README's provider table and give it a section: where to get a key, which permission it needs, what it shows, and whether the endpoint is documented.

### Providers that don't use an API key

Claude and Codex reuse logins that their own tools already have, read-only. A provider like that conforms to `Provider` directly (see `ClaudeProvider` and `CodexProvider`) and needs its own adapter in `Sources/UsageBar`. Never refresh, store or forward another tool's token: refresh tokens are usually single-use, so refreshing one signs the user out of the real tool. Open an issue to discuss one before starting.

## Pull requests

- Keep each pull request to one change, with tests.
- Run `scripts/test.sh` and `scripts/build.sh` before pushing.
- Include before and after `--snapshot` images for visual changes.
- Check your diff for keys, tokens, emails and local paths.
- See [AGENTS.md](AGENTS.md) for the guardrails and what reviewers look for.
