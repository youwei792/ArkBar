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

## 2. ⚠️ 已知问题:共享总池环拿不到(核心遗留问题)

**现象**:导入浏览器会话后刷新,monthly 环始终不出现;刷新多次仍是两环。

**根因(已实机验证)**:
1. 缓存/导入的 `kimi-auth` token 调用 `GetSubscriptionStats` / `GetUsages` 均返回 `401 {"code":"unauthenticated", ... "reason":"REASON_INVALID_AUTH_TOKEN"}`。
2. 该 token 是 Kimi 主站/Kimi Work 的登录态(`app_id=kimi`, `iss=user-center`, `region=cn`, `membership.level=10`),**不是 Kimi For Coding(Coding Plan)控制台专用会话**。
3. 用户本机没有 Kimi Code CLI 凭据(`~/.kimi-code/` 不存在),CodexBar 的 CLI 认证路径不可用。
4. **结论**:Kimi Work 桌面端登录态(Kimi.app,`com.moonshot.kimichat`)认证不了 Coding Plan 控制台接口;要拿到共享池,必须在**浏览器**登录 https://www.kimi.com/code 的 **Coding Plan 控制台**,让该控制台产生自己的会话 token 后重新导入。

**现有缓解**:2026-08-15 新增 `KimiProvider.webSessionInvalid` 标志(存 UserDefaults `tokenbar.kimiWebSessionInvalid`),web 401/403 时置位、成功时清除;设置页「Kimi For Coding」显示橙色警告「浏览器会话无效或已过期……请在 www.kimi.com/code 登录后重新读取浏览器登录」。

**遗留待验证**:浏览器里登录 kimi.com/code 控制台后重新导入,确认共享池环是否出现。如果控制台登录也是 `user-center` 体系、接口仍 401,则 CodexBar 的 Kimi web 路径本身可能也需要额外条件(如特定的 Coding Plan 专属 cookie 或请求头),需进一步抓包确认。

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

71 个测试全绿。

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
