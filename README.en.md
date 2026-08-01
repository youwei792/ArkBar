# TokenBar

[简体中文](README.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md)

TokenBar is a native macOS menu-bar app for Volcengine Ark Coding/Agent Plan, OpenCode Go, and DeepSeek usage. It keeps the quota you have **left** visible without a Dock icon.

## Highlights

- Native AppKit UI for macOS 14+.
- Per-plan session, weekly, and monthly remaining quota with reset countdowns.
- A gradient ring that becomes visually deeper as remaining quota gets low.
- Auto, `arkcli` SSO, AK/SK, and Ark API key data-source modes.
- DeepSeek monitoring: balance, today/monthly cost, token counts, request counts, and a cache hit/miss/output breakdown. The balance ring = this month's spend ÷ (spend + balance) and recalculates automatically after a top-up.
- DeepSeek credentials come from three sources: settings fields (stored in Keychain), environment variables, or the **signed-in DeepSeek Platform session in Chrome** (no key needed at all).
- Instant Ark/OpenCode Go/DeepSeek switching with isolated refresh and error state.
- Each provider can be independently shown/hidden from its own settings pane; hidden providers leave the switcher and stop refreshing.
- Menu-bar styles: meter bar, bar + percent, percent only, logo only, logo + percent, and logo + bar.
- System, Simplified Chinese, and English interfaces.
- No telemetry. OpenCode browser import runs only after an explicit user action and stores only the filtered authentication cookie in the local Keychain.

## Quick start

### Build from source

Requirements: macOS 14+, Swift 6.0, and one supported authentication source.

```bash
git clone https://github.com/youwei792/TokenBar.git
cd TokenBar
swift build
.build/debug/TokenBar
```

### Package a local app

```bash
./Scripts/package_app.sh
```

This development script builds an Apple Silicon (`arm64`) app, replaces the local `TokenBar.app` bundle, and replaces `/Applications/TokenBar.app`. It ad-hoc signs the result; it is not a notarized release installer.

### Intel and Universal Binary builds (maintainer reference)

`swift build` targets the current Mac's native architecture by default. On an Intel Mac that meets the macOS 14+ and Swift 6.0 requirements, the **Build from source** command therefore produces an `x86_64` executable without Rosetta.

The current `Scripts/package_app.sh` intentionally produces an `arm64` development `.app` only; it cannot make an Intel or Universal installer. The source has no known `arm64`-specific dependency, but the Intel path has not yet been verified on Intel hardware or CI. This is a build guide, not a released compatibility guarantee.

To ship a Universal Binary, produce and validate independent `arm64` and `x86_64` slices in the release process, then merge them with the macOS-provided `lipo` tool:

```bash
lipo -create -output TokenBar <path-to-arm64-TokenBar> <path-to-x86_64-TokenBar>
lipo -archs TokenBar
# Expected: both arm64 and x86_64, in either order.
```

This creates a Universal **executable**, not a Universal `.app`. To publish the latter, place it at `TokenBar.app/Contents/MacOS/TokenBar`, sign the bundle again, and test it separately on Apple Silicon and Intel Macs. Do not run the current `package_app.sh` afterwards: it would replace the app executable with a single arm64 slice.

## Authentication and data sources

In **Auto** mode, TokenBar prefers explicitly configured credentials, then falls back to `arkcli`. The first successful source is shown in the menu.

| Source | Configuration | Coverage and limits |
| --- | --- | --- |
| `arkcli` SSO (recommended) | `npm install -g @volcengine/ark-cli` then `arkcli auth login volc-sso` | Personal and team Coding/Agent Plan usage exposed by `arkcli usage plan`. |
| Volcengine AK/SK | `VOLCENGINE_ACCESS_KEY_ID` and `VOLCENGINE_SECRET_ACCESS_KEY` | Coding Plan usage only, via signed `GetCodingPlanUsage`. |
| Ark API key | `ARK_API_KEY`; optionally `ARK_MODEL_ID` | One request-rate-limit window only. The probe sends a minimal API request, so it can consume request quota. |
| OpenCode Go | Explicitly choose **Re-import Browser Session** in **Settings → OpenCode Go**, or select a manual Cookie | Subscription usage returned by `opencode.ai`; TokenBar never substitutes a local spending estimate. |
| DeepSeek | Any of: API Key / Platform Token entered in Settings (stored in Keychain), environment variables `DEEPSEEK_API_KEY` / `DEEPSEEK_PLATFORM_TOKEN`, or simply signing in to platform.deepseek.com in Chrome | Balance from `api.deepseek.com/user/balance` (or the platform wallets); today/monthly cost, tokens, request counts, and the category breakdown from the platform `usage/amount` + `usage/cost` endpoints. Credential precedence: settings > environment > Chrome session. |

See the official [Ark CLI installation guide](https://github.com/volcengine/ark-cli) for the current CLI setup.

Never commit credentials. Set them in your shell environment before launching TokenBar:

```bash
export VOLCENGINE_ACCESS_KEY_ID='...'
export VOLCENGINE_SECRET_ACCESS_KEY='...'
.build/debug/TokenBar
```

## Reading the UI

- All prominent percentages mean **remaining** quota, not consumed quota.
- The menu-bar item shows the selected tab's current Session / 5-hour quota left; the style (meter bar, percent, provider logo, or a combination) is chosen in **Settings → Appearance → Display mode**.
- The ring centre shows the Session (or 5-hour) quota left, and every ring fills from its own **remaining** value—100% is a full ring.
- The three ring rows are Session, Weekly, and Monthly remaining quota; each row keeps its own reset countdown.
- The DeepSeek tab uses a single balance ring: used share = this month's cost ÷ (cost + balance). Topping up raises the balance, so the ring recalculates on the next refresh. Below the ring, the cache hit/miss/output breakdown and the top model are shown.
- A refresh failure preserves the last confirmed data and marks it stale.
- By default, data refreshes only on the interval selected in **Settings → Refresh**. Enable **Refresh when opening the menu bar item** to also refresh whenever the status item is opened; overlapping triggers are coalesced into one request.
- Manual **Refresh** keeps the panel open, shows a live refreshing state, then reports “Updated just now” / a relative update time or a failure reason.
- The interface follows the system language by default. Change it in **Settings → Language**.

## Subscription-expiry data

Quota reset time is not subscription expiry. TokenBar displays a plan-expiry badge only when a provider exposes a verified order end date. The currently supported `arkcli usage plan` response does not provide that value, so TokenBar intentionally hides the badge instead of guessing from a reset time or local profile cache.

## Privacy

- OpenCode browser import reads the `opencode.ai` authentication cookie only after **Re-import Browser Session** is clicked. It does not read browsing history or scan arbitrary files.
- TokenBar keeps only the `auth` / `__Host-auth` cookie and stores it in the local macOS Keychain. Startup, scheduled refresh, and ordinary manual refresh use that cache instead of repeatedly reading the browser.
- A manually pasted OpenCode Cookie is also stored only in the local Keychain, never UserDefaults, source files, or logs.
- DeepSeek automatic access, when no Keychain/environment credential is set, silently reads the `userToken` of `platform.deepseek.com` from Chrome's local storage (plaintext browser entries) and uses it only to call DeepSeek platform endpoints. TokenBar never writes it to disk; the browser source label is shown in Settings.
- API Keys / Platform Tokens entered in the DeepSeek settings pane are stored only in the local Keychain, never UserDefaults, source files, or logs.
- `arkcli` keeps ownership of its SSO session; TokenBar only runs `arkcli usage plan --format json` and parses its output.
- AK/SK and Ark API keys are read from the launch environment and are never written to disk by TokenBar.
- Network requests go only to the required Volcengine Ark endpoints, `opencode.ai`, or `platform.deepseek.com`.

## Development

```bash
swift test
```

The test suite covers Ark CLI, OpenAPI, OpenCode Go, and DeepSeek decoding, DeepSeek balance/usage aggregation, browser-session token extraction, time formatting, icon rendering, refresh interaction, and menu-card layout regressions. GitHub Actions runs the same test command for pull requests and pushes to `main`.

## Project structure

```text
Sources/TokenBar/
  ArkCLIFetcher.swift    arkcli SSO usage provider
  VolcAPIProvider.swift  AK/SK signed Coding Plan provider
  ArkAPIKeyProvider.swift API-key rate-limit probe provider
  OpenCodeGoProvider.swift authoritative OpenCode Go usage provider
  OpenCodeGoBrowserSession.swift explicit browser-session importer
  DeepSeekProvider.swift DeepSeek balance/usage provider
  DeepSeekBrowserSession.swift silent Chrome local-storage session resolver
  DeepSeekCardView.swift single balance-ring menu card
  ProviderLogo.swift     provider brand icons (doubao/opencode/deepseek SVGs)
  UsageStore.swift       source selection and refresh lifecycle
  PlanCardView.swift     menu-card layout and remaining-quota ring
  Localization.swift     Simplified Chinese and English catalog
Scripts/package_app.sh   local Apple Silicon app packaging
Tests/TokenBarTests/       decoding and visual regression tests
```

## License and attribution

TokenBar is released under the [MIT License](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the CodexBar and SweetCookieKit notices.
