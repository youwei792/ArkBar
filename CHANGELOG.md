# Changelog

All notable public changes to ArkBar are documented here.

## Unreleased

- Added a persisted switch for refreshing when the menu-bar item opens; the default remains interval-only refresh.
- Coalesced overlapping refresh triggers and scheduled the timer in common RunLoop modes to keep refreshes stable while the menu is open.
- Made Simplified Chinese the default repository README and moved the English version to `README.en.md`.

- Added English and Simplified Chinese public documentation.
- Documented provider limits, privacy boundaries, packaging behavior, and verified subscription-expiry behavior.
- Added contribution and security-reporting guidance.

## 0.1.0

- Initial public release: native macOS menu-bar usage monitor for Volcengine Ark Coding and Agent Plans.
