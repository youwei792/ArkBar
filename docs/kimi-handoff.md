# Kimi For Coding 交接文档

> 状态日期:2026-08-15。本文记录 Kimi 标签页的现状、认证体系、已发现的问题与后续方向,给下一个接手的开发者/自己续接时参考。

## 1. 现状概览

ArkBar(菜单栏应用,Target `TokenBar`)已上线 **Kimi For Coding** 标签页,目标是展示 Kimi Coding Plan 的额度环:

- **session 环**(最内圈):Code 5 小时限流窗口。
- **weekly 环**(中间圈):Code 每周配额(`api.kimi.com/coding/v1/usages` 的 `usage`)。
- **monthly 环**(外圈):**Kimi Code + Kimi Work 共享总池**(来自 `www.kimi.com` 控制台 `GetSubscriptionStats` 的 `subscriptionBalance.amountUsedRatio`)。

数据源(移植自 CodexBar 的 Kimi provider,见 `Sources/TokenBar/KimiProvider.swift`、`Sources/TokenBar/KimiBrowserSession.swift`):

| 凭据 | 认证方式 | 能拿到什么 |
| --- | --- | --- |
| API Key(`KIMI_CODE_API_KEY`,设置页存 Keychain `kimi-key`) | `GET api.kimi.com/coding/v1/usages`,Bearer | Code 每周配额 + 5 小时限流(两环) |
| 浏览器 `kimi-auth`(导入自 `www.kimi.com`,存 Keychain `kimi-auth`) | `POST www.kimi.com/.../GetUsages` + `GetSubscriptionStats` | Code 用量 + **共享总池 + Code 7 天**(monthly 环) |

当前实现:API Key 存在时走 Code API 主路径;若同时有浏览器会话,则尝试用 web 路径补充共享池环(`try?` 失败回退两环)。无 API Key 时纯 web 路径。

## 2. ✅ 已修复:共享总池环拿不到(月度环不显示)

**现象**:导入浏览器会话后刷新,monthly 环始终不出现;刷新多次仍是两环。

**根因(2026-08-15 实机定位)**:
1. Kimi 的 access_token **有效期仅 15 分钟**(`exp - iat = 900s`),过期后调用 `GetSubscriptionStats` / `GetUsages` 均 401。
2. 旧代码没有 token 刷新逻辑——只从 Kimi.app Local Storage 或浏览器读取一次 access_token,过期后无法续期,monthly 环静默消失。
3. SweetCookieKit 的 `ChromiumLocalStorageReader.readEntries(for:)` 对 Kimi.app 3.1.8(Electron 41)的 LevelDB key 格式(带 `0x01 0x23` 前缀)解析失败,返回空数组。需要回退到 `readTokenCandidates(in:)` 直接扫描原始字节。
4. 交接文档之前的判断(`iss=user-center` 的 cookie 401)不准确——实际上 `iss=user-center` 的 access token **可以**正常调用控制台接口,问题纯粹是 token 过期。

**修复(2026-08-15)**:
1. **Token 刷新流程**:采集 localStorage 里的 `refresh_token`(90 天有效期),access token 过期/即将过期时调用 `GET https://www.kimi.com/api/auth/token/refresh`(Bearer refresh token)获取新 token。刷新返回的 access token 有效期 30 天,且服务端会轮转 refresh token。
2. **凭据模型**:`KimiBrowserSession.Credential` 同时持有 access token 和 refresh token;refresh token 单独存 Keychain `kimi-refresh`。
3. **LevelDB 回退**:`desktopTokens()` 和 `collectFromBrowser()` 先尝试结构化读取,失败后用 `readTokenCandidates` 扫描 JWT。
4. **401 自动重试**:web 接口返回 401 时,用 refresh token 刷新一次后重试。
5. 移除了 `preferredAuthToken` 中对 `iss=user-center` 的 -3 惩罚(实测两种 issuer 均可认证)。

**验证**:
- Kimi.app Local Storage 中的 access token + refresh token 成功读取。
- `GET /api/auth/token/refresh` 返回 HTTP 200,新 access token 可调用 `GetSubscriptionStats`,拿到 `amountUsedRatio=0.2736`(27% 已用)。
- 清空凭据缓存后冷启动,app 自动从 Kimi.app 读取 token、持久化 refresh token,`webSessionInvalid` 标志保持清除。

## 2b. ✅ 已修复:启动时弹三次管理员/钥匙串密码

**现象**:修复月环后每次启动会弹 2-3 次"想要使用你在钥匙串中存储的机密信息"管理员密码框。

**根因**:`CookieKeychainStore.store(cookie:provider:)` 每次刷新都无条件调用 `SecItemUpdate`。ad-hoc 签名的 app 对自有 Keychain 项的 ACL 不被信任,每次写都会触发授权对话框。而 token 刷新后即使值没变(缓存命中、Kimi.app 短 token 与缓存相同)也会写,导致一次启动内多次弹窗。

**修复(2026-08-15)**:
1. `CookieKeychainStore.store` 在写 Keychain 前比对进程内缓存,值未变化时跳过 `SecItemUpdate`(仍照常写文件缓存并更新进程缓存),消除重复写入。
2. `KimiBrowserSession.resolveCredential` 改为**缓存优先**:缓存里的 access token 仍有效(距过期还有余量)就直接用,不再每次都用 Kimi.app 的短寿命 token 顶替,避免无谓的 token 轮换和随之而来的 Keychain 写。
3. 读取路径(`kimi-auth` / `kimi-refresh`)优先走 `~/Library/Application Support/TokenBar/credentials.json` 文件缓存(权限 0600),暖启动完全不碰 Keychain。

**验证**:release 包冷启动无任何钥匙串弹窗,凭据(access token + 90 天 refresh token)正常读取。

## 3. 代码结构

- `Sources/TokenBar/KimiProvider.swift`:provider 主体。`fetch` 解析 API Key / authToken → Code API 或 web 路径 → `makeWindows(from:)` 映射环。`parse(data:)` 供测试。`webSessionInvalid` 静态标志。
- `Sources/TokenBar/KimiBrowserSession.swift`:从浏览器读 `www.kimi.com` / `kimi.com` 的 `kimi-auth` cookie,显式导入、Keychain + 文件缓存(`kimi-auth` 账户),仿 `NebulaBrowserSession`。
- `Sources/TokenBar/Settings.swift`:`kimiAPIKey`(Keychain `kimi-key`)、`kimiAuthToken`(Keychain `kimi-auth`)镜像 + `showKimi`。
- `Sources/TokenBar/UsageStore.swift`:`kimiStatus`/`kimiLastUpdatedAt`/`kimiIsRefreshing` 三件套、`refreshKimi`/`runKimiProvider`/`finishKimiRefresh`、`reimportKimiBrowserSession()`。
- `Sources/TokenBar/StatusItemController.swift`:三个 sink + visibility `$showKimi`。
- `Sources/TokenBar/PreferencesWindow.swift`:`KimiPreferencesPane`(API Key + 导入按钮 + 会话来源 + 失效警告)。
- `Sources/TokenBar/ProviderTab.swift` / `ProviderLogo.swift` / `MenuBuilder.swift`:`.kimi` 分支 + `ProviderIcon-kimi.svg`。
- `Sources/TokenBar/Localization.swift`:`tabKimi`/`settingsKimi`/`refreshKimi`/`openKimiConsole`/`kimiCredentialsHint`/`kimiBrowserHint`/`kimiWebSessionInvalidHint`/`reimportKimiBrowserSession`/错误文案。

## 4. 认证优先级与数据模型

**凭据优先级**(Provider `fetch`):设置页/Keychain > 环境变量。
- API Key 环境变量:`KIMI_CODE_API_KEY`
- web token 环境变量:`KIMI_AUTH_TOKEN`

**web 请求头**(`webRequest`,对齐 CodexBar):`POST` + `Content-Type: application/json` + `Authorization: Bearer <token>` + `Cookie: kimi-auth=<token>` + `Origin/Referer: www.kimi.com` + UA + `x-msh-platform: web` + `x-msh-device-id`/`x-msh-session-id`/`x-traffic-id`(从 JWT payload 的 `device_id`/`ssid`/`sub` 提取)。

**窗口映射**(`KimiProvider.makeWindows(from:)`):
- 5 小时限流 → `"5-hour"`(session 环)
- Code 每周配额(`usage`)→ `"Weekly"`(weekly 环)——**始终用 Code 自己配额**,不用 `ratelimitCode7d` 顶替(三环模型无第 4 槽,且周配额语义更贴用户预期)
- 共享池(`subscriptionBalance`,需 `feature==FEATURE_OMNI` 或空 + `type==SUBSCRIPTION` 或空 + `amountUsedRatio` 有限)→ `"Monthly"`(monthly 环),用 `ratioWindow` 直接按比例避免 Int 截断

**解码类型**:`KimiCodeAPIUsageResponse`(`usage` + `limits[]`)、`KimiUsageDetail`(容错 string/number)、`KimiRateLimit`(`window.duration` + `detail`)、`KimiSubscriptionStatsResponse`(`subscriptionBalance` + `ratelimitCode7d`)、`KimiSubscriptionBalance`(`amountUsedRatio` = 全池已用比,**`kimiCodeUsedRatio`** = Code 单独已用比)。

## 5. 测试

`Tests/TokenBarTests/TokenBarTests.swift`:
- `KimiProvider decode`:Code API payload 解析、数字字段容错、仅 weekly 响应。
- `KimiProvider web session & shared pool`:真实 `GetSubscriptionStats` fixture 解码、共享池→monthly / Code weekly→weekly / 5h→session 映射、无共享池省略 monthly、Code-only 回退。
- `KimiBrowserSessionTokenTests`:`bestRefreshPicksLongestLived`、`needsRefreshDetection`、`refreshParsesResponse`、`refreshThrowsOn401`,覆盖 refresh token 选择、过期判定、刷新响应解析与 401 抛错。
- 余额显示:`balanceDisplayWidensStatusItem`、`moneyFormattingUsesCorrectSymbol`,覆盖余额模式状态栏加宽与货币符号格式化(DeepSeek `¥`/`$`、Nebula `¥`)。

80 个测试全绿。

## 6. 提交 / 发布

- 合并方式:分支 → PR(youwei792)→ CI `test` 通过 → merge。**不能直接推 main**(有分支保护)。
- 推送凭据:本机 git 凭据缓存的账号是 `alvincna`(无权),需用 `gh auth token --user youwei792` 做单次 URL 内嵌推送。**提交身份**是 `WwwSideQuest <229644306+youwei792@users.noreply.github.com>`(youwei792)。
- 打包:`bash Scripts/package_app.sh`(arm64,ad-hoc 签名)→ 安装到 `/Applications/TokenBar.app` → `pkill -f "/Applications/TokenBar.app/Contents/MacOS/TokenBar"` → `open`。
- 敏感信息:提交前用 `git diff HEAD | grep -Ei "sk-|Bearer [A-Za-z0-9]{24,}|api[_-]?key=..."` 扫描,确认无真实密钥。

## 7. 后续方向(若需要)

1. **确认 Coding Plan 控制台会话可导入**后,可移除 `try?` 静默回退,把「无共享池」做成显式状态。
2. 若用户有 Kimi Code CLI(`kimi` 命令),可仿 CodexBar `KimiCLICredentialFetchStrategy` 复用 `~/.kimi-code/credentials/kimi-code.json` 的 access token(需 `device_id` 等身份 header)。
3. 未来若 Kimi 控制台要求额外 cookie(不止 `kimi-auth`),`KimiBrowserSession` 需扩展为导入完整 cookie header(仿 Nebula 的 `requestCookieHeader`)。

## 8. 参考

- CodexBar 上游:`Sources/CodexBarCore/Providers/Kimi/`(`KimiUsageFetcher`/`KimiModels`/`KimiCookieImporter`/`KimiSettingsReader`)与 `docs/kimi.md`。
- CodexBar Kimi API 文档:`GET api.kimi.com/coding/v1/usages` 响应示例在 `docs/kimi.md`。
