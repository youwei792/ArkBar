# TokenBar

[简体中文](README.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md)

TokenBar is a native macOS menu-bar app for Volcengine Ark Coding/Agent Plan, OpenCode Go, DeepSeek, APINebula relay, Z.ai (Zhipu GLM), and Kimi For Coding usage. It keeps the quota you have **left** visible without a Dock icon.

## Highlights

- Native AppKit UI for macOS 14+.
- Per-plan session, weekly, and monthly remaining quota with reset countdowns.
- A gradient ring that becomes visually deeper as remaining quota gets low.
- Auto, `arkcli` SSO, AK/SK, and Ark API key data-source modes.
- DeepSeek monitoring: balance, today/monthly cost, token counts, request counts, and a cache hit/miss/output breakdown. The balance ring = this month's spend ÷ (spend + balance) and recalculates automatically after a top-up.
- DeepSeek credentials come from three sources: settings fields (stored in Keychain), environment variables, or the **signed-in DeepSeek Platform session in Chrome** (no key needed at all).
- APINebula (new-api relay) monitoring: a balance ring (cumulative spend ÷ spend + balance), today/monthly cost, token counts, request counts, and a cache-read/uncached/output split aggregated from the console usage log.
- APINebula balance and usage logs are console APIs: credentials come from the browser sign-in session (imported explicitly in Settings and cached in Keychain), with an optional API key fallback.
- Instant Ark/OpenCode Go/DeepSeek/APINebula/Z.ai/Kimi switching with isolated refresh and error state.
- An **Overview** tab lists every visible provider's remaining percent with a teal→blue capsule meter; click a row to open that provider's full card. Toggle it in **Settings → General**.
- Each provider can be independently shown/hidden from its own settings pane; hidden providers leave the switcher and stop refreshing.
- Menu-bar styles: meter bar, bar + percent, percent only, logo only, logo + percent, and logo + bar. Logo glyphs are 16pt and percent text uses the system font size, matching CodexBar's menu-bar scale.
- System, Simplified Chinese, and English interfaces.
- No telemetry. OpenCode/APINebula browser import runs only after an explicit user action. Sessions and API keys are stored in the local Keychain and mirrored to a file cache in the app-support directory, so ordinary restarts never prompt for the Keychain password.

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
| APINebula (relay) | Explicitly choose **Re-import Browser Sign-in** in **Settings → APINebula Relay** (console session cached in Keychain); optional API key | Balance/cumulative spend from the console `api/user/self`; today/monthly cost, tokens, request counts, and the cache-read/uncached/output split from the `api/log/self` usage log (cache tokens live in the log's `other` field). Balance and logs are console APIs; API keys only guarantee `/v1` model calls. |
| Z.ai (Zhipu GLM) | API key entered in **Settings → Z.ai Coding Plan** (stored in Keychain + file cache); optional `Z_AI_API_KEY` environment fallback; API region Global (`api.z.ai`) or BigModel CN (`open.bigmodel.cn`, default) | Reads the Coding Plan quota windows from `api/monitor/usage/quota/limit`: a 5-hour + weekly pair (session/weekly rings), plus a monthly MCP time window (monthly ring) on some plans. Credential precedence: settings > environment. |
| Kimi For Coding | API key entered in **Settings → Kimi For Coding** (stored in Keychain + file cache); optional `KIMI_CODE_API_KEY` environment fallback | Reads the membership quota from `api.kimi.com/coding/v1/usages`: total weekly quota (weekly ring) plus a 5-hour rate-limit window (session ring). Credential precedence: settings > environment. |

See the official [Ark CLI installation guide](https://github.com/volcengine/ark-cli) for the current CLI setup.

Never commit credentials. Set them in your shell environment before launching TokenBar:

```bash
export VOLCENGINE_ACCESS_KEY_ID='...'
export VOLCENGINE_SECRET_ACCESS_KEY='...'
export Z_AI_API_KEY='...'
export KIMI_CODE_API_KEY='...'
.build/debug/TokenBar
```

## Reading the UI

- All prominent percentages mean **remaining** quota, not consumed quota.
- The menu-bar item shows the selected tab's current Session / 5-hour quota left; in **Overview** mode it shows the tightest (lowest remaining) provider. The style (meter bar, percent, provider logo, or a combination) is chosen in **Settings → Appearance → Display mode**.
- The switcher's leading **Overview** tab is optional; with 4+ tabs the switcher collapses to icons (full names in tooltips).
- The ring centre shows the Session (or 5-hour) quota left, and every ring fills from its own **remaining** value—100% is a full ring.
- The three ring rows are Session, Weekly, and Monthly remaining quota; each row keeps its own reset countdown.
- The DeepSeek tab uses a single balance ring: used share = this month's cost ÷ (cost + balance). Topping up raises the balance, so the ring recalculates on the next refresh. Below the ring, the cache hit/miss/output breakdown and the top model are shown.
- The APINebula tab uses a single balance ring: used share = cumulative spend ÷ (spend + balance). Below the ring, the cache-read/uncached/output breakdown and the top model are shown.
- The Z.ai (Zhipu GLM) tab shows Coding Plan quota rings: the 5-hour window drives the session ring, the weekly window the weekly ring, and an optional monthly MCP time window (monthly ring) on some plans. Rings and legend rows fill from their **remaining** values.
- The Kimi For Coding tab shows membership quota rings: the total weekly quota drives the weekly ring and the 5-hour rate-limit window the session ring. Rings and legend rows fill from their **remaining** values.
- A refresh failure preserves the last confirmed data and marks it stale.
- By default, data refreshes only on the interval selected in **Settings → Refresh**. Enable **Refresh when opening the menu bar item** to also refresh whenever the status item is opened; overlapping triggers are coalesced into one request.
- Manual **Refresh** keeps the panel open, shows a live refreshing state, then reports “Updated just now” / a relative update time or a failure reason.
- The interface follows the system language by default. Change it in **Settings → Language**.

## Subscription-expiry data

Quota reset time is not subscription expiry. TokenBar displays a plan-expiry badge only when a provider exposes a verified order end date. The currently supported `arkcli usage plan` response does not provide that value, so TokenBar intentionally hides the badge instead of guessing from a reset time or local profile cache.

## Privacy

- OpenCode browser import reads the `opencode.ai` authentication cookie only after **Re-import Browser Session** is clicked. It does not read browsing history or scan arbitrary files.
- TokenBar keeps only the `auth` / `__Host-auth` cookie and stores it in the local macOS Keychain, mirrored to `~/Library/Application Support/TokenBar/credentials.json` (mode 0600). Startup, scheduled refresh, and ordinary manual refresh read the file cache first and never re-prompt the Keychain.
- A manually pasted OpenCode Cookie is also stored only in the local Keychain + file cache, never UserDefaults, source files, or logs.
- DeepSeek automatic access, when no Keychain/environment credential is set, silently reads the `userToken` of `platform.deepseek.com` from Chrome's local storage (plaintext browser entries) and uses it only to call DeepSeek platform endpoints. TokenBar never writes it to disk; the browser source label is shown in Settings.
- APINebula browser access reads the `apinebula.ai` console session cookie (and the account id from localStorage) only after **Re-import Browser Sign-in** is clicked, and uses them only for the balance/log endpoints, writing to the Keychain + file cache.
- Browser-session import (OpenCode/APINebula) is an explicit settings action; background and startup refreshes never read browser cookie stores or prompt for Keychain passwords.
- API Keys / Platform Tokens entered in the DeepSeek settings pane are stored only in the local Keychain + file cache, never UserDefaults, source files, or logs.
- The Z.ai API key entered in Settings is likewise stored only in the local Keychain + file cache, never UserDefaults, source files, or logs; the region preference is plain UserDefaults and holds no credentials.
- The Kimi API key entered in Settings is likewise stored only in the local Keychain + file cache, never UserDefaults, source files, or logs.
- `arkcli` keeps ownership of its SSO session; TokenBar only runs `arkcli usage plan --format json` and parses its output.
- AK/SK and Ark API keys are read from the launch environment and are never written to disk by TokenBar.
- Network requests go only to the required Volcengine Ark endpoints, `opencode.ai`, `platform.deepseek.com`, the Z.ai quota endpoint (`open.bigmodel.cn` / `api.z.ai`), or the Kimi quota endpoint (`api.kimi.com`).

## Development

```bash
swift test
```

The test suite covers Ark CLI, OpenAPI, OpenCode Go, DeepSeek, Z.ai, and Kimi decoding, DeepSeek balance/usage aggregation, browser-session token extraction, time formatting, icon rendering, refresh interaction, and menu-card layout regressions. GitHub Actions runs the same test command for pull requests and pushes to `main`.

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
  NebulaProvider.swift APINebula relay balance/log provider
  NebulaBrowserSession.swift explicit console cookie + user-id importer
  NebulaCardView.swift single balance-ring menu card
  ZaiProvider.swift    Z.ai (Zhipu GLM) Coding Plan quota provider
  KimiProvider.swift   Kimi For Coding membership quota provider
  ProviderLogo.swift     provider brand icons (doubao/opencode/deepseek/apinebula/zai/kimi)
  CookieKeychainStore.swift Keychain + file-cache credential store
  CredentialFileCache.swift on-disk credential mirror (mode 0600)
  MenuBuilder.swift      menu construction incl. SummaryRowView overview rows
  ProviderSwitcherView.swift switcher with optional Overview tab
  UsageStore.swift       source selection and refresh lifecycle
  PlanCardView.swift     menu-card layout and remaining-quota ring
  Localization.swift     Simplified Chinese and English catalog
Scripts/package_app.sh   local Apple Silicon app packaging
Tests/TokenBarTests/       decoding and visual regression tests
```

## License and attribution

TokenBar is released under the [MIT License](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the CodexBar and SweetCookieKit notices.
