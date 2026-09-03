# ArkBar 全面审计报告

- **审计日期**：2026-09-04（Asia/Shanghai）
- **审计对象**：`youwei792/ArkBar`，提交 `68e4a1addc21dcc54da633fbf46da7193d78e38d`
- **范围**：代码质量、架构、功能正确性、安全性、凭据与浏览器会话、网络请求、依赖、测试、CI、构建/打包/发布和文档可维护性。
- **方法**：源码/脚本/配置静态审阅、行号级追踪、测试结构审阅、依赖和 CI 配置审阅。没有修改业务代码。

## 1. 结论摘要

ArkBar 的基础设计是清晰的：Provider 已按数据源拆分，UI 大部分位于 `@MainActor`，HTTP 层和 Provider 解码逻辑可注入 mock，Keychain 使用了 `ThisDeviceOnly`，OpenCode 请求也实现了专门的重定向保护。当前提交包含约 **100 个 Swift Testing 测试**，并且仓库托管 CI 的最新已查询 run 为 success。

但它目前还不适合作为“安全敏感凭据 + 正式分发”的无条件发布版本。主要原因不是单个 DTO 错误，而是凭据边界、网络边界、生命周期和发布脚本的 fail-open 行为：

1. Nebula/GrokPool 的自定义地址会接收 Cookie、API key 或管理员凭据，但地址没有强制 HTTPS、主机或端口策略。
2. `arkcli` 子进程继承完整 GUI 进程环境，可能拿到其他 Provider 的秘密；诊断路径也没有显式隔离环境。
3. 通用 `URLSession` 没有统一的跨 origin 重定向策略；OpenCode 的 guard 只保护了它自己的 session，而且只比较 host，不比较 port。
4. Keychain 写入/删除失败没有可靠地传递给 UI；明文文件缓存是实际的首选读取源，且文件缓存没有并发协调。
5. 刷新只用布尔值防重入，没有任务取消或 generation token，配置变更和慢请求之间可能出现旧结果覆盖新状态。
6. LongCat 的 automatic/manual 选择器尚未接入 Provider；Kimi/Nebula 的浏览器会话还有跨 profile 或跨 token 误配风险。
7. 打包脚本会吞掉 codesign/verify 失败，并在之后无条件移除 quarantine；资源 bundle 查找还使用了 macOS BSD `find` 不保证支持的 `-maxdepth`。

**建议发布结论**：先修复 P1（高风险）项，再进行真实 macOS、浏览器、Keychain、重定向和打包验证；P2 项应在下一次功能发布前完成。当前没有确认到一个“无需本地权限即可远程利用”的漏洞，但多个问题会在用户误配置、恶意/被攻陷上游、同用户恶意进程或异常服务响应下放大凭据暴露和错误数据风险。

## 2. 风险等级

- **P0 / Blocker**：应立即停止发布；本次未确认 P0。
- **P1 / High**：发布前修复或加入明确的安全门禁。
- **P2 / Medium**：会影响凭据边界、数据正确性、可靠性或可维护性，应尽快修复。
- **P3 / Low**：技术债、文档或测试质量问题，不一定阻塞当前本地使用。

“待验证”表示静态代码已经形成风险，但本环境没有 macOS 运行时或真实服务，不能把运行时行为当作已证实事实。

## 3. 风险矩阵

| ID | 等级 | 问题与影响 | 证据 | 修复建议 |
|---|---|---|---|---|
| F-01 | **P1** | **自定义 Base URL 可把凭据发往任意地址。** Nebula 会发送浏览器 Cookie/`New-Api-User` 或 API key，GrokPool 会发送管理员账号密码和 Bearer token；当前只做字符串拼接和 `/v1`/斜杠处理，不限制 HTTPS、host、port 或 origin。 | `Sources/TokenBar/NebulaProvider.swift:255-270,368-382`；`GrokPoolProvider.swift:171-198,233-258,293-307`；设置值来自 `Settings.swift:243-265`。 | 解析为 `URLComponents` 后强制 `https`；默认地址使用 host/port allowlist。若确实支持自托管 relay，应在 UI 明示“凭据将发送到此地址”，对修改后的 origin 要求二次确认，并在每次请求前验证 origin。 |
| F-02 | **P2** | **环境变量 Base URL fallback 被默认设置值遮蔽，且 `/v1/` 归一化有缺陷。** `AppSettings` 初始化时把默认 URL 写入内存，Provider 随后优先使用这个非空值，通常不会再走 `NEBULA_BASE_URL`/`GROKPOOL_BASE_URL`。输入 `https://host/v1/` 时先去斜杠后不会再次去掉 `/v1`，最终可能请求 `.../v1/api/...`。输入框还是直接绑定设置，每次输入字符都会写 UserDefaults 并触发刷新。 | `Settings.swift:496-500`；`NebulaProvider.swift:141-145,375-382`；`GrokPoolProvider.swift:129-139,300-307`；`PreferencesWindow.swift:598-603,766-772`；刷新订阅 `UsageStore.swift:172-176,190-195`。 | 用可选 override 表示“未设置”，按 override > 环境变量 > 默认值解析；统一 URLComponents 归一化并测试 `/v1/`。URL 用 draft state + Save/Apply 或 debounce，不要在每个 keystroke 上发请求。 |
| F-03 | **P1（待运行验证）** | **携带凭据的通用 HTTP 请求没有统一重定向保护。** `HTTPClientTransport` 使用 `URLSession.shared.data(for:)`，未设置 delegate 来拒绝跨 host/origin redirect。Foundation 在某些跨 host 场景可能重写敏感 header，但当前代码没有显式保证，不能把实现行为交给默认值。OpenCode 的 guard 只作用于自己的 session，且只比较 host 和目标 scheme，允许同 host 改 port。 | `Sources/TokenBar/HTTPTransport.swift:20-29`；OpenCode 专用 session/guard `OpenCodeGoProvider.swift:21-36,115-134`；多个 Provider 通过 `defaultHTTPTransport()` 发送 `Authorization`/`Cookie`。 | 使用统一的 ephemeral `URLSession` 和 delegate；比较完整 origin（scheme、host、effective port），必要时禁止所有 redirect 后由业务层显式跟随；响应还应验证最终 URL。为每个携带 Cookie/Authorization 的请求写 redirect 测试。 |
| F-04 | **P1** | **`arkcli` 子进程继承完整进程环境。** 传给 runner 的 environment 来自 `ProcessInfo.processInfo.environment`，runner 仅修改 PATH 后整体赋给 `Process.environment`；因此 `DEEPSEEK_*`、`Z_AI_API_KEY`、`KIMI_*`、GrokPool 密码等可能暴露给 CLI 及其子进程。设置页的 `--version` 诊断没有显式 environment，也按 `Process` 默认行为继承父环境。CLI 路径还可以来自用户可控 PATH/`ARKCLI_PATH`。 | `ArkCLIFetcher.swift:143-176`；调用环境 `UsageStore.swift:446-449,468-470`；诊断 `PreferencesWindow.swift:1176-1202`。 | 为 CLI 构造最小 allowlist（必要的 PATH、HOME、LANG、TMPDIR 等），明确是否必须给 HOME；不把 Provider secret 传入。诊断也用相同 allowlist，固定并验证可执行文件路径，必要时检查签名/文件 owner。 |
| F-05 | **P2** | **Keychain 失败不可被调用方可靠感知，且文件缓存事实上是首选凭据源。** `store` 忽略 `store(keychainOnly:)` 的结果，写文件/进程缓存后无条件返回 true；`clear` 也无条件返回 true，即使文件写失败或 Keychain 删除失败。读取顺序是文件 > 进程缓存 > Keychain，因此旧文件可遮蔽 Keychain 的更新/删除。相同值的进程缓存命中还会跳过 Keychain 修复写入。 | `CookieKeychainStore.swift:26-56,59-85,88-97`；Keychain 状态实际在 `:101-134`；设置层据此宣称保存成功 `Settings.swift:290-340,394-412`。 | 返回逐层结果并区分“Keychain 成功”“仅文件 fallback”“失败”；UI 显示真实持久化状态。定义清晰的权威源和失效策略，不让旧文件无限期遮蔽 Keychain；删除必须验证三个层次。 |
| F-06 | **P2** | **凭据文件缓存没有进程间/跨线程协调，也没有完整路径安全检查。** `loadAll`→修改→写回是非原子事务；不同 Provider 同时写会丢失其他键。所有写入共用固定 `.credentials.json.tmp`，并发会互相覆盖。目录只在不存在时设置 0700，不校验已有目录的 owner/mode/symlink；文件本身也不做最终权限/符号链接检查。0600 只能防其他用户，不能替代 Keychain 对同一用户进程的隔离。 | `CredentialFileCache.swift:14-25,28-51,59-76`；`CookieKeychainStore.swift:19-20` 的锁只保护进程字典，不保护文件事务。 | 将整个文件存取放进 actor/进程内锁，使用唯一临时文件 + 原子 rename；校验目录和文件 owner、权限及 symlink，失败时不报告成功。若安全模型允许，考虑只保存受保护的短期缓存或改为 Keychain/加密数据库。 |
| F-07 | **P1（正确性）** | **刷新生命周期只有 bool 防重入，没有 Task 句柄、取消或 generation ID。** 慢请求期间修改凭据、source mode、URL 或再次触发刷新时，新刷新会因 `isRefreshing` 被丢弃；旧请求完成后仍可写入新的 status/snapshot/lastUpdatedAt。应用也无法取消浏览器扫描、分页或网络任务。 | `UsageStore.swift:439-450,453-471,546-564,595-605,679-731,763-787`；设置变更直接 refresh `:136-204`；定时器 `:844-852`。 | 每个 Provider 使用 `RefreshTask { id, snapshot }`；新配置递增 generation 并取消旧 task，完成时只接受当前 generation。把取消当作正常状态，不写成错误；网络、LevelDB、CLI 和分页都传播 cancellation。 |
| F-08 | **P2** | **LongCat 的 automatic/manual 选择器没有接入实际认证解析。** UI 显示并持久化 `longcatCookieSource`，但 Provider 固定按 manual → cached browser → environment；切到 automatic 后仍可能使用旧手工 Cookie。手工值未通过 `requestCookieHeader` 规范化，`Cookie:` 前缀、空项或复制来的完整 header 可能原样作为 Cookie 值发送。 | UI `PreferencesWindow.swift:847-875`；设置 `Settings.swift:273-280,404-412`；解析 `LongCatProvider.swift:196-213`；规范化只在浏览器导入路径 `LongCatBrowserSession.swift:154-173`。 | 按 source enum 构造互斥解析分支；automatic 只允许缓存浏览器/环境，manual 只允许手工值。手工输入统一去除 `Cookie:`/`Set-Cookie:` 前缀、解析合法 name/value、丢弃属性和空项，并加入 selector/原始 header 测试。 |
| F-09 | **P2** | **Kimi 浏览器 token 选择边界过宽，且旧 refresh token 可能与新账户配对。** Kimi.app 结构化读取失败后会对整个 LevelDB 做 JWT 扫描；浏览器 fallback 同样可能失去 origin/key 语义，`preferredAuthToken` 主要按 JWT claims/分数选 token，没有严格绑定 audience、issuer、账户或来源。导入新 access token 但没有 refresh token 时，`cache` 不清除之前的 `kimi-refresh`；之后可能把旧账户 refresh token 用于新账户 access token。 | `KimiBrowserSession.swift:186-210,315-355,436-469,494-505`；更新路径 `:266-283`；Provider 使用/刷新 `KimiProvider.swift:243-335`。 | 保留 origin、storage key、profile 和账户标识，严格校验 `aud`/`iss`/account 关联；raw scan 只能作为明确的用户确认 fallback。以 access+refresh+source 为事务替换，缺少 refresh 时清除旧值；刷新响应也要原子更新 pair。 |
| F-10 | **P2** | **Nebula Cookie 与 user ID 可能来自不同浏览器 profile。** 导入 Cookie 时已经选定了 browser/source，但 `resolveUserId` 又遍历该浏览器所有 profile，返回第一个发现的 localStorage ID，没有和 Cookie 所属 `source.label`/profile 绑定。最终 `New-Api-User` 可能与 session 不匹配，造成错误账户、失败请求或将身份元数据与另一会话配对。 | `NebulaBrowserSession.swift:95-114`；profile 遍历和返回首个 ID `:130-161`；header 使用 `:333-343`。 | 让 Cookie source 携带 profile path/ID，localStorage 只在同一 profile 查询；无法建立绑定时不要发送 `New-Api-User`，并让用户选择 profile/重新导入。 |
| F-11 | **P2** | **部分成功和认证来源的语义不一致。** Kimi 的 web-only snapshot 固定写 `authMethod: "apikey"`，设置页会错误显示 API key；API key 路径的 web enrichment 使用 `try?`，共享池失败时 monthly ring 静默消失。Nebula 日志请求失败后仍返回余额成功 snapshot，虽然 `usageAvailable` 为 false，但 Provider-level error/source 没有明确呈现，用户容易把缺失数据当成零。 | `KimiProvider.swift:283-292,383-402,430-441`；Nebula `:185-242`；模型字段 `UsageModels.swift:52-54,81-82`。 | `makeProviderSnapshot` 接收真实 auth source；将 optional enrichment 的失败原因放进可见的 soft warning/diagnostic；区分“真实 0”和“未获取”，禁止用 0 填充未知计数。 |
| F-12 | **P2** | **错误日志和 UI 可能包含未经裁剪的服务端响应正文。** Kimi 将 HTTP body 拼进 `UsageError.apiError`，Z.ai 也将 body 拼进错误；`UsageStore` 随后同时写 stderr 和状态文本。服务端正文可能包含账户信息、调试数据，甚至回显认证材料，与 README/SECURITY 中“不会写入日志”的保证不一致。 | `KimiProvider.swift:418-420,453-454,469-470`；`KimiBrowserSession.swift:101-109`；`ZaiProvider.swift:304-309`；统一记录 `UsageStore.swift:490-495,660-661,702-703`。 | 默认只保存状态码和固定、截断、字段白名单后的 message；日志永不记录 body/header/token。UI 可给用户“查看诊断详情”的显式动作，但也要脱敏并设长度上限。 |
| F-13 | **P2** | **响应体和诊断输出没有真正的大小上限，存在内存/可用性风险。** `URLSession.data(for:)` 会先完整读入响应再返回；CLI `PipeReader` 也是 `readDataToEndOfFile()` 完成后才截断，注释所述“never hold runaway output”并不成立。`--version` 诊断既不设读取上限也没有 timeout；CLI timeout 后还等待 reader 完成，子进程继承 pipe 时可能拖延。 | HTTP `HTTPTransport.swift:20-29`；CLI `ArkCLIFetcher.swift:197-220,292-333`；诊断 `PreferencesWindow.swift:1184-1202`。 | 对 HTTP 用 streaming/bounded delegate 或统一 max response bytes；超限立即取消。Pipe 逐块读取、超过上限关闭/终止进程；诊断设置 deadline、终止 process group 并保证 reader 可退出。 |
| F-14 | **P2** | **Ark API-key Provider 用真实 chat 请求探测额度。** 每次刷新最多尝试多个模型并发送 `messages: "hi"`，可能产生计费、消耗 token、污染用户统计或触发内容策略；这不是只读额度查询。 | `ArkAPIKeyProvider.swift:27-46,49-67`；请求体 `:56-61`。 | 优先使用官方只读 quota/rate-limit endpoint；若不存在，应缓存探测结果并提供显式“允许一次探测”选项，或至少降低频率、只探测用户指定模型并明确可能计费。 |
| F-15 | **P2** | **Overview 菜单的状态源和刷新动作不一致。** `UsageStore.currentStatus`/status item 选择“最紧张” Provider，但 `StatusItemController.rebuildMenu` 在 summary 下把 `selectedTab` 固定为第一个 visible provider，Refresh 行的 loading、更新时间和错误因此代表第一个 Provider；点击却调用 summary refresh，刷新全部 visible providers。注释声称 tightest，实际绑定 first。Overview row 的 `NSMenuItem.isEnabled = false` 与 view 内 gesture 的点击能力也尚未在真实 AppKit 菜单验证。 | `UsageStore.swift:55-105`；`StatusItemController.swift:207-227,372-405,430-433`；`MenuBuilder.swift:115-128`；`SummaryRowView` gesture `MenuBuilder.swift:298-323`。 | Summary State 显式提供 `isAnyRefreshing`、整体最近更新时间和聚合错误，不借用某个 Provider；或让 Refresh 行只刷新/显示选中目标。把 overview item 保持可启用并写真实 NSMenu UI 测试，确认 row click 不被 disabled item 吞掉。 |
| F-16 | **P3/P2** | **可用性协议和配置行为不够一致。** Ark CLI、Ark API key、Volc API、Kimi、Nebula、Z.ai、LongCat 等多个 `isAvailable` 恒为 true，调用者仍会在无凭据时启动 fetch 并显示错误；DeepSeek/Kimi 还会在没有明确凭据时做浏览器/本地存储解析。另有 source mode、凭据和 URL 的 Combine sink 即使 Provider 隐藏也直接 `refresh(tab:)`，绕过“隐藏后停止后台刷新”的约定。 | `ArkCLIFetcher.swift:16-19`；各 Provider 的 `isAvailable`；`UsageStore.swift:281-303,433-437` 和配置 sink `:136-204`。 | 将 `isAvailable` 定义成纯、可测试的 credential availability；把“尚未配置”展示为 idle 状态而不是失败；只对 visible/configured provider 做自动 refresh，显式设置操作可单独触发。对隐式浏览器扫描增加设置开关并在首次使用时说明。 |
| F-17 | **P1** | **全局浏览器 Keychain prompt 文案绑定在 OpenCode 模块。** AppDelegate 启动时只配置 `OpenCodeGoBrowserSession.configureKeychainPrompt()`；同一 SweetCookieKit 全局 handler 也服务 Nebula、Kimi、LongCat 导入，但 alert 固定显示 OpenCode 文案和 `opencode.ai`，用户导入其他 Provider 时可能被要求批准错误的访问说明。 | `TokenBarApp.swift:22-31`；`OpenCodeGoBrowserSession.swift:41-66`；其他导入调用 `UsageStore.swift:348-430`。 | 让 handler 接受 provider/context，或使用中性的“TokenBar 将读取所选浏览器中该服务的登录 Cookie”文案；在发起每种导入前设置 scoped prompt，操作结束恢复全局状态。 |
| F-18 | **P1** | **打包脚本 fail-open，可能发布未签名/验证失败且移除 quarantine 的 App。** `codesign` 失败只打印 WARN，verify 用 `|| true`，随后仍安装并执行 `xattr -dr com.apple.quarantine`。这会把安全失败伪装成成功，并削弱系统对坏包的阻拦。资源 bundle 查找使用 `find ... -maxdepth 4`，macOS BSD `find` 不保证支持该选项；在 `set -euo pipefail` 下可能中止，或最终缺少 Provider logo。版本/build 还在脚本和 plist 中硬编码为 0.1.0/1。 | `Scripts/package_app.sh:9-25,46-54,60-84`；源 plist `Resources/Info.plist:8-15`。 | codesign、verify、资源复制、安装后的验证全部 fail-closed；验证失败不得移除 quarantine。用 BSD/跨平台兼容的 bundle 路径查找或直接使用已知 SwiftPM 输出路径。版本由单一来源注入并在 CI 校验。正式分发增加 Developer ID、notarization、staple 和 Gatekeeper smoke test。 |
| F-19 | **P2** | **CI 只跑测试，不验证可发布构建。** workflow 没有执行 `swift build -c release`、`package_app.sh`、资源 bundle 检查、codesign、notarization、Universal/Intel slice 或安装启动 smoke test；也没有 lint/format、依赖更新扫描或 artifact。`DEVELOPER_DIR` 硬编码到 `/Applications/Xcode_26.2.app`，runner 镜像变化会直接失效。 | `.github/workflows/ci.yml:9-21`；打包脚本独立存在但不在 CI。 | CI 分层加入 debug test、release build、资源/Info.plist 校验、`file`/`lipo`、codesign verify；发布 workflow 在真实 macOS 上做签名/公证。用明确的 Xcode matrix 或经过维护的 setup action，并在 README 记录实际 Swift/Xcode 要求。 |
| F-20 | **P2** | **测试覆盖偏解码/UI 纯函数，未覆盖关键风险路径。** 测试有约 100 项，但没有 UsageStore 真实状态竞态、取消、配置切换、Keychain 权限/失败、文件并发/symlink/权限、redirect、响应上限、CLI timeout/process tree、真实 SweetCookieKit 导入、LongCat selector、summary refresh binding 或签名/公证测试。所谓视觉回归主要检查 PNG 文件存在，不比较 reference image。 | `Tests/TokenBarTests/TokenBarTests.swift:1-2191`；视觉输出/存在性断言如 `:458-563,675-760,1120-1203`；ProviderVisibility 直接共享 singleton `:1063-1118`。 | 把 transport、clock、credential store、process runner、browser importer 和 settings 注入 `UsageStore`；增加 deterministic state-machine/取消测试和 security regression tests。视觉测试使用 reference image/pixel threshold 或明确改名为 smoke render。 |
| F-21 | **P2/P3** | **测试可能互相污染，且全局设置令测试与生产耦合。** Swift Testing 测试默认可能并行；两个 ProviderVisibility 测试共同修改 `AppSettings.shared`/`UserDefaults`，只在各自 defer 中恢复，存在交错风险。`MenuBuilder` 直接读取 `AppSettings.shared`，而不是只消费传入 State，增加不可控全局依赖。 | `Tests/TokenBarTests/TokenBarTests.swift:1063-1118`；`MenuBuilder.swift:115-120,168-185`；`AppSettings` singleton `Settings.swift:5-6`。 | 使用独立 suite storage/注入 settings，或显式串行化并清理所有 keys；MenuBuilder 只依赖 State/formatter 参数，生产入口负责组装。 |
| F-22 | **P2** | **Nebula 分页和数值聚合对异常服务响应不够健壮。** 每页 100、最多 20 页，超过 2000 条就静默截断；响应的 `total` 被解码但未用于判断是否完整。负数、异常时间、极大 token 值会进入聚合，`prompt + completion`、累计 Int 可能溢出或产生错误统计；日志失败则保留余额但没有明确的 Provider warning。 | `NebulaProvider.swift:27-44,275-330,438-494`；模型和 `cacheTokens` `:46-91`。 | 依据 server total/next cursor 分页，超过上限时标记 incomplete；限制单项和累计范围，拒绝负数/NaN/不合理时间；用 checked arithmetic/饱和算术并测试边界，UI 区分 partial。 |
| F-23 | **P2/P3** | **并发安全和全局可变状态仍靠“实践上安全”。** L10n 明确使用 `nonisolated(unsafe)` 暴露可变 `@Published language`，注释承认只在主线程修改；错误描述、菜单格式化和后台 Provider 可能跨 actor 读取。CLI `PipeReader` 使用 `@unchecked Sendable`，虽然有锁保护 collected，但 reader 生命周期/阻塞仍没有结构化并发保证。 | `Localization.swift:312-344`；`ArkCLIFetcher.swift:296-333`；全局状态还包括 `KimiProvider.webSessionInvalid`、UserDefaults 和静态缓存。 | 将 L10n 设为 `@MainActor` 或不可变快照；把后台错误转换为值后再在主 actor 本地化。尽量以 async sequence/actor 管理 CLI pipes，减少 `@unchecked Sendable`，并启用 Swift 6 strict concurrency 作为 CI 门禁。 |
| F-24 | **P2/P3** | **安全政策、README 和第三方说明已经与实现漂移。** `SECURITY.md` 声称“不持久化 Volcengine AK/SK”，但当前 Settings/Keychain/file cache 已保存它们；同文件还以 OpenCode 为主描述凭据边界。README/SECURITY 声称凭据不写日志，但 Kimi/Z.ai 错误路径会把响应 body 放入日志。`THIRD_PARTY_NOTICES.md` 说 SweetCookieKit 用于“明确授权的 OpenCode session”，实际还用于 Nebula/Kimi/LongCat 浏览器导入。 | `SECURITY.md:11-24`；`README.md:121-133`；`Settings.swift:367-383`；`THIRD_PARTY_NOTICES.md:3-9`；各错误路径见 F-12。 | 把凭据矩阵、浏览器读取时机、文件缓存威胁模型、日志脱敏和自定义 endpoint 风险写成单一规范并由 README/SECURITY 复用；更新第三方用途/版本/来源说明，发布前做文档与代码一致性检查。 |

## 4. 重点修复顺序

### 第一阶段：发布前安全门禁

1. **F-01/F-03**：统一 origin policy。Nebula/GrokPool 先强制 HTTPS 和明确 endpoint 规则；所有 credential-bearing request 使用同一 redirect-safe transport。补充最终 URL、跨 host、跨 port、HTTP、3xx 的测试。
2. **F-04**：CLI/诊断使用最小环境 allowlist；确认 arkcli 是否确实需要 HOME，禁止把其他 Provider secret 传入。
3. **F-18**：codesign/verify/资源复制改为 fail-closed，去掉无条件 quarantine removal；在目标 macOS 上实际生成、安装、验证和启动 `.app`。
4. **F-05/F-06**：定义 Keychain 与文件缓存的权威关系，正确传播失败，修复文件事务并发和路径安全。

### 第二阶段：数据正确性与生命周期

1. **F-07**：用 per-provider task + generation 重写刷新状态，覆盖慢 mock、取消、连续设置修改和旧结果丢弃。
2. **F-08/F-09/F-10/F-17**：接通 LongCat selector；清理/绑定 Kimi refresh pair；绑定 Nebula profile；统一浏览器授权提示。
3. **F-11/F-12/F-22**：修正 auth source、partial data、服务端错误和分页边界语义，所有未知数据不要静默显示为零。
4. **F-14**：移除或显式化真实 chat 探测。

### 第三阶段：工程化

1. **F-19/F-20/F-21/F-23**：增强 CI、注入依赖、拆分 `UsageStore`/`PreferencesWindow`/测试大文件，启用严格并发检查。
2. **F-24**：同步安全政策、README、CHANGELOG 和第三方 notices，发布前执行文档一致性审查。

## 5. 已有的正向控制

- `Package.resolved` 锁定了 SweetCookieKit 0.4.1 的具体 revision `21bedea672a3e63ccad24d744051e76cdf0462dd`，没有发现多余的直接外部依赖。
- Keychain 项使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，并设置了 no-UI 读取策略，减少后台刷新时的交互式弹窗。
- OpenCode 使用独立 URLSession、禁用 URL cache，并已有重定向 guard；这是统一 transport 应采用的方向，但仍需修正 port/origin 比较。
- 浏览器 Cookie 过滤大体按 Provider/domain 约束；OpenCode/Nebula/LongCat 的交互式导入入口和 routine refresh 路径在代码结构上已分开。DeepSeek 的 silent Chrome 读取则是显式产品选择，应继续在文档中清楚说明。
- `HTTPTransport`、Provider decode、部分 Browser token 解析可以注入 mock，已有不少 provider fixture 和边界格式测试。
- SwiftUI 设置和 AppKit 菜单多数在 `@MainActor`，Provider 状态已按 Provider 分离，降低了一个 Provider 覆盖另一个 Provider 的风险。
- 仓库含 MIT license、`SECURITY.md`、第三方 notices，并在 README 中主动声明 arm64-only 本地打包和尚未验证 Intel 的限制；问题在于这些说明尚未随当前实现完全同步。

## 6. 测试与验证状态

### 已完成

- 静态审阅主源码、8 个 Provider、凭据/Keychain/file cache、浏览器会话、刷新生命周期、AppKit 菜单、设置窗口、测试、CI、依赖、README、SECURITY 和打包脚本。
- 已确认仓库公开元数据和 CI 配置；针对基线提交的 GitHub Actions test run 为 success：<https://github.com/youwei792/ArkBar/actions/runs/33013565418>。
- 已确认当前工作区在审计前无业务代码修改；本次只新增本报告。

### 本环境未执行

当前环境没有 Swift/Xcode/macOS 工具链，因此没有执行以下命令或运行时验证：

- `swift test`、`swift build`、Swift 6 strict-concurrency 编译检查。
- 真实 macOS AppKit 菜单、`NSMenuItem.isEnabled = false` 自定义 gesture、设置窗口、状态栏布局和多显示器行为。
- 真实 Provider 网络请求、HTTP 3xx 跨 host/port redirect、响应超限、取消竞态和服务端字段契约。
- Chrome/Arc/Safari/Edge/Brave/Firefox/Kimi.app LevelDB/Cookie 导入、profile 对应关系和 Keychain 授权/拒绝路径。
- 文件缓存并发写入、权限/符号链接/磁盘失败、Keychain add/update/delete 失败。
- `arkcli` 的环境可见性、超时/子进程树、诊断命令卡死。
- `Scripts/package_app.sh`、资源 bundle 是否复制、arm64/Intel/Universal、codesign、notarization、Gatekeeper 和安装启动。

因此，报告中的 F-03、F-13、F-17 需要目标 macOS 的验证来确定最终表现，但即使运行时暂时未复现，也不建议继续依赖默认重定向、完整响应读入或被吞掉的签名失败。

## 7. 维护性评估

当前源码把 8 个 Provider、多个浏览器导入器和完整 AppKit/SwiftUI 设置都放在单一 executable target 中；`UsageStore.swift` 约 861 行、`PreferencesWindow.swift` 约 1248 行、`MenuBuilder.swift` 约 791 行、测试约 2191 行。Provider 复制了许多相同的状态和错误处理流程，短期易于增加功能，长期会使生命周期 bug 和认证策略漂移。

建议的目标架构：

- `ProviderStateStore`：按 `ProviderTab` 保存统一状态、Task、generation、last success 和 partial diagnostics。
- `CredentialStore`：协议化 Keychain/file cache，并在单 actor 中实现原子读改写、迁移、清除和状态报告。
- `SafeHTTPClient`：统一 ephemeral session、redirect/origin policy、max response bytes、timeout、redacted error。
- `BrowserSessionImporter`：统一 `ProviderContext`、profile identity 和 prompt 文案，Provider 只声明允许的 domains/keys。
- `MenuState`：菜单只渲染注入的 immutable state，不再从 `AppSettings.shared` 读取隐藏全局设置。
- `Release workflow`：测试 → release build → resource check → architecture check → sign → verify → notarize → smoke test，每一步失败都停止。

**总体评价**：代码已经具备可维护产品雏形，但当前应视为“功能丰富的开发/预发布版本”，而不是已完成安全加固和发布工程闭环的正式版本。