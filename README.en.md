# ArkBar

[简体中文](README.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md)

ArkBar is a native macOS menu-bar app for Volcengine Ark Coding Plan and Agent Plan usage. It keeps the quota you have **left** visible without a Dock icon.

## Highlights

- Native AppKit UI for macOS 14+.
- Per-plan session, weekly, and monthly remaining quota with reset countdowns.
- A gradient ring that becomes visually deeper as remaining quota gets low.
- Auto, `arkcli` SSO, AK/SK, and Ark API key data-source modes.
- System, Simplified Chinese, and English interfaces.
- No telemetry, browser-cookie access, Keychain access, or credential storage.

## Quick start

### Build from source

Requirements: macOS 14+, Swift 6.0, and one supported authentication source.

```bash
git clone https://github.com/youwei792/ArkBar.git
cd ArkBar
swift build
.build/debug/ArkBar
```

### Package a local app

```bash
./Scripts/package_app.sh
```

This development script builds an Apple Silicon (`arm64`) app, replaces the local `ArkBar.app` bundle, and replaces `/Applications/ArkBar.app`. It ad-hoc signs the result; it is not a notarized release installer.

## Authentication and data sources

In **Auto** mode, ArkBar prefers explicitly configured credentials, then falls back to `arkcli`. The first successful source is shown in the menu.

| Source | Configuration | Coverage and limits |
| --- | --- | --- |
| `arkcli` SSO (recommended) | `npm install -g @volcengine/ark-cli` then `arkcli auth login volc-sso` | Personal and team Coding/Agent Plan usage exposed by `arkcli usage plan`. |
| Volcengine AK/SK | `VOLCENGINE_ACCESS_KEY_ID` and `VOLCENGINE_SECRET_ACCESS_KEY` | Coding Plan usage only, via signed `GetCodingPlanUsage`. |
| Ark API key | `ARK_API_KEY`; optionally `ARK_MODEL_ID` | One request-rate-limit window only. The probe sends a minimal API request, so it can consume request quota. |

See the official [Ark CLI installation guide](https://github.com/volcengine/ark-cli) for the current CLI setup.

Never commit credentials. Set them in your shell environment before launching ArkBar:

```bash
export VOLCENGINE_ACCESS_KEY_ID='...'
export VOLCENGINE_SECRET_ACCESS_KEY='...'
.build/debug/ArkBar
```

## Reading the UI

- All prominent percentages mean **remaining** quota, not consumed quota.
- The menu-bar capsule reflects the tightest quota window across available plans.
- The three ring rows are Session, Weekly, and Monthly remaining quota; each row keeps its own reset countdown.
- A refresh failure preserves the last confirmed data and marks it stale.
- By default, data refreshes only on the interval selected in **Settings → Refresh**. Enable **Refresh when opening the menu bar item** to also refresh whenever the status item is opened; overlapping triggers are coalesced into one request.
- The interface follows the system language by default. Change it in **Settings → Language**.

## Subscription-expiry data

Quota reset time is not subscription expiry. ArkBar displays a plan-expiry badge only when a provider exposes a verified order end date. The currently supported `arkcli usage plan` response does not provide that value, so ArkBar intentionally hides the badge instead of guessing from a reset time or local profile cache.

## Privacy

- ArkBar does not read browser cookies, Keychain entries, or arbitrary files.
- `arkcli` keeps ownership of its SSO session; ArkBar only runs `arkcli usage plan --format json` and parses its output.
- AK/SK and API keys are read from the launch environment and are never written to disk by ArkBar.
- Network requests go only to Volcengine Ark endpoints required by the selected source.

## Development

```bash
swift test
```

The test suite covers Ark CLI and OpenAPI decoding, time formatting, icon rendering, and menu-card layout regressions. GitHub Actions runs the same test command for pull requests and pushes to `main`.

## Project structure

```text
Sources/ArkBar/
  ArkCLIFetcher.swift    arkcli SSO usage provider
  VolcAPIProvider.swift  AK/SK signed Coding Plan provider
  ArkAPIKeyProvider.swift API-key rate-limit probe provider
  UsageStore.swift       source selection and refresh lifecycle
  PlanCardView.swift     menu-card layout and remaining-quota ring
  Localization.swift     Simplified Chinese and English catalog
Scripts/package_app.sh   local Apple Silicon app packaging
Tests/ArkBarTests/       decoding and visual regression tests
```

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md), keep credentials out of logs and fixtures, and run `swift test` before opening a pull request.

## License and attribution

ArkBar is released under the [MIT License](LICENSE). Parts of the architecture and rendering approach were adapted from CodexBar; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
