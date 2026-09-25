# StepFun（阶跃星辰）与 SenseNova（商汤日日新）接入交接

> **2026-09-25 复核**：两者均已落地可用（见下方状态更新）；本会话另修复了
> StepFun 会话轮换回写与导入校验（`Oasis-Token` 必需）。总体状态与验证清单见
> `docs/handoff-2026-09-25.md`。

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

### SenseNova：已完成 ✅

**接口契约（2026-09-23 实测确认）：**

1. **鉴权**：控制台数据面只认 OAuth bearer token。域配置（bundle 内）：
   `client_id=nova`、`redirect_uri=https://platform.sensenova.cn`（只有这个是注册过的）、
   `scope=openid offline offline_access`、IdP 为 `iam.sensecoreapi.cn`（Hydra）。
   **实测：导入 `oauth2_authentication_session` 后，login 与 consent 两跳都自动放行**，
   因此可以完全无交互地走完 授权码+PKCE：
   `GET /oauth2/auth?...` →(302 login_challenge)→ IdP `/iam/authn/v1/auth/login` →(302 login_verifier)→
   `/oauth2/auth` →(302 consent_challenge)→ IdP `.../auth/consent` →(302 consent_verifier)→
   `/oauth2/auth` →(303 `?code=`)→ `POST /oauth2/token`（`grant_type=authorization_code` + `code_verifier`）。
   `expires_in=10800`，并下发 `refresh_token`（后续用 `grant_type=refresh_token` 续，不需要浏览器）。
   - 关键坑：**不能把已存的 `oauth2_*_csrf` 一起回灌**，CSRF 与 challenge 一一绑定，
     旧的会直接换来 `request_forbidden … CSRF value from the token does not match`。
     种入会话 cookie、其余 csrf 由每一跳现下发即可。
   - 跳转链跨两个可注册域，自动重定向 + 共享 cookie 存储会被第三方策略拦掉，
     所以要手工逐跳跟随并自己带 Cookie 头。
2. **额度**：`GET {origin}/lite/console/v1/tokenplan/pool-usage`（Bearer）→
   ```json
   {"plan":{"id":"free","name":"Free Plan","type":"TOKEN_PLAN_PLAN_TYPE_FREE"},
    "pools":[{"id":"pool_…","name":"通用积分池","pool_type":"default","model_ids":[…],
      "window_5h":{"limit":"60000","used":"0","remaining":"60000","reset_at":"1790111866"},
      "window_7d":{"limit":"600000","used":"151348","remaining":"448652","reset_at":"1790342266"},
      "grant_balance":"0","nearest_grant_expiry":"0","nearest_grant_expiring_balance":"0"}]}
   ```
   所有数字都是**十进制字符串**；`reset_at`/`nearest_grant_expiry` 是 **epoch 秒**，`0` 表示无。
   恒等式 `used + remaining == limit` 成立，所以 `usedPercent = used / limit`。
   免费档实测：5 小时 60,000、每周 600,000（与官网公告一致）。
3. **映射**：每个积分池一条 PlanSnapshot（通用池 + 模型专属池各自成环，不合并平均），
   窗口 `5-hour` / `Weekly`；`nearest_grant_expiry` 是**加油包**最近到期，不是套餐到期，
   因此刻意不驱动到期徽标。

**修掉的两个真 bug**（"获取不到进度"的直接原因）：

1. **导入器接受无登录态的 cookie 包**：`sensenova.cn` 域上同时存在百度统计 `Hm_lvt_*`
   与 GrowthBook `gr_user_id`，旧代码只判断"cookie 非空"，于是**未登录也能导入"成功"**，
   之后每个请求都带着垃圾凭据（实测旧缓存包里就只有这两个名字）。现在要求必须含
   `*authentication_session*`，历史无效缓存包作废；诊断只记 cookie **名字**，绝不记值。
2. **探测链被第一个 401 打断**：7 个候选只跑了第 1 个（这也是诊断文件只有 1 行的原因）。
   现已换成确认过的唯一真接口，正常路径每次刷新只发 1 个请求。

**遗留观察（未修，非阻塞）**：启用"商汤"标签后的那次启动，日志里商汤刷新了两次
（其他 provider 一次），token 走的是缓存、兜底探测未触发，因此只是多一次请求；
触发点尚未定位。

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
