# Security policy

## Supported versions

Security fixes are applied to the latest `main` branch.

## Reporting a vulnerability

Do not include credentials, tokens, personal usage data, or an exploit proof in a public issue. Use GitHub Private Vulnerability Reporting from this repository's **Security** tab when it is available. If it is unavailable, open a minimal public issue requesting a private reporting channel without disclosing the vulnerability details.

## Credential storage

TokenBar stores credentials in the local macOS Keychain
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no-UI reads) and mirrors
them to a file cache at
`~/Library/Application Support/TokenBar/credentials.json` (directory 0700,
file 0600). The Keychain is the canonical store; the file cache exists so
warm restarts and background refreshes never trigger a Keychain prompt, and
it is protected by the same user-level boundary the Keychain is. This applies
to: OpenCode Go session cookies, DeepSeek API key / platform token,
APINebula (Nebula) browser session and API key, Z.ai API key, Kimi For Coding
API key and `kimi-auth` JWT pair, GrokPool administrator username/password,
LongCat browser session, Aliyun Coding Plan API key, StepFun and SenseNova
console sessions, and the Volcengine Ark Access Key / Secret Key pair.
Credentials are never written to UserDefaults (region/language/UI preferences
only), source files, or logs.

Note that ad-hoc signed builds (no stable signing identity) mint a new
signature on every build, which revokes Full Disk Access and the browser
Keychain grants the user previously approved. `Scripts/package_app.sh`
prefers a stable identity (`TOKENBAR_SIGN_IDENTITY`) for this reason.

## Browser access

Browser cookie reads happen only on the explicit "重新读取浏览器登录" /
"re-read browser sign-in" settings action per provider. Routine refreshes and
startup use the cached credential. DeepSeek's platform session is the
documented exception: when no Keychain/environment platform token exists,
TokenBar silently reads the plaintext `userToken` from Chrome's
`platform.deepseek.com` localStorage (results cached 30 minutes; this reads
localStorage, never the cookie store or the Keychain).

Imports keep only the provider's authentication material — OpenCode keeps
`auth` / `__Host-auth` / `console_session` / `__Host-console_session`, Kimi
the `kimi-auth` JWT plus its refresh token, DeepSeek the `userToken` — and
record the cookie *names* (never values) in support diagnostics written to
`~/Library/Application Support/TokenBar/*.txt`. Imports require a real
sign-in cookie (e.g. LongCat's `passport_token_key`, StepFun's `Oasis-Token`,
APINebula's `session`); a signed-out browser full of analytics cookies fails
the import instead of being cached as a "success". Domain matching is
boundary-strict, so lookalike domains (`not-stepfun.com`) are never
collected.

## Network

Requests go only to the selected providers' own endpoints. Custom relay base
URLs (APINebula, GrokPool) must be HTTPS (plain HTTP is accepted only on
loopback for self-hosted relays), enforced in one shared `SecureEndpoint`
policy. Error responses are truncated to a bounded single-line summary
(`HTTPErrorSummary`) before reaching the UI or stderr; full response bodies
are never logged. The `arkcli` subprocess receives a fixed minimal
environment (PATH, HOME, USER/LOGNAME/SHELL/TMPDIR/LANG/LC_ALL), never other
providers' credentials.

If you believe a provider, subprocess, browser import, Keychain, redirect, or
log path can expose a secret, report it as a security issue.
