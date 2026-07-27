# Changelog

All notable public changes to ArkBar are documented here.

## Unreleased

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
- Added a trailing safety inset to the ArkBar header wordmark so its final glyph is never visually clipped.
- Documented the distinction between host-native source builds, the arm64-only development packaging script, and a maintainer workflow for Universal Binary releases.
- Made Simplified Chinese the default repository README and moved the English version to `README.en.md`.

- Added English and Simplified Chinese public documentation.
- Documented provider limits, privacy boundaries, packaging behavior, and verified subscription-expiry behavior.
- Added security-reporting guidance.

## 0.1.0

- Initial public release: native macOS menu-bar usage monitor for Volcengine Ark Coding and Agent Plans.
