# StepFun（阶跃星辰）与 SenseNova（商汤日日新）接入交接

两个平台都是赠送的 Plan，用户想追踪剩余额度和到期时间。调研结论（2026-09-21）：

## StepFun Step Plan

- 套餐：月度 Credit 制（1M Credit = ¥1），档位 Flash Mini 400M / Plus 1600M /
  Pro 8000M / Max 40000M；月末清零不结转；加油包独立 30 天周期。
- 调用：`https://api.stepfun.com/step_plan`（Anthropic 兼容）或
  `/step_plan/v1`（OpenAI 兼容），普通 Step API Key；与按量通道额度独立。
- **公开 API 只有 `GET /v1/accounts`（Bearer API Key）**：返回
  `balance / total_cash_balance / total_voucher_balance`——只有余额，
  没有 Step Plan Credit、用量、到期时间（已实测探测 `/v1/credits`、
  `/v1/usage`、`/v1/subscription` 等均 404）。
- 结论：**套餐额度/到期需要控制台抓包**。

## SenseNova Token Plan

- 套餐页 `https://www.sensenova.cn/token-plan`；控制台
  `https://platform.sensenova.cn/token-plan`；模型网关
  `https://token.sensenova.cn/v1`（OpenAI 兼容，海外 `.ai` 域）。
- 公测免费档：60,000 积分 / 5 小时（滚动窗口）；模型 SenseNova 6.8 Flash
  Lite / U1 Fast；最多 20 个 API Key。
- 实测：网关只有模型路由（`/models` 401，其余全部 404），
  `platform/api/*`、`api.sensenova.cn` 等也无公开路由——**额度/到期需要
  登录态抓包**（console 页面是 Next.js SPA，接口在登录后可见）。

## 状态更新（2026-09-22）

### StepFun：已完成 ✅

接口契约全部逆向确认（控制台 Connect-RPC，cookie 鉴权）：

1. **导入**：Chrome 的 `Oasis-Token` / `Oasis-Webid` cookie（`account.stepfun.com` 与
   `platform.stepfun.com` 两个域都要）。
2. **轮换**：`POST /passport/proto.api.passport.v1.PassportService/RefreshToken`
   （注意：不是 `/api/...` 路径，前端 fetch 封装会把 `/api/proto.api.passport.v1.GlobalPassportService`
   重写成 `/passport/...`）。响应头 `Set-Cookie` 会下发**新的 Oasis-Token 和新 Oasis-Webid**，
   两者必须一起替换，否则报 `token is illegal`。access token 有效期 1800 秒，每次抓取都先轮换。
3. **查询**（都要带 `Oasis-Webid` / `Oasis-Platform: web` / `Oasis-appID: 10300` 三个头，
   `Connect-Protocol-Version: 1`，body `{}`）：
   - `POST /api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit`
     → `five_hour_usage_left_rate` / `weekly_usage_left_rate`（0–1 剩余率）+
     `plan_credit_rate_limit.subscription_credit_left_rate` +
     `credit_buckets[0]`（`credit_total` / `credit_residual` / `expire_at`）。
   - `POST /api/step.openapi.devcenter.Dashboard/GetStepPlanStatus`
     → `subscription.name` / `subscription.expired_at`（epoch 秒）。
4. **窗口判定规则**：`*_usage_reset_time` 为 "0" 表示该窗口不适用（本账号 Plus 套餐
   只有月度 Credit，无 5 小时/周限制），不能把 0 剩余率当成"已用尽"。

结论：**API Key 无法读取套餐额度**（三个 RPC 均返回 `api key not permitted for this method`），
必须走控制台会话；网关 `/v1/models` 响应头也不含额度信息。

### SenseNova：接口已定位，卡在鉴权形态 ⏸

**2026-09-22 进展：额度接口已确认（从控制台前端产物逆向，非猜测）。**

- 控制台是 Next.js App Router。仪表盘组件（i18n 命名空间 `consoleDashboard`）请求：
  `${location.origin}/lite/console/v1/tokenplan/pool-usage`（**双积分池**）与
  `…/tokenplan/credit-usage-trend`（趋势图）。前端封装在 `Em()` 里，
  经 axios 拦截器**无条件附加 `Authorization: Bearer <access token>`**。
- 响应外壳：`{ pools: [ … ] }`（组件直接读 `resp.pools.length` / `pools.map`，以 `pool.id` 作 key）。
  每个 pool 的字段（从渲染代码提取）：`limit`、`remaining`、
  `window_5h{limit, remaining, reset_at}`、`window_7d{limit, remaining, reset_at}`、
  `nearest_grant_expiry`（epoch 秒）、`nearest_grant_expiring_balance`、`grant_balance`。
- 域配置（bundle 内）：`platform.sensenova.cn` →
  `signinUrl/callbackUrl=https://platform.sensenova.cn`、`sensecoreIamApi=https://iam.sensecoreapi.cn`、
  `consoleUrl=https://console.sensecore.cn`；client_id = **`nova`**；
  scope = `openid offline offline_access`；登录走 Hydra 授权码 + PKCE，
  token 交换 `POST {signinUrl}/oauth2/token`。

**实测的鉴权结论（都是确定性错误，不是网络问题）：**

| 尝试 | 结果 |
| --- | --- |
| 只有控制台 cookie，无 Bearer | `401 code=16 Authorization header is required` |
| 用已存的 `sk-*` API Key 当 Bearer | `401 Authentication type 'apikey' is not enabled` |
| 用导入的会话 cookie 跑 PKCE（`/oauth2/auth`） | 302 到 `iam.sensecoreapi.cn` 且带 `login_challenge` → 会话不被识别，要求交互式登录（该登录需要短信验证码） |
| 读浏览器 localStorage 里的 `access_token` | SPA 按 `nova:<clientId>:login` 存的是 **CryptoJS AES 密文**，且随 access token 过期 |

**同时修掉的两个真 bug**（这才是"获取不到进度"的直接原因）：

1. **导入器接受无登录态的 cookie 包**：`sensenova.cn` 域上同时存在百度统计 `Hm_lvt_*`
   与 GrowthBook `gr_user_id`，旧代码只判断"cookie 非空"，于是**未登录也能导入"成功"**，
   之后每个请求都带着垃圾凭据。现在要求 cookie 里必须含 `*authentication_session*`，
   缓存里缺该 cookie 的旧包也一并作废；诊断文件记录 cookie **名称**（绝不记录值）。
2. **探测链被第一个 401 打断**：旧代码遇到任一候选返回 401/403 立即抛"登录已失效"，
   7 个候选只跑了第 1 个（诊断文件里只有 1 行就是这个原因）。现在跑完全部再汇总判定。

**解冻剩余工作**：需要一个可程序化获取的用户级 token。按可行性排序：
(a) 用户在浏览器真实登录后，用其 `oauth2_authentication_session` 走一遍 PKCE，
验证 Hydra 是否对 `nova` 客户端免同意放行（若放行，TokenBar 可自持 refresh_token 并存 Keychain，
与 StepFun 的 token 轮换同构）；(b) 商汤开放"API Key 读套餐额度"；(c) 手动粘贴 access token
（有效期短，体验差）。当前账号状态下 (a) 无法验证：**Chrome 内该域只有
`oauth2_authentication_csrf`（登录前置 cookie），没有 `oauth2_authentication_session`**，
即浏览器本身没有控制台登录态。


## 抓包步骤（两个平台通用）

1. 浏览器登录控制台（StepFun：platform.stepfun.com；SenseNova：以用户实际
   使用页为准），打开显示套餐额度/到期时间的页面。
2. DevTools → Network → 筛选 Fetch/XHR → 刷新页面。
3. 找到返回额度数据的请求，记录：完整 URL、请求头（鉴权方式：Cookie 还是
   Bearer）、响应 JSON 全文（脱敏后）。
4. 交给开发者：套用 OpenCode Go 模板实现 provider（浏览器会话导入 +
   JSON 解析 + 三环/到期徽标映射），预计每个平台一小时量级。

## 落地模板

参考 `Sources/TokenBar/AliyunProvider.swift`（骨架 + 占位解析）与
`Sources/TokenBar/OpenCodeGoProvider.swift`（完整实现：cookie 导入、
`parseConsoleStatus`、`access.endsAt` → 到期徽标 + 提醒）。新 provider 按需：
ProviderTab case、UsageModels Product、Settings Keychain 凭据、UsageStore 接线、
设置页、ProviderLogo、本地化、测试、README/CHANGELOG。

## 注意

- 不要提交真实 Key、Cookie 或含账号信息的响应原文（脱敏后再进测试 fixture）。
- Chrome Cookie 读取需要 App 拥有「完全磁盘访问」权限（已授予）。
