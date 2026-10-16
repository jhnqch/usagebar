# UsageBar

A macOS menu bar app that shows AI subscription limits (Claude, Codex) and API balances and quotas (OpenRouter, DeepSeek, Moonshot, z.ai, GitHub Copilot), with weekly cost history. `README.md` covers what it does and how each provider connects; `CONTRIBUTING.md` covers the code layout and adding a provider.

## Build and test

- `scripts/test.sh` runs the test suite. Use it instead of plain `swift test`: with only the Command Line Tools installed (no Xcode), Swift Testing needs the CLT framework and rpath flags that the script adds. Extra arguments go to `swift test`, e.g. `scripts/test.sh --filter DeepSeek`.
- `scripts/build.sh` builds and packages `~/Applications/UsageBar.app`; set `USAGEBAR_APP` to package somewhere else.
- `<app>/Contents/MacOS/UsageBar --snapshot <fixture.json> <out.png>` renders the popover from a fixture, for checking visual changes.
- `scripts/release.sh vX.Y.Z` tags `main` and creates the GitHub Release that installed apps update to (see "Releasing" in `CONTRIBUTING.md`).

## How to work here

- `Sources/UsageCore` is the pure usage engine: readings, a clock and price tables in, a `UsageSnapshot` out. Build behaviour there, test-first, through its public interface, with files in `Fixtures/` as input.
- `Sources/UsageBar` holds thin system adapters (Keychain, network, subprocess, file watching) and the SwiftUI views. Keep logic out of them.
- Adding a provider: follow "Adding a provider" in `CONTRIBUTING.md`. A key provider is one `KeyAPI` type plus one entry in `BuiltInProviders.keyAPIs`.

## Guardrails

- Treat the Claude Code OAuth token (Keychain item `Claude Code-credentials`) as read-only: it goes into the `Authorization` header of requests to `api.anthropic.com` and nowhere else, so it is never printed, logged or written to disk.
- Leave token refresh to Claude Code and Codex themselves. Their refresh tokens are single-use, so refreshing one here would sign the user out of the real tool.
- Point installer and settings tests at a temp copy of `~/.claude/settings.json`; the user's real file changes only by explicit request.
- API keys for key providers live only in UsageBar's own Keychain items (service `io.github.jhnqch.usagebar.api-key`, one per provider). A key goes only into the `Authorization` header of https requests to that provider's declared hosts, which `KeyClient` enforces; it is never printed, logged, put in `UserDefaults`, written to disk or put in a fixture. Tests inject a `KeyStore` and an `HTTPTransport` and use obviously fake keys; they never touch the real Keychain.
- Update checks are an unauthenticated `GET` to `api.github.com` for the `owner/name` recorded at build time, nothing else. The self-update runs only in the recorded checkout, refuses one with uncommitted changes or off `main` and release tags, never deletes untracked files (no `git clean`), and replaces the installed app only after a successful build. Test it against temp git repos, never a real checkout or `~/Applications`.
- Fixtures hold responses, never requests or credentials, and no account ids, emails, usernames or local paths.

## Review focus

Reviewers should check:

- Token and API key handling against the guardrails above.
- Tolerance in decoding undocumented formats: missing, extra and renamed fields degrade one row to "—" rather than failing the whole snapshot.
- UI state changes on the main actor.
- Time math for limit windows and resets: time zones, DST, windows that reset while the app is asleep.
