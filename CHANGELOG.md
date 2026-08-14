# Changelog

All notable public changes to TokenBar are documented here.

## Unreleased

- DeepSeek and APINebula now have a per-provider "Menu bar shows" setting (remaining percent vs money balance). In balance mode the status item shows the remaining balance with the correct currency symbol—`¥` for CNY or `$` for USD on DeepSeek (following the wallet currency returned by the API), always `¥` on APINebula—formatted to two decimals, and widens automatically to fit. The Overview summary rows follow the same choice.
- Fixed the Kimi For Coding monthly/shared-pool ring not appearing: the Kimi access token expires in 15 minutes but the app never refreshed it, so the `www.kimi.com` console calls 401'd and the outer ring silently vanished. The app now collects the 90-day refresh token, refreshes expired access tokens via `/api/auth/token/refresh` (rotating the refresh token), retries 401s once, and falls back to a raw-byte LevelDB scan for newer Kimi.app builds whose structured `readEntries` returns empty.
- Fixed multiple admin/Keychain password prompts on startup. `CookieKeychainStore` now skips `SecItemUpdate` when the value is unchanged, and credential resolution uses the still-valid cached access token instead of swapping it on every refresh; combined with the file-cache-first read path, warm restarts no longer touch the Keychain.
- Added a Kimi For Coding tab: membership quota from `api.kimi.com/coding/v1/usages` (weekly quota + 5-hour rate-limit window, mapped to the weekly and session rings), with an API key stored in Keychain + file cache (or the `KIMI_CODE_API_KEY` environment fallback). Importing the `www.kimi.com` browser sign-in additionally reads `GetSubscriptionStats` and maps the **shared Kimi Code + Kimi Work pool** to the monthly ring (the two products bill against one shared pool).
- Added a Z.ai (Zhipu GLM) Coding Plan tab: quota windows from `api/monitor/usage/quota/limit` (5-hour session + weekly rings, plus a monthly MCP time window on some plans), with Global / BigModel CN region selection and an API key stored in Keychain + file cache (or the `Z_AI_API_KEY` environment fallback).
- `CREDIT_LIMIT` windows (the type newer BigModel CN plans return instead of `TOKENS_LIMIT`) are treated as token/credit windows and drive the 5-hour and weekly rings; the plan tier is read from the response's `level` field.
- Added a multi-provider **Overview** tab that lists every visible provider with remaining percent and a teal→blue capsule meter; click a row to open that provider's full card. Toggle it in **Settings → General**.
- Status-item logo glyphs are 16×16pt and percent text uses the system font size, matching CodexBar's menu-bar scale.
- Credentials are mirrored to a local file cache (`~/Library/Application Support/TokenBar/credentials.json`, mode 0600) so warm restarts never need Keychain UI; Keychain remains the canonical store and backfills the file on first silent read.
- Added an APINebula (new-api relay) tab with a balance ring (cumulative spend vs spend + balance), today/monthly cost, token counts, request counts, and a cache-read/uncached/output split aggregated from the console usage log.
- APINebula balance/usage endpoints are console APIs: credentials come from the browser sign-in session (imported explicitly and cached locally) or an optional API key/environment fallback.
- Added a DeepSeek tab with balance, today/monthly cost, token counts, request counts, and a cache hit/miss/output breakdown, mirroring CodexBar's DeepSeek monitoring.
- Added a single balance ring for DeepSeek (this month's spend vs spend + balance) that recalculates automatically after a top-up.
- Added DeepSeek credential entry in Settings (API Key / Platform Token, stored in Keychain + file cache) and silent auto-resolution of the signed-in DeepSeek Platform session from Chrome local storage when no key is configured.
- Added per-provider show/hide toggles in each provider's settings pane; hidden providers leave the switcher and stop background refresh.
- Added CodexBar-style menu-bar display modes: meter bar, bar + percent, percent only, logo only, logo + percent, and logo + bar, with provider brand icons (doubao/opencode/deepseek/apinebula) shipped as resources.
- Provider brand logos now also appear in the settings sidebar and menu switcher buttons.
- Browser-session import (OpenCode / APINebula) is an explicit settings action only; background/startup refreshes never decrypt browser cookie stores or prompt for Keychain passwords.
- Added an OpenCode Go tab backed by authoritative subscription-page data, with explicit browser-session import or a manual Keychain-stored Cookie.
- Isolated Ark and OpenCode refresh, error, stale-data, and last-updated state so one provider cannot overwrite the other.
- Prevented background and ordinary refreshes from repeatedly reading browser cookie stores or triggering recurring Keychain password prompts.
- Kept one persistent menu attached to the status item, eliminating the first-click miss and allowing tab switches and refresh state to update in place.
- Kept the menu-bar percentage synchronized with the selected provider's Session value while using a fixed-width anchor to avoid horizontal movement.
- Reworked the settings window into compact General, Ark, OpenCode Go, and Diagnostics panes.
- Refined the remaining-quota rings with distinct color families, a wider neutral track, contained progress strokes, and a clean full-ring state at 100%.
- Added a persisted switch for refreshing when the menu-bar item opens; the default remains interval-only refresh.
- Coalesced overlapping refresh triggers and scheduled the timer in common RunLoop modes to keep refreshes stable while the menu is open.
- Fixed the status-item hover selector crash, kept Refresh inside the open menu, and made the primary ring/centre consistently represent remaining quota.
- Changed the menu-bar capsule to show the current Session / 5-hour remaining percentage rather than the lowest remaining period.
- Refresh now records its local completion time in the visible “Updated at” label and remains available whether or not refresh-on-open is enabled.
- Added a persistent, live refresh row with in-place refreshing, success, relative-time, and failure states.
- Fixed the live refresh row so it changes to “Refreshing…” immediately while the menu is open, then returns to its success or error state without requiring the menu to close.
- Replaced the unstable rotating refresh glyph with a fixed native loading indicator inside the refresh icon slot.
- Added a trailing safety inset to the TokenBar header wordmark so its final glyph is never visually clipped.
- Documented the distinction between host-native source builds, the arm64-only development packaging script, and a maintainer workflow for Universal Binary releases.
- Made Simplified Chinese the default repository README and moved the English version to `README.en.md`.

- Added English and Simplified Chinese public documentation.
- Documented provider limits, privacy boundaries, packaging behavior, and verified subscription-expiry behavior.
- Added security-reporting guidance.

## 0.1.0

- Initial public release: native macOS menu-bar usage monitor for Volcengine Ark Coding and Agent Plans.
