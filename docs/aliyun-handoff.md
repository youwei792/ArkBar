# 阿里云百炼 Token Plan / Coding Plan 接入交接

> 状态：**代码已完成，浏览器登录的监听缺陷已修**（2026-09-25 二次复核，见
> `docs/aliyun-browser-login-fix.md`）。三种鉴权方式均可用，**无需安装官方 `bl` CLI**。
> 唯一待完成的一步：**真人登录一次**验证端到端（见文末「验证清单」）。

## 1. 现状概览

| 能力 | 状态 |
| --- | --- |
| Token Plan（积分制：5 小时 / 每周 / 每月已用比例环 + 到期日） | ✅ 已实现（契约来自官方 CLI 源码 + 真机抓包复核） |
| Coding Plan（请求数制：5h/周/月三档绝对值环） | ✅ 已实现 |
| 套餐类型自动识别 | ✅ 首次成功后记住（`tokenbar.aliyunDetectedPlan` 偏好），之后每轮只查一个接口 |
| 浏览器登录（`bl auth login --console` 同款流程） | ✅ 已实现并修好监听（原 `NWListener` 在挂 VPN 的机器上必然 EINVAL 启动失败）；回调契约与官方 CLI 逐字对齐，**待真人登录一次验证** |
| AK/SK（ACS3 签名换 console token） | ✅ 已实现，签名算法与官方 CLI 逐位一致（有固定向量测试） |
| sk-sp- 套餐 Key 兜底尝试 | ✅ 已实现（网关拒绝 → 本次运行内不再重试，报可操作的 invalid-token） |
| 失败诊断 | ✅ 写 `~/Library/Application Support/TokenBar/aliyun-last-response.txt`（无凭据） |

## 2. 三条鉴权路径（优先级从高到低）

1. **浏览器登录（推荐，无需 AK/SK）**
   与官方 CLI `bl auth login --console` 完全相同的机制：
   - 本地 **loopback-only 原生 socket**（`bind(127.0.0.1:0)`）+ `DispatchSource` 读事件，
     生成 32 位十六进制 `state`；
     （**不是** `NWListener`：本机 Proton VPN 的 WireGuard 网络扩展处于激活状态时，
     `NWListener` 任何参数组合都以 `NWError 22 EINVAL` 失败——已在
     `docs/aliyun-browser-login-fix.md` 里逐项复现；官方 CLI 同样是 loopback-only + exclusive。）
   - 打开 `https://bailian.console.aliyun.com/console-login?notice=127.0.0.1:<port>?state=<state>`
     （注意 `notice` 参数里字面上含一个 `?`，必须原样发送，这是官方 CLI 的写法）；
   - 控制台登录页把 `access_token` 回调到本地端口（支持 GET query、POST
     urlencoded / JSON（含 `data.access_token` 嵌套）/ multipart `FormData`）；
   - 校验 `state` 不一致 → 400 并继续等待；**state 正确但不带 token 的中间请求 → 200 并继续等待**
     （与官方一致，不再整体判失败）；拿到令牌后回 200 结束流程；
   - **每个响应都必须带 `Access-Control-Allow-Origin: *`**（含成功那个 200）：控制台是用跨域
     `fetch` 投递令牌的，缺这个头 → 浏览器把这次请求判为失败 → 页面永远停在「授权中」，
     而令牌其实已经到手了。这一条真机踩过；
   - 重复点击会**取消上一次尝试**（旧监听立即释放端口，不再各占 10 分钟），被取消的那次不写日志；
   - 令牌存 Keychain（`aliyun-console`），10 分钟超时；成功/超时/被新点击取消都会 cancel source，
     **并由 cancel handler 以「按值捕获的 fd」关闭监听**——handler 在下一个队列轮次才跑，
     那时 server 往往已经释放，靠 `weak self` 关 fd 会静默失败并永久占住端口（真机出现过 7 小时未释放）。
   - 过期（401）→ 清掉令牌；若同时配有 AK/SK 则自动回退，否则报
     `aliyunConsoleLoginExpired` 提示重新登录。
   - ⚠️ **这张令牌只有几分钟寿命**（实测 22:48:51 拿到、22:52:20 已 `Login.NotLogined`；
     注意每次重新登录也可能使上一张失效），而默认刷新是 5 分钟一次 —— 所以纯浏览器登录会周期性变红。
     要长期无人值守出数，请配 AK/SK（app 会自己重新换票）。

2. **AK/SK**：ACS3-HMAC-SHA256 签名 `POST modelstudio.cn-beijing.aliyuncs.com
   /modelstudio/cli/generateAccessToken`（action `GenerateCLIAccessToken`，
   version `2026-02-10`，空 body）→ `cliAccessToken`，内存缓存 ~10 分钟，
   401 自动重换一次。需要 `modelstudio:GenerateCLIAccessToken` 权限。
   环境变量：`ALIYUN_ACCESS_KEY_ID` / `ALIYUN_ACCESS_KEY_SECRET`。

3. **sk-sp- 套餐 Key**：直接作为 Bearer 试控制台网关（元数据接口，拒绝不耗额度）。
   已被真机验证会返回 `200 + {"data":{"success":false,"errorCode":"InvalidParameter",
   "errorMessage":"Bad Request"}}`——说明**网关调用链路（URL/表单编码/信封解析）
   已被真实网络验证**，只是这个 Key 本身无权。失败后 `markAPIKeyRejected()`，
   同一次运行内不再重试。

## 3. 最终契约（官方 CLI 同源，未做抓包猜测）

来源：`github.com/modelstudioai/cli`（npm `bailian-cli`），`packages/commands/src/commands/usage/token-plan.ts`、
`coding-plan.ts`、`packages/core/src/client/acs.ts`、`packages/commands/src/commands/auth/login-console.ts`。

**网关调用（两种套餐共用）**：

- `POST https://bailian-cs.console.aliyun.com/cli/api.json?action=BroadScopeAspnGateway&product=sfm_bailian&api=<encoded api name>`
- Header：`Authorization: Bearer <console token>`；
  Body（x-www-form-urlencoded）：`params=<JSON>&region=cn-beijing`
- `params` JSON：`{"Api":"<api name>","V":"1.0","Data":{...,"cornerstoneParam":{...}}}`
  ——**`cornerstoneParam` 由客户端对每一次调用统一注入**（官方 `buildGatewayParams()`），
  Token Plan 那种空 payload 也要带；写在 `AliyunConsoleAPI.gatewayCall` 里，
  不要退回某个套餐的私有 payload。
- **错误信封**：HTTP 200 + `{"data":{"success":false,"errorCode":...,"errorMsg"|"errorMessage":...}}`
  ——必须检查，不能只看状态码（已实现于 `AliyunConsoleAPI.assertEnvelopeSucceeded`）。
  真机见过的形态：`errorCode:"BailianGateway.Login.NotLogined"` + **`errorMsg`**（不是 `errorMessage`）；
  未登录类错误靠 `notlogined` 子串识别并映射为 `aliyunInvalidToken`。
- 控制台页面自己走的是 `/data/api.json`（cookie 会话），CLI 与 TokenBar 走 `/cli/api.json`
  （Bearer 换票）；两者 `params`/`region` 表单体与信封一致。核对契约时可以用登录态的浏览器
  直接向 `/data/api.json` 发同样的 body 取真实响应（本次的月度字段就是这么抓到的）。

**Token Plan**：

- api name：`zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage`，`Data` 只有 `cornerstoneParam`
- 响应（unwrap 后）：`per5HourPercentage` / `per1WeekPercentage` / `per1MonthPercentage` 为
  **[0,1] 的已用比例**，配对的 `per*ResetTime` 为 epoch 毫秒。
  **真机实测：个人版 Essential 只返回 `per1MonthPercentage` + `per1MonthResetTime`**，
  没有 5 小时与每周两档 —— 只按官方 CLI 打印的两档解析会把有套餐的账号误判成「未订阅」。
- 无绝对计数 → 圆环只显示比例（`used`/`total` 为 nil）
- 用量接口**不含任何日期**，到期日与套餐档位来自同一页会调的订阅记录：
  `zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription` →
  `{instanceCode, specCode:"essential", remainingDays, startTime, endTime, autoRenewFlag, status:"VALID"}`；
  TokenBar 只取 `specCode`（→ 卡片 edition `Essential`）与 `endTime`（→ 到期日/倒计时/到期提醒），
  `remainingDays` 是派生值故忽略。该调用失败只损失这两项显示，不影响已拿到的用量。

**Coding Plan**：

- api name：`zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2`
- `Data`：`{"queryCodingPlanInstanceInfoRequest":{"commodityCode":"sfm_codingplan_public_cn",
  "onlyLatestOne":true},"cornerstoneParam":{"protocol":"V2","console":"ONE_CONSOLE",
  "productCode":"p_efm","switchUserType":3,"consoleSite":"BAILIAN_ALIYUN"}}`
- 响应信封：`data → DataV2 → data → data → codingPlanInstanceInfos[]`，取第一个
  `status == "VALID"` 实例的 `codingPlanQuotaInfo`：
  `per5Hour|perWeek|perBillMonth` × `UsedQuota|TotalQuota|QuotaNextRefreshTime`（epoch 毫秒）；
  `instanceType` 如 `pro`；`expiredTime`（可选）作到期徽标。

**ACS3 签名**（与官方 acs.ts 逐位一致，`Tests` 中有固定向量断言）：

- 签名头：`host`, `content-type`, `x-acs-action`, `x-acs-content-sha256`,
  `x-acs-date`（ISO8601 秒级 UTC）, `x-acs-signature-nonce`（UUID）,
  `x-acs-version`；按字母序拼接
- canonicalRequest = `METHOD\nPATH\nQUERY\ncanonicalHeaders(含尾换行)\nsignedHeaders\nhashedBody`
- stringToSign = `ACS3-HMAC-SHA256\n` + sha256hex(canonicalRequest)
- signature = **直接用 secretKey 做 HMAC-SHA256**（无派生密钥，与火山 V4 不同）
- Authorization：`ACS3-HMAC-SHA256 Credential=<AK>,SignedHeaders=<...>,Signature=<...>`
  ——**逗号后无空格**（曾在实现里写成 `", "`，被固定向量测试抓出）。

## 4. 代码结构

| 文件 | 职责 |
| --- | --- |
| `Sources/TokenBar/AliyunProvider.swift` | fetch 流程（三条鉴权路径 + 401 回退）、双套餐识别、解析（`parse` / `parseTokenPlan` / `unwrapEnvelope`）、快照映射、诊断写入 |
| `Sources/TokenBar/AliyunSigner.swift` | `AliyunCredentials`、环境变量解析（AK/SK、sk-sp-）、ACS3 签名器、console 网关调用（`AliyunConsoleAPI`，`gatewayCall` 统一注入 `cornerstoneParam`）、token 缓存 actor（`AliyunConsoleTokenStore`，含 `markAPIKeyRejected`） |
| `Sources/TokenBar/AliyunConsoleLogin.swift` | 浏览器登录：`CallbackServer`（loopback-only 原生 socket + `DispatchSource`）、请求解析（`CallbackRequest`，含 multipart）、state 校验、超时 |
| `Sources/TokenBar/Settings.swift` | `aliyunConsoleToken` / `aliyunAccessKeyID` / `aliyunSecretAccessKey` / `aliyunAPIKey`（均 Keychain 镜像）、`aliyunDetectedPlan`（UserDefaults 偏好） |
| `Sources/TokenBar/PreferencesWindow.swift` | 阿里云百炼面板：浏览器登录按钮 + 登录状态 + sk-sp- + AK/SK 三个输入 |
| `Sources/TokenBar/UsageStore.swift` | `reimportAliyunConsoleLogin()`；凭据变更触发 `.aliyun` 刷新 |
| `Sources/TokenBar/UsageModels.swift` | `UsageError.aliyun*`（missingCredentials / invalidToken / notActivated / consoleLoginExpired）；`PlanSnapshot.Product.aliyunTokenPlan` |
| `Sources/TokenBar/Localization.swift` | `aliyun.*` 与 `error.aliyun*` 中英文案 |

## 5. 测试

```bash
swift test                                   # 全量：231 测试 / 57 suites
swift test --filter "Aliyun"                 # 阿里云相关：43 测试 / 8 suites
```

覆盖：ACS3 签名固定向量（与官方 node 算法逐位比对）、双套餐解析（真实信封/边界/缺失字段）、
mint→查询全流程、401 重换、过期信封重换、双套餐探测与回退、浏览器登录回调解析
（GET/POST/JSON/嵌套/multipart）、**回调服务器的真实 socket 用例**（真连接投递 token、
无 token 与伪 state 继续等待、POST 表单、超时后端口已释放、绑定后未 serve 也释放端口）、
**网关请求体本身**（两种套餐都带 `cornerstoneParam`、Token Plan 的 `Data` 除它以外为空、
Coding Plan 的查询对象保留）、token 来源优先级、sk-sp- 拒绝后不重试。

**测试已做隔离**：`AliyunProviderFetchTests` 标注 `.serialized`，且每个测试用
`clearAmbientAliyunCredentials()` 清空并还原本机 Keychain 里的真实凭据——
不要移除，否则测试会依赖开发者机器状态（曾因此出现 flaky）。

## 6. 已知行为与坑

- **设置面板的 Save 会把空字段写空**（全仓库通用行为）：如果字段因故为空时点了
  Save，会清掉 Keychain 里的旧值。用户曾因此丢失过旧的 sk-sp- key
  （该 key 与用量读取无关，无影响，但知悉即可）。
- `Settings` 面板中 AK/SK 与 sk-sp- 三个输入框共用 `saveCredentials()`，各自
  `.onSubmit` 也会触发保存。
- 套餐识别一旦记住，若账号换了套餐（Token→Coding），需要成功一次另一条
  路径才会改写；识别为 `.coding` 时若 Coding 查询失败会自动回退试 Token。
- 因是控制台网关（元数据接口），**所有请求都不消耗套餐额度**；这也是
  sk-sp- 兜底尝试可以放心做一次的原因。

## 7. 验证清单（接手者/真人）

0. **监听本身已被真实 socket 测试覆盖**（`swift test --filter Aliyun` 里的
   `Alibaba Cloud console login callback server`：真连接投递 token、伪 state/无 token
   继续等待、POST 表单、超时后端口释放）。剩下没被覆盖的只有「控制台页面真的会回调」
   这一条，必须真人登录一次。
1. **浏览器登录端到端**（唯一未验证项）：设置 → 阿里云百炼 → 点「浏览器登录百炼控制台」，
   在浏览器完成登录；预期：控制台回调后 app 自动刷新，菜单栏出现
   Token Plan 两环（5 小时 / 每周剩余比例）。
   抓 stderr 可看到 `✓ 阿里云: console login succeeded` 与刷新行
   `✓ 阿里云: 1 plan(s)`。失败时看
   `~/Library/Application Support/TokenBar/aliyun-last-response.txt`。
   - 想先确认端口起来了而不登录：`lsof -nP -iTCP -sTCP:LISTEN | grep TokenBar`
     能看到 `127.0.0.1:<port>`；对它发任意 `curl "http://127.0.0.1:<port>/?state=wrong"`
     应回 `bad state`（说明监听与解析都在工作，且伪 state 被拒）。
2. 终端直接跑以观察日志：
   `pkill -f "TokenBar.app/Contents/MacOS/TokenBar"; /Applications/TokenBar.app/Contents/MacOS/TokenBar 2>&1 | grep 阿里云`
   （先退出正在运行的实例，避免双开）。

## 8. 抓包备用路径（若阿里云改动契约）

控制台页面 `https://bailian.console.aliyun.com/cn-beijing/subscription/coding-plan` 的
XHR 里找用量请求；Token Plan 在订阅页。DevTools → Network → Fetch/XHR，按 §3 的
字段结构对拍 `parse`/`parseTokenPlan` 的别名列表。产品事实（5h 6000 / 周 45000 /
月 90000 次；5 小时滚动恢复）来自官方文档，见 README 提供商表。