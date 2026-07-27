# ArkBar 🎚️

Tiny macOS 14+ menu-bar app that keeps your **Volcengine Ark Coding / Agent Plan usage** visible — inspired by [CodexBar](https://github.com/steipete/CodexBar), focused on the Volcengine Ark plans.

The menu-bar icon is a capsule that fills according to the **tightest** usage window across all your plans (session / 5-hour / weekly / monthly). Click it for a per-plan breakdown with reset countdowns.

## Install & run

```bash
swift build
.build/debug/ArkBar
```

No Dock icon — it lives entirely in the menu bar. Quit it from the dropdown menu.

## Authentication (three paths, same as CodexBar's Doubao provider)

In **Auto** mode, ArkBar tries configured API credentials first, then falls back
to `arkcli`; the first source that succeeds wins. This keeps a GUI launch from
silently showing a different SSO account when explicit credentials are present.

| Mode | How | When to use |
|---|---|---|
| **AK/SK** | `VOLCENGINE_ACCESS_KEY_ID` + `VOLCENGINE_SECRET_ACCESS_KEY`, Volcengine V4 signed `GetCodingPlanUsage` OpenAPI | CI / headless / when SSO token expires. Coding Plan only. |
| **Ark API Key** | `ARK_API_KEY` probes `/api/coding/v3/chat/completions` and reads `x-ratelimit-*` headers | Fallback after AK/SK. Single request-limit window only. Set `ARK_MODEL_ID` to use a model/endpoint available to your key. |
| **arkcli (SSO)** | `arkcli usage plan --format json` reads your Volc SSO session | Fallback; gives all plans (personal + team Coding/Agent). |

### Set up arkcli (recommended)

```bash
brew install arkcli          # or your install path
arkcli auth login volc-sso   # one-time sign-in
```

If you see "arkcli is not signed in" in the menu, the SSO token expired — just run `arkcli auth login volc-sso` again. The "Open arkcli auth login" menu item does this for you.

### Use AK/SK instead

```bash
export VOLCENGINE_ACCESS_KEY_ID=AK...
export VOLCENGINE_SECRET_ACCESS_KEY=SK...
.build/debug/ArkBar
```

### Use an Ark API key

```bash
export ARK_API_KEY=...
.build/debug/ArkBar
```

## What you see

**Icon** — a capsule progress bar reflecting the *remaining* percent of your tightest window. Template-tinted, so it adapts to light/dark mode automatically. Dimmed when data is stale or a fetch failed.

**Dropdown** — grouped by plan:

```
ArkBar  ·  arkcli
Coding Plan  -  personal
    Session ███████░░░  73%   -/-    resets in 2h 14m
    Weekly  ███░░░░░░░  31%   -/-    resets in 3d 4h
    Monthly █░░░░░░░░░  12%   -/-    resets in 18d
Agent Plan  -  medium
    5-hour  ██████░░░░  58%   250/1000   resets in 1h
    ...
─────────────────────
Last updated 14:32
Refresh Now
Open arkcli auth login
Open Ark Console
─────────────────────
Quit ArkBar
```

## Refresh

- Default every 5 minutes. Change it in `Settings.refreshInterval` (1/2/5/15/30 min).
- Opening the menu forces a refresh if the last fetch was >1 minute ago.
- `Refresh Now` always refreshes.
- Changing the interval takes effect immediately. If a later refresh fails, the
  last successful snapshot remains visible and is explicitly marked as stale.

## Language and accessibility

- Choose **System Default**, **简体中文**, or **English** in Settings. The setting
  persists, and the current Settings window is rebuilt immediately after a
  language change.
- The ring gauge uses a short 0.26 s entrance transition. It is disabled when
  macOS **Reduce Motion** is enabled.

## Adding new plans or subscriptions

ArkBar is provider-driven, exactly like CodexBar (which also extends via code, not runtime plugins — see their [provider authoring guide](https://github.com/steipete/CodexBar/blob/main/docs/provider.md)).

To add a new usage source:

1. Conform a type to `UsageProvider`:
   ```swift
   final class MyProvider: UsageProvider {
       let displayName = "My Plan"
       func isAvailable(environment: [String: String]) -> Bool { true }
       func fetch(environment: [String: String]) async throws -> ProviderSnapshot { ... }
   }
   ```
2. Register it in `UsageStore.rebuildProviders()` so it joins the priority list.

That's it — the icon aggregation and menu rendering pick it up automatically. `ProviderSnapshot` carries `[PlanSnapshot]`, each with `[UsageWindow]`; windows carry `usedPercent` / `used` / `total` / `resetsAt`, so most quota shapes map onto it directly.

## Architecture

```
UsageProvider (protocol)
├── ArkCLIProvider     — arkcli SSO, parses viewer + items[].periods[]
├── VolcAPIProvider    — AK/SK Volcengine V4 signed GetCodingPlanUsage
└── ArkAPIKeyProvider  — ARK_API_KEY probe of x-ratelimit headers

UsageStore             — provider priority + refresh timer + aggregated state
StatusItemController   — NSStatusItem, icon, click → menu
IconRenderer           — 18×18pt 2× template capsule (ported from CodexBar)
MenuBuilder            — NSMenu with per-plan sections, block progress bars, countdowns
VolcSigner             — Volcengine V4 HMAC-SHA256 (ported from CodexBar DoubaoVolcengineSigner)
```

## Data source contract

`arkcli usage plan --format json` returns `{ viewer, items[] }` where each item has `product` (`coding-plan` / `agent-plan` / `coding-plan-team` / `agent-plan-team`), `subscribed`, and `periods[]`. Each period has `label` (`session`/`5h`/`weekly`/`monthly`), `percent` (**used** percent 0–100), optional `used`/`total` (AgentPlan only), and `reset_at` (RFC3339 Beijing time). `updated_at` may be epoch seconds or milliseconds — detected by magnitude (≥1e11 → ms).

## Privacy

- No Keychain reads, no browser cookies, no disk scanning.
- arkcli owns the SSO session; ArkBar only reads its stdout.
- AK/SK and API keys come from environment variables you set.
- All network calls go directly to Volcengine endpoints — nothing else.

## Testing

```bash
swift test
```

Covers arkcli JSON decoding (multi-plan, auth=none, subscribed=false, ms/s timestamp detection), Volcengine OpenAPI decoding, menu progress-bar/countdown formatting, and icon rendering.

## Requirements

- macOS 14+ (Sonoma)
- Swift 6.0 toolchain
- `arkcli` (recommended) **or** Volcengine AK/SK **or** an Ark API key
