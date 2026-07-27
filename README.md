# Claude Usage Widget

A small always-on-top macOS widget that shows your Claude Code usage as
concentric Apple-Watch-style activity rings.

<p align="center">
  <img src="docs/rings.png" alt="Three concentric usage rings: 5-hour, weekly and Fable" width="300">
</p>

Each ring is one limit:

| Ring | Colour | What it measures | Source |
|---|---|---|---|
| **5-Hour** | red | rolling 5-hour session window | live API |
| **Weekly** | green | 7-day rolling limit, all models | live API |
| **Fable** | violet | weekly Fable-model limit | live API |

Three rings, because three is what the plan actually exposes. They are
data-driven, so you can turn any of them off in Settings.

## Install

Requires macOS 14+ and a Claude subscription that Claude Code is signed in to.

```bash
git clone https://github.com/melucasleite/claude-usage-widget.git
cd claude-usage-widget
./Scripts/build-app.sh --run
```

That produces `dist/ClaudeUsageWidget.app`. Drag it to `/Applications` and add
it to Login Items if you want it always around.

> **Xcode note.** SwiftUI's `@State` and friends are macros now, expanded by
> `libSwiftUIMacros.dylib`, which ships inside Xcode and *not* with the
> standalone Command Line Tools. The build script finds any installed Xcode
> automatically and borrows it via `DEVELOPER_DIR` — no `xcode-select` (and no
> `sudo`) required. Override it explicitly if you like:
>
> ```bash
> DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/build-app.sh
> ```

## Usage

- **Hover a ring** to preview it: the centre readout switches to that ring's
  percentage, label and colour, and reverts when you leave. The tooltip adds
  the reset countdown and where the number came from.
- **Click a ring** to pin it there. Click it again to unpin. The choice
  persists across relaunches. Unpinned, the centre follows whichever ring is
  closest to its limit.
- **Drag** the widget anywhere. Its position is remembered.
- **Hover** the widget for a refresh button and a settings shortcut.
- **Right-click** the widget, or click the menu bar readout, for the full menu
  — including *Centre Shows*, which pins a ring without clicking one.
- **Always on top** is a toggle — in the menu, or in Settings → Appearance.

Reset countdowns live in the tooltip rather than on the face. The widget is
something you glance at, and a number that only matters once you are already
worried has not earned permanent space in the middle.

### Diagnostics

If the rings are not showing live data, ask the app why:

```bash
./dist/ClaudeUsageWidget.app/Contents/MacOS/ClaudeUsageWidget --check
```

It reports which Keychain items it found, whether the token parsed, whether the
endpoint answered, and which windows came back. It never prints a token value —
only metadata such as length and expiry.

### Regenerating the screenshot

```bash
./dist/ClaudeUsageWidget.app/Contents/MacOS/ClaudeUsageWidget --render-preview docs/rings.png --demo
```

`--demo` uses fixed representative values, so the image in this README contains
none of anyone's real numbers.

## How it gets the data

Two independent sources, because the good one is undocumented and the reliable
one is imprecise.

### 1. Live endpoint (preferred)

`GET https://api.anthropic.com/api/oauth/usage` — the same endpoint `/usage`
inside Claude Code talks to. It returns exact percentages:

```json
{
  "five_hour":        { "utilization": 30.0, "resets_at": "..." },
  "seven_day":        { "utilization": 47.0, "resets_at": "..." },
  "seven_day_omelette": null,
  "seven_day_opus":     null
}
```

This is **unofficial and undocumented** and may change or vanish without
notice. Two things are worth knowing if you build something similar:

- The `User-Agent: claude-code/<version>` header is not optional in practice.
  Without it you land in an aggressively rate-limited bucket and get persistent
  `429`s.
- **Per-model windows use internal codenames, not model names.** There is no
  `seven_day_fable`. A live response carries `seven_day_omelette` alongside
  decoys like `cinder_cove`, `nimbus_quill` and `iguana_necktie`. The Fable ring
  is mapped to `seven_day_omelette` by matching a live response against what
  Claude Code's own `/usage` displayed — an **inference, not a documented
  contract**. Pin a different key in Settings → Data if it ever moves.
- **`null` means 0%, not "unavailable".** A per-model key that is present but
  null means the window applies to your account with no usage yet — which is
  exactly how `/usage` renders it. Treating null as missing is what keeps an
  idle Fable ring dark when it should read 0%.
- The response is otherwise decoded by *shape* rather than a hardcoded key
  list, so new windows appear without a code change.

### 2. Local transcripts (fallback)

Claude Code already writes every response's token usage to
`~/.claude/projects/**/*.jsonl`. Parsing those needs **no credentials at all**,
so the widget keeps working when the token is stale or the endpoint moves.

Two details make it cheap enough to run every minute:

- **Incremental tailing.** Per-file byte offsets are persisted, so a refresh
  parses only bytes appended since last time, and a partially-written trailing
  line is left for the next pass.
- **Deduplication by request ID.** The same billable response legitimately
  appears more than once in the transcripts. Without dedup, every window
  double-counts.

### The calibration trick

Locally we know exactly what your usage *cost* at list prices. What we cannot
know is the denominator — a Max plan's quotas are not published, and they are
emphatically not the subscription price.

Guessing is worse than useless here. An early version of this widget divided a
real weekly cost by a plausible-looking `$120` budget and proudly displayed
**3704%**.

So it does not guess. Whenever the live endpoint answers, both halves of the
equation are in hand at the same instant:

```
utilization = 47%      (authoritative, from the API)
window cost = $2,090   (computed locally from transcripts)
⇒ implied full quota ≈ $2,090 / 0.47 ≈ $4,447
```

That implied quota is smoothed, persisted, and reused as the denominator the
next time the endpoint is unreachable. Until a window has been calibrated at
least once, that ring reports *unknown* rather than inventing a number.

You can override any denominator manually in Settings → Data.

## Credentials and security

The app reads the Claude OAuth token that Claude Code already stores on your
machine. It is worth being precise about what that does and does not involve:

- The token is **read** via `/usr/bin/security`, falling back to
  `~/.claude/.credentials.json` and then the Keychain API. It is never written
  anywhere by this app — not to its config, not to logs, not to disk.
- `OAuthCredentials` overrides `description` and `debugDescription` to print
  `<redacted>`, so interpolating one into a log line cannot leak it. There is a
  unit test asserting this, specifically so that deleting the redaction turns
  the build red.
- The diagnostic command prints token *metadata* only — length, expiry — never
  a value.
- **No credential of any kind is committed to this repository**, and
  `.gitignore` blocks the usual shapes as a backstop.

Claude Code does not use one fixed Keychain service name. It builds one:

```
"Claude Code" + <build-channel suffix> + "-credentials" + <config-dir hash>
```

where the trailing hash is present only when `CLAUDE_CONFIG_DIR` is set. So the
app discovers the name by pattern instead of hardcoding a spelling that is
right on some machines and wrong on others.

### Why `/usr/bin/security` comes first

Keychain access is granted per *application*, and Claude Code creates its
credential item by shelling out to `security add-generic-password` — which puts
`/usr/bin/security` on that item's access-control list. Reading through the
same tool is therefore silent, while calling `SecItemCopyMatching` from this app
is a different binary asking for someone else's item, which is exactly what
macOS puts a dialog in front of.

Related: those grants are bound to the app's **code identity**. An ad-hoc
signature changes identity on every rebuild, so "Always Allow" is invalidated
each time you rebuild — the classic "I keep allowing it and it never sticks".
The build script therefore signs with a real certificate when one exists
(any Apple Development cert; nothing here is distributed), which keeps the
grant stable across rebuilds:

```bash
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./Scripts/build-app.sh
```

### Why not an API key?

`ANTHROPIC_API_KEY` does not help here and would report the wrong thing. The
usage endpoint reports *subscription* limits — the Max plan's 5-hour, weekly
and per-model windows. An API key authenticates a separate pay-as-you-go
billing path; it is not accepted by this OAuth-scoped endpoint, and API console
spend has no relationship to your plan's quotas.

### If the widget shows no live data

The most common cause is a stale Keychain token. Claude Code refreshes tokens
in memory and does not always write the new value back, and the desktop app
keeps a separate session from the CLI. Run `claude` once in a terminal to
refresh the stored credential, then hit Refresh in the widget.

Note that an expired-looking `expiresAt` is deliberately *not* treated as fatal
— the app tries the request anyway and lets the server be the authority, since
a local timestamp is often wrong in the safe direction.

## Architecture

```
Sources/ClaudeUsageWidget/
├── main.swift                  entry point; --check and --render-preview
├── App/
│   ├── AppDelegate.swift       wiring, settings window
│   ├── WidgetPanel.swift       borderless non-activating NSPanel
│   ├── StatusItemController.swift
│   ├── Diagnostics.swift       --check
│   └── PreviewRenderer.swift   --render-preview
├── Core/
│   ├── Models.swift            RingMetric, RingDatum, UsageSnapshot
│   └── Config.swift            settings, persisted as JSON
├── Data/
│   ├── CredentialStore.swift   Keychain discovery + redaction
│   ├── OAuthUsageProvider.swift
│   ├── TranscriptProvider.swift
│   ├── Calibration.swift       learns real quotas from live readings
│   ├── Pricing.swift           per-model rates, user-overridable
│   └── UsageCoordinator.swift  merges sources, backs off on 429
└── UI/
    ├── ActivityRingsView.swift adaptive geometry, overflow laps
    ├── WidgetView.swift
    └── SettingsView.swift
```

Settings, calibration, the transcript index and any pricing overrides live in
`~/Library/Application Support/ClaudeUsageWidget/`.

Prices can be overridden without rebuilding — drop a `pricing.json` in that
directory:

```json
{ "claude-opus-5": { "input": 15, "output": 75, "cacheWrite": 18.75, "cacheRead": 1.5 } }
```

## Distribution

The Mac App Store is not an option for this app, and the reason is structural
rather than bureaucratic: **MAS requires sandboxing**, and a sandboxed app
cannot read Claude Code's Keychain item, cannot read `~/.claude/projects`
outside its container, and cannot invoke `/usr/bin/security`. That is every one
of this app's data paths.

The route for Mac utilities is **Developer ID + notarization** — no store, no
review.

### Generating the Xcode project

Everyday work needs no Xcode project (`swift build`, `swift test`,
`./Scripts/build-app.sh`). But a Swift *package* opened in Xcode has no
Signing & Capabilities tab and no `Product ▸ Archive`, so the Organizer flow
that notarizes a Developer ID build is unavailable. For that you need a real
App target:

```bash
brew install xcodegen && xcodegen generate && open ClaudeUsageWidget.xcodeproj
```

`project.yml` is the source of truth; the `.xcodeproj` is generated and
git-ignored, so it cannot drift from the sources or rot into an unreviewable
binary diff. Regenerate it whenever you add a file.

### Signing certificates: the iOS gotcha

An **Apple Development** certificate is not enough. Those are for local and
registered devices — an app signed with one is *blocked* on someone else's Mac.
Distribution needs a **Developer ID Application** certificate, created in
Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ **+**, which requires the
paid Apple Developer Program.

`Scripts/build-app.sh` deliberately prefers whatever certificate it finds for
*local* builds — that is only about keeping Keychain grants stable across
rebuilds, and is unrelated to distribution.

### Archiving and notarizing

In Xcode: select the target ▸ **Signing & Capabilities** ▸ set your Team, then
`Product ▸ Archive` ▸ **Distribute App** ▸ **Direct Distribution**. Xcode
notarizes and staples for you.

The equivalent from the command line:

```bash
xcrun notarytool submit ClaudeUsageWidget.zip --keychain-profile AC_PASSWORD --wait
```

```bash
xcrun stapler staple dist/ClaudeUsageWidget.app
```

Stapling matters — it embeds the ticket so the app validates without a network
round trip on your friend's machine.

Hardened runtime is enabled in `project.yml` (notarization rejects builds
without it) and the sandbox is explicitly off, for the reasons above.

### Or just have them build it

The repository is public and `./Scripts/build-app.sh` works from a clean clone.
For a technical friend that is zero cost and no Apple paperwork.

Either way, the widget is only useful to someone who has Claude Code signed in
on their own machine — it reads *their* credentials and *their* transcripts,
never yours.

## Tests

```bash
swift test
```

Covers the parts that fail quietly: tolerant decoding of the usage payload
(including unknown and renamed model windows), credential envelope parsing,
token redaction, longest-prefix price matching, and ring formatting including
the over-100% case.

## Caveats

- The usage endpoint is unofficial. If it changes, the live rings go quiet and
  the local estimator carries on.
- Local cost figures are list-price approximations used for *ratios*, not
  billing. They are not what you are charged.
- Only `.app`-bundle builds get a stable ad-hoc signature; rebuilding from a
  different path may re-prompt for Keychain access.

## License

MIT — see [LICENSE](LICENSE).
