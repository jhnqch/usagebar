# UsageBar

A personal macOS menu bar app that shows Claude and Codex subscription limits and weekly cost history. Decisions and their reasons live in `PLAN.md`; the spec is the GitHub issue labelled `spec`.

## Build and test

- `scripts/build.sh` builds and packages `~/Applications/UsageBar.app`.
- `scripts/test.sh` runs the test suite. Use it instead of plain `swift test`, which fails on this machine: there is no full Xcode, so Swift Testing needs the Command Line Tools framework and rpath flags that the script adds.

## Workflow

- One ticket is one branch, `ticket/<n>-<slug>`, and one PR whose body contains `Closes #<n>`.
- Tickets stack: cut each ticket branch from the previous ticket's branch and point its PR at that branch.
- The repo merges with merge commits only. The user does every merge. The status workflow is the only writer to `main` (it maintains `STATUS.md`).
- Implementation runs through the `developer` agent (`.claude/agents/developer.md`).

## Guardrails

- Treat the Claude Code OAuth token (Keychain item `Claude Code-credentials`) as read-only: it goes into the `Authorization` header of requests to `api.anthropic.com` and nowhere else, so it is never printed, logged or written to disk.
- Leave token refresh to Claude Code and Codex themselves. Their refresh tokens are single-use, so refreshing one here would sign the user out of the real tool.
- Point installer and settings tests at a temp copy of `~/.claude/settings.json`; the user's real file changes only by explicit request.
- API keys for key providers live only in UsageBar's own Keychain items (service `io.github.jhnqch.usagebar.api-key`, one per provider). A key goes only into the `Authorization` header of https requests to that provider's declared hosts, which `KeyClient` enforces; it is never printed, logged, put in `UserDefaults`, written to disk or put in a fixture. Tests inject a `KeyStore` and an `HTTPTransport` and use obviously fake keys; they never touch the real Keychain.

## Review focus

Reviewers (including Codex) should check:

- Token and API key handling against the guardrails above.
- Tolerance in decoding undocumented formats: missing, extra and renamed fields degrade one row to "—" rather than failing the whole snapshot.
- UI state changes on the main actor.
- Time math for limit windows and resets: time zones, DST, windows that reset while the app is asleep.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on `jhnqch/usagebar`; the spec is labelled `spec` and tickets are its sub-issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context. See `docs/agents/domain.md`.
