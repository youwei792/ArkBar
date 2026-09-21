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

### SenseNova：已冻结 ⏸

已确认的事实：
- 控制台 `platform.sensenova.cn/console`，登录态 cookie 为
  `platform.sensenova.cn` 上的 `oauth2_authentication_session`（OAuth2 架构，
  数据端点在登录后懒加载的 chunk 里，匿名侧挖不到）。
- 额度结构（页面实测）：**双积分池**——「通用积分池」与「Flash-Lite专属积分池」，
  每池含：周余额（本周余额）、5h 窗口可用（used/limit + 重置时间）、周额度（下次重置）。
- App 内已实现探测版 provider：导入会话成功，7 个候选端点全部未命中，
  每次探测的响应落在 `~/Library/Application Support/TokenBar/sensenova-last-response.txt`。

**解冻所需（一次约 1 分钟）**：登录控制台后 F12 → Network → 刷新 → 把返回积分数字的
请求 URL + 响应 JSON 交给开发者，按 StepFun 同款速度收掉。Computer Use 尝试过自动
抓取，DevTools 面板自动化成本过高，已放弃该路线。

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
