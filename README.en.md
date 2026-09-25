# TokenBar

[简体中文](README.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md)

TokenBar is a native macOS menu-bar app for Volcengine Ark Coding/Agent Plan, OpenCode Go, DeepSeek, APINebula relay, Z.ai (Zhipu GLM), Kimi For Coding, GrokPool gateway, LongCat (longcat.chat), Alibaba Cloud (百炼) Coding Plan / Token Plan, StepFun Step Plan, and SenseNova Token Plan usage — and it nags you when a subscription is about to expire with quota left. It keeps the quota you have **left** visible without a Dock icon.

> The repository is named `ArkBar`; the user-facing product, Swift package, executable, and `.app` bundle are all named `TokenBar`. The current source and local-package version is `0.1.0` (Unreleased). As of September 1, 2026, the remote repository has no Git tag or GitHub Release. The steps below are for source builds and local development packages only, not a published installer.

## Highlights

- Native AppKit UI for macOS 14+.
- Per-plan session, weekly, and monthly remaining quota with reset countdowns.
- A gradient ring that becomes visually deeper as remaining quota gets low.
- Auto, `arkcli` SSO, AK/SK (enterable in Settings; long-lived), and Ark API key data-source modes.
- DeepSeek monitoring: balance, today/monthly cost, token counts, request counts, and a cache hit/miss/output breakdown. The balance ring = this month's spend ÷ (spend + balance) and recalculates automatically after a top-up.
- DeepSeek credentials come from three sources: settings fields (stored in Keychain), environment variables, or the **signed-in DeepSeek Platform session in Chrome** (no key needed at all).
- APINebula (new-api relay) monitoring: a balance ring (cumulative spend ÷ spend + balance), today/monthly cost, token counts, request counts, and a cache-read/uncached/output split aggregated from the console usage log.
- APINebula balance and usage logs are console APIs: credentials come from the browser sign-in session (imported explicitly in Settings and cached in Keychain), with an optional API key fallback.
- GrokPool (grok2api admin gateway) monitoring: sign in with the administrator account (`POST /api/admin/v1/auth/login`) for a short-lived access token and read the **24-hour dashboard** (`GET /api/admin/v1/dashboard?period=24h`): request counts/success rate, billed cost, input/cached/output/reasoning tokens, active accounts, and the top model. The success ring = successful request share; fully isolated from the APINebula tab (separate settings and state). Billing converts at grok2api's 10^10 ticks = $1.
- LongCat (longcat.chat) monitoring: usage endpoints live behind the longcat.chat console (not api.longcat.chat) and authenticate with a browser sign-in session. The remaining-quota ring = remaining-token share of the active token pack; beside the ring are total / used (with used percent) / remaining (with remaining percent), plus an optional fuel-pack balance and nearest-expiry countdown below the ring.
- Instant Ark/OpenCode Go/DeepSeek/APINebula/Z.ai/Kimi/GrokPool/LongCat/Alibaba Cloud/StepFun/SenseNova switching with isolated refresh and error state.
- **Expiry reminders**: an "Expiring subscriptions" section at the top of the Overview menu lists every integrated plan with a verified expiry date (OpenCode Go renewal, LongCat pack expiry, …) plus user-managed manual entries, color-coded by days left. The nag only fires when a plan expires within the lead time (3/7/14/30 days, default 7) and still holds ≥50% quota, so nearly exhausted plans stay quiet. Optional macOS notifications de-duplicate to one per subscription per day (they only appear in the packaged app; when running from source the in-menu section is authoritative). Manage the toggle, lead time, and manual list in **Settings → Expiry Reminders**.
- An **Overview** tab lists every visible provider's remaining percent with a teal→blue capsule meter; click a row to open that provider's full card. Toggle it in **Settings → General**.
- Each provider can be independently shown/hidden from its own settings pane; hidden providers leave the switcher and stop refreshing.
- Menu-bar styles: rings, rings + percent, percent only, logo only, logo + percent, and logo + rings. Logo glyphs are 16pt and percent text uses the system font size. The rings mirror the cards: three-window plans show monthly (outer) / weekly (middle) / 5-hour (inner) concentric rings, while single-window balance providers show one ring.
- For DeepSeek and APINebula you can choose, per provider, whether the menu bar shows the remaining percent or the money balance with its currency symbol: DeepSeek shows `¥` (CNY) or `$` (USD) depending on the wallet currency returned by the API, APINebula always shows `¥` (CNY), both with two decimals. GrokPool toggles between the success percent and the 24h cost (`$`). The status item widens automatically in balance/cost mode to fit the amount.
- System, Simplified Chinese, and English interfaces.
- No telemetry. OpenCode/APINebula browser import runs only after an explicit user action. Sessions and API keys are stored in the local Keychain and mirrored to a file cache in the app-support directory, so ordinary restarts never prompt for the Keychain password.

## Quick start

### Build from source

Requirements: macOS 14+, Swift 6.0, and one supported authentication source.

```bash
git clone https://github.com/youwei792/ArkBar.git
cd ArkBar
swift build
.build/debug/TokenBar
```

### Package a local app

```bash
./Scripts/package_app.sh
```

This development script builds an Apple Silicon (`arm64`) app, replaces the local `TokenBar.app` bundle, and replaces `/Applications/TokenBar.app`. It signs with a stable identity when one is available (`TOKENBAR_SIGN_IDENTITY`, defaulting to an existing Apple Development identity); when none is found it falls back to ad-hoc signing with a warning — ad-hoc signatures change on every build, which revokes the Full Disk Access and browser Keychain grants the user already approved. It is not a notarized release installer.

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
| Volcengine AK/SK | Any of: enter the Access Key / Secret Key in **Settings → Ark Plans** (stored in Keychain + file cache), or environment variables `VOLCENGINE_ACCESS_KEY_ID` and `VOLCENGINE_SECRET_ACCESS_KEY` | Coding Plan usage only, via signed `GetCodingPlanUsage`. IAM long-lived keys never expire: entering a read-only sub-account key pair once removes arkcli SSO's roughly-48-hour re-login cycle. Precedence: settings values > environment variables. |
| Ark API key | `ARK_API_KEY`; optionally `ARK_MODEL_ID` | One request-rate-limit window only. Probes zero-cost `GET /models` first for the gateway `x-ratelimit-*` headers; only when that route carries no quota headers does it fall back to a single minimal chat request (`max_tokens: 1`), which can consume a little request quota. |
| OpenCode Go | Explicitly choose **Re-import Browser Session** in **Settings → OpenCode Go**, or select a manual Cookie | Subscription usage returned by `opencode.ai`; TokenBar never substitutes a local spending estimate. |
| DeepSeek | Any of: API Key / Platform Token entered in Settings (stored in Keychain), environment variables `DEEPSEEK_API_KEY` / `DEEPSEEK_PLATFORM_TOKEN`, or simply signing in to platform.deepseek.com in Chrome | Balance from `api.deepseek.com/user/balance` (or the platform wallets); today/monthly cost, tokens, request counts, and the category breakdown from the platform `usage/amount` + `usage/cost` endpoints. Credential precedence: settings > environment > Chrome session. |
| APINebula (relay) | Explicitly choose **Re-import Browser Sign-in** in **Settings → APINebula Relay** (console session cached in Keychain); optional API key | Balance/cumulative spend from the console `api/user/self`; today/monthly cost, tokens, request counts, and the cache-read/uncached/output split from the `api/log/self` usage log (cache tokens live in the log's `other` field). Balance and logs are console APIs; API keys only guarantee `/v1` model calls. |
| Z.ai (Zhipu GLM) | API key entered in **Settings → Z.ai Coding Plan** (stored in Keychain + file cache); optional `Z_AI_API_KEY` environment fallback; API region Global (`api.z.ai`) or BigModel CN (`open.bigmodel.cn`, default) | Reads the Coding Plan quota windows from `api/monitor/usage/quota/limit`: a 5-hour + weekly pair (session/weekly rings), plus a monthly MCP time window (monthly ring) on some plans. Credential precedence: settings > environment. |
| Kimi For Coding | API key optional (entered in **Settings → Kimi For Coding**, stored in Keychain + file cache; `KIMI_CODE_API_KEY` environment fallback); choose **Re-import Browser Sign-in** to also read the shared pool from the `www.kimi.com` session | Reads the Code membership quota from `api.kimi.com/coding/v1/usages`: total weekly quota (weekly ring) plus a 5-hour rate-limit window (session ring); the browser session also reads `GetSubscriptionStats` from `www.kimi.com` and maps the **shared Kimi Code + Kimi Work pool** to the monthly ring. Credential precedence: settings > environment. |
| GrokPool (grok2api gateway) | Administrator username and password entered in **Settings → GrokPool Gateway** (stored in Keychain + file cache); optional `GROKPOOL_USERNAME` / `GROKPOOL_PASSWORD` environment fallback; base URL defaults to `https://grok.axonlume.com` | Signs in as the gateway administrator (`POST /api/admin/v1/auth/login`) for a short-lived Bearer access token, then reads the 24-hour dashboard (`GET /api/admin/v1/dashboard?period=24h`): requests and success rate, billed cost (10^10 ticks = $1), the input/cached/output/reasoning token split, active accounts, and the top model. The token refreshes automatically every 15 minutes and 401s trigger a re-login. |
| LongCat (longcat.chat) | Choose **Re-import Browser Sign-in** in **Settings → LongCat** to import the `longcat.chat` session (stored in Keychain + file cache); multi-browser fallback across Chrome / Arc / Safari / Edge / Brave / Firefox; optional manual Cookie header or `LONGCAT_MANUAL_COOKIE` environment fallback | Usage endpoints live behind the longcat.chat console (not api.longcat.chat). Reads the active token pack from `POST /api/pay/quota/metering/token-packs/summary` (`data.currentLot`: `totalToken` / `consumedToken` / `remainingToken` / `expireTime`); the remaining ring = remaining-token share. Optionally reads pending fuel packs for a supplementary balance and the nearest expiry. Credential source is explicit: **Automatic** = browser session > environment variable; **Manual** = only the pasted Cookie. Import requires the `passport_token_key` sign-in cookie. |
| Alibaba Cloud (百炼) Coding Plan / Token Plan | **Browser sign-in** in **Settings → Alibaba Cloud Bailian** (recommended, no AK/SK): the Bailian console login page opens in your browser and returns automatically. An Aliyun AK/SK pair or the `sk-sp-` plan key also work (stored in Keychain + file cache; a read-only RAM sub-account with `modelstudio:GenerateCLIAccessToken` is recommended for AK/SK). Environment fallbacks: `ALIYUN_ACCESS_KEY_ID` / `ALIYUN_ACCESS_KEY_SECRET`, `ALIYUN_CODING_PLAN_API_KEY` | Alibaba publishes no public usage API: TokenBar reads usage through the same console gateway the official `bl` CLI uses. Browser sign-in obtains the console access token directly — the identical mechanism as `bl auth login --console` (a loopback port receives the callback; the token is stored in Keychain). AK/SK mints the token via an ACS3-signed call instead (cached in memory ~10 minutes, re-minted on 401). The account's plan is detected automatically: a **Token Plan** (credit-based) renders 5-hour / weekly / monthly used-ratio rings (an Essential personal plan publishes the monthly one only — a window that is absent is simply not rendered); a **Coding Plan** (request-based) renders the 5-hour 6,000 / weekly 45,000 / monthly 90,000 request windows as absolute counts. Once detected, each refresh queries only that plan's API (Token Plan adds one subscription-record call, which is where the expiry date and the plan tier come from; both are quota-free metadata calls). **A browser sign-in hands out a console token that lives only a few minutes**, so it needs a fresh click once it expires; with AK/SK configured the app re-mints the token by itself. |
| StepFun | Click “Re-import Browser Sign-in” in **Settings → StepFun Step Plan** to capture the console session (cookie auth, auto-rotated; requires Full Disk Access) | Console Connect-RPC: rotates the session via `RefreshToken`, then queries `QueryStepPlanRateLimit` + `GetStepPlanStatus`. The Plus plan shows a single monthly-credit ring (plus the expiry badge); plans with 5-hour/weekly windows show all three rings automatically. API keys cannot read plan quota (vendor restriction). |
| SenseNova | Click “Re-import Browser Sign-in” in **Settings → SenseNova Token Plan** to capture the console session (Full Disk Access required) | Token Plan free beta (dual credit pools: general + Flash-Lite, each with weekly balance / 5-hour window / weekly quota). The console `pool-usage` endpoint only accepts the SPA's OAuth bearer, so after import TokenBar completes the Hydra authorization-code + PKCE exchange headlessly and keeps the session alive on the refresh token (access tokens last three hours). Each credit pool renders its own rings. |

See the official [Ark CLI installation guide](https://github.com/volcengine/ark-cli) for the current CLI setup.

Never commit credentials. Set them in your shell environment before launching TokenBar:

```bash
export VOLCENGINE_ACCESS_KEY_ID='...'
export VOLCENGINE_SECRET_ACCESS_KEY='...'
export Z_AI_API_KEY='...'
export KIMI_CODE_API_KEY='...'
export GROKPOOL_USERNAME='...'
export GROKPOOL_PASSWORD='...'
export LONGCAT_MANUAL_COOKIE='...'
export ALIYUN_ACCESS_KEY_ID='...'
export ALIYUN_ACCESS_KEY_SECRET='...'
.build/debug/TokenBar
```

## Reading the UI

- All prominent percentages mean **remaining** quota, not consumed quota.
- The menu-bar rings follow CodexBar's binding-constraint rule: it shows the selected tab's current Session / 5-hour quota left by default, but a fully exhausted longer window (weekly/monthly) takes over — e.g. with the weekly pool spent and the session ring back at 100%, the item honestly reads 0% instead of a misleading 100%. In **Overview** mode it shows the tightest (lowest remaining) provider. The style (rings, percent, provider logo, or a combination) is chosen in **Settings → Appearance → Display mode**.
- The switcher's leading **Overview** tab is optional; with 4+ tabs the switcher collapses to icons (full names in tooltips).
- The ring centre shows the Session (or 5-hour) quota left, and every ring fills from its own **remaining** value—100% is a full ring.
- The three ring rows are Session, Weekly, and Monthly remaining quota; each row keeps its own reset countdown.
- The DeepSeek tab uses a single balance ring: used share = this month's cost ÷ (cost + balance). Topping up raises the balance, so the ring recalculates on the next refresh. Below the ring, the cache hit/miss/output breakdown and the top model are shown. In that provider's "Menu bar shows" setting you can display either the remaining percent or the balance (DeepSeek balance carries the `¥`/`$` symbol for its currency).
- The APINebula tab uses a single balance ring: used share = cumulative spend ÷ (spend + balance). Below the ring, the cache-read/uncached/output breakdown and the top model are shown. In that provider's setting you can display either the remaining percent or the CNY balance (`¥`).
- The Z.ai (Zhipu GLM) tab shows Coding Plan quota rings: the 5-hour window drives the session ring, the weekly window the weekly ring, and an optional monthly MCP time window (monthly ring) on some plans. Rings and legend rows fill from their **remaining** values.
- The Kimi For Coding tab shows membership quota rings: Code's total weekly quota drives the weekly ring and the 5-hour rate-limit window the session ring; after importing the browser sign-in, the **shared Kimi Code + Kimi Work pool** additionally drives the monthly ring. Rings and legend rows fill from their **remaining** values.
- The GrokPool tab shows the 24-hour dashboard: the primary ring is the request success rate (remaining = success, 100% success is a full ring); beside the ring are Requests (OK/failed), Billed cost (`$`, 10^10 ticks = $1), and Success rate; below the ring are the input/cached/output/reasoning token split, active accounts, and the top model. Its settings pane chooses whether the menu bar shows the success percent or the 24h cost (`$`).
- The LongCat tab shows the token-pack remaining-quota ring: remaining percent = `remainingToken ÷ totalToken`; the three ring rows are total / used (with used percent) / remaining (with remaining percent); an optional fuel-pack balance and nearest-expiry countdown sit below the ring. The menu bar always shows the remaining percent.
- A refresh failure preserves the last confirmed data and marks it stale.
- By default, data refreshes only on the interval selected in **Settings → Refresh**. Enable **Refresh when opening the menu bar item** to also refresh whenever the status item is opened; overlapping triggers are coalesced into one request.
- Manual **Refresh** keeps the panel open, shows a live refreshing state, then reports “Updated just now” / a relative update time or a failure reason.
- The interface follows the system language by default. Change it in **Settings → Language**.

## Subscription-expiry data

Quota reset time is not subscription expiry. TokenBar displays a plan-expiry badge only when a provider exposes a verified order end date — it never guesses from a reset timestamp or the local credential cache. Verified sources today:

- **Volcengine Ark Coding / Agent Plan**: the signed OpenAPI action `ListSubscribeTrade` (queried on both the AK/SK and arkcli-SSO paths), taking `EndTime` of the `Status=Running` order — the console's "我的订阅 → 结束时间". Team editions are seat-scoped and never borrow the personal order's date.
- **Z.ai Coding Plan**: `GET /api/biz/subscription/list` (reuses the existing plan API key, no browser sign-in needed), taking `nextRenewTime` of the `status=VALID` order — the console's "套餐概览 → 有效期至"; the end of the order's `valid` range is the fallback when that field is absent.
- **OpenCode Go / Kimi / LongCat / StepFun / SenseNova / Alibaba Cloud**: each provider's own renewal or expiry field.

The expiry lookup is best effort: a failure hides the badge and leaves the rings and menu rendering untouched.

Expiry dates also feed the **Expiry Reminders** feature: integrated plans (Ark and Z.ai renewal dates, OpenCode Go renewals, LongCat pack expiries, …) are picked up automatically, and services TokenBar does not integrate can be added manually (name + expiry date + note) in **Settings → Expiry Reminders**.

## Privacy

- OpenCode browser import reads the `opencode.ai` authentication cookie only after **Re-import Browser Session** is clicked. It does not read browsing history or scan arbitrary files.
- TokenBar keeps only the `auth` / `__Host-auth` / `console_session` / `__Host-console_session` cookies and stores them in the local macOS Keychain, mirrored to `~/Library/Application Support/TokenBar/credentials.json` (mode 0600). Startup, scheduled refresh, and ordinary manual refresh read the file cache first and never re-prompt the Keychain.
- A manually pasted OpenCode Cookie is also stored only in the local Keychain + file cache, never UserDefaults, source files, or logs; pasted input is normalized first (a `Cookie:` prefix is stripped, attribute entries are dropped) before being saved.
- DeepSeek automatic access, when no Keychain/environment platform token is available, silently reads the `userToken` of `platform.deepseek.com` from Chrome's local storage (plaintext browser entries) and uses it only to call DeepSeek platform endpoints. TokenBar never writes it to disk; both the disk scan and the network validation are cached for 30 minutes so refreshes do not rescan every tick; the browser source label is shown in Settings.
- APINebula browser access reads the `apinebula.ai` console session cookie (and the account id from localStorage, bound to the same browser profile) only after **Re-import Browser Sign-in** is clicked, and uses them only for the balance/log endpoints, writing to the Keychain + file cache. Import requires the `session` sign-in cookie and fails explicitly when the account id cannot be read, instead of caching a session that cannot work.
- Browser-session import (OpenCode/APINebula/Kimi/LongCat/StepFun/SenseNova) is an explicit settings action; background and startup refreshes never read browser cookie stores or prompt for Keychain passwords.
- Credentials for every provider are stored only in the local Keychain + file cache, never UserDefaults, source files, or logs; the Keychain prompt names the provider whose import you just triggered and states that macOS will confirm next.
- Network errors keep only a truncated single-line summary alongside the status code (`HTTPErrorSummary`); full response bodies never reach logs or the UI.
- API Keys / Platform Tokens entered in the DeepSeek settings pane are stored only in the local Keychain + file cache, never UserDefaults, source files, or logs.
- The Z.ai API key entered in Settings is likewise stored only in the local Keychain + file cache, never UserDefaults, source files, or logs; the region preference is plain UserDefaults and holds no credentials.
- The Kimi API key entered in Settings is likewise stored only in the local Keychain + file cache, never UserDefaults, source files, or logs; browser import reads only the `kimi-auth` cookie (JWT) from `www.kimi.com` and uses it only for the console usage endpoints, storing it in the same Keychain + file cache.
- The GrokPool administrator username and password entered in Settings are stored only in the local Keychain + file cache, never UserDefaults, source files, or logs; the base URL is a plain address preference kept in UserDefaults. The login token is cached in memory only (15-minute validity) and never written to disk.
- LongCat browser access reads the `longcat.chat` session cookies (dropping only `utm_` tracking cookies, keeping `passport_token_key`, `_lxsdk_cuid`, and other identity cookies) only after **Re-import Browser Sign-in** is clicked, and uses them only for the console usage endpoints, writing to the Keychain + file cache. A manually pasted Cookie header is likewise stored only in the local Keychain + file cache.
- `arkcli` keeps ownership of its SSO session; TokenBar only runs `arkcli usage plan --format json` and parses its output.
- The Access Key / Secret Key entered on the Ark settings pane are stored only in the local Keychain + file cache, never in UserDefaults, source code, or logs; the Ark API key is read from the launch environment only.
- Network requests go only to the required Volcengine Ark endpoints, `opencode.ai`, `platform.deepseek.com`, the Z.ai quota endpoint (`open.bigmodel.cn` / `api.z.ai`), the Kimi quota endpoint (`api.kimi.com`), the Kimi console endpoints (`www.kimi.com`), the GrokPool gateway (`grok.axonlume.com`), or the LongCat console (`longcat.chat`).

## Development

```bash
swift test
```

The test suite covers Ark CLI, OpenAPI, OpenCode Go, DeepSeek, Z.ai, Kimi, GrokPool, and LongCat decoding, DeepSeek balance/usage aggregation, browser-session token extraction, time formatting, icon rendering, refresh interaction, and menu-card layout regressions. GitHub Actions runs the same test command for pull requests and pushes to `main`.

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
  GrokPoolProvider.swift GrokPool (grok2api admin gateway) dashboard provider
  LongCatProvider.swift  LongCat (longcat.chat) token-pack quota provider
  LongCatBrowserSession.swift explicit multi-browser session importer
  LongCatCardView.swift  single remaining-token-ring menu card
  ProviderLogo.swift     provider brand icons (doubao/opencode/deepseek/apinebula/zai/kimi/grokpool/longcat)
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
