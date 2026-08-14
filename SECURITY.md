# Security policy

## Supported versions

Security fixes are applied to the latest `main` branch.

## Reporting a vulnerability

Do not include credentials, tokens, personal usage data, or an exploit proof in a public issue. Use GitHub Private Vulnerability Reporting from this repository's **Security** tab when it is available. If it is unavailable, open a minimal public issue requesting a private reporting channel without disclosing the vulnerability details.

TokenBar does not persist Volcengine AK/SK or Ark API keys. When OpenCode Go
integration is enabled, TokenBar stores only the filtered `auth` / `__Host-auth`
cookie in the local macOS Keychain. Browser import is user initiated; routine
refreshes reuse the cached credential and must not trigger a new browser-cookie
read. Credentials must never be written to UserDefaults, source files, or logs.

DeepSeek, Z.ai (Zhipu GLM), and Kimi For Coding API keys entered in Settings
follow the same policy as OpenCode credentials: stored in the local Keychain and
mirrored to the app-support credential file cache, never written to UserDefaults,
source files, or logs.

Kimi browser import reads only the `kimi-auth` cookie (JWT) from `www.kimi.com`
and stores it in the same Keychain + file cache; it is used only to call the
membership console usage endpoints.

If you believe a provider, subprocess, browser import, Keychain, redirect, or
log path can expose a secret, report it as a security issue.
