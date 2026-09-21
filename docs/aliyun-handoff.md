# 阿里云百炼 Coding Plan 接入交接（阶段 2：开通后抓包适配）

本文档面向开发者。阶段 1 已交付完整的 provider 骨架（tab、设置页、三环映射、
到期徽章、错误态、测试），但**真实的用量接口尚未确认**——阿里云官方文档只
写了"在 Coding Plan 页面可以查看用量"（控制台
`https://bailian.console.aliyun.com/cn-beijing/subscription/coding-plan`），
没有公开的查询 API。等用户的套餐开通后，按下面步骤抓包确认契约，然后替换
`AliyunProvider.fetchUsage` 的实现。

## 产品事实（来自官方文档，开通前可确认）

- 仅 Pro 档可订阅：¥200/月（新客首月 ¥39.90）；Lite 已停售。
- 请求额度：**5 小时 6,000 次**（滚动恢复，每分钟释放 5 小时前的额度）、
  **每周 45,000 次**（每周一 00:00:00 UTC+8 重置）、**每月 90,000 次**
  （下一个订阅日 00:00:00 UTC+8 重置）。单次提问按实际模型调用次数扣减。
- 专属 API Key：`sk-sp-` 开头，与按量计费的 `sk-` Key 不互通。
- Base URL（OpenAI 兼容）：`https://coding.dashscope.aliyuncs.com/v1`
  （Anthropic 兼容：`https://coding.dashscope.aliyuncs.com/apps/anthropic`）。
- 支持模型：qwen3.7-plus、kimi-k2.5、glm-5、MiniMax-M2.5 等。
- 月度订阅，到期后额度不结转。

## 抓包步骤

1. 在 Chrome/Safari 登录百炼控制台，打开 Coding Plan 页面
   （`https://bailian.console.aliyun.com/cn-beijing/subscription/coding-plan`）。
2. 打开 DevTools → Network，筛选 `Fetch/XHR`，刷新页面。
3. 找到返回用量数据的请求（响应里应包含已用/剩余额度、5 小时/周/月窗口、
   可能还有订阅到期时间）。记录：
   - 请求 URL（完整，含 query）与 method；
   - 请求头（鉴权方式：Cookie？`Authorization: Bearer`？自定义头？）；
   - 响应 JSON 全文（脱敏后）与关键字段路径。
4. 确认鉴权方式：
   - 如果 `sk-sp-` Key 可以直接调用该接口 → 最简单，`fetchUsage` 里用
     Bearer 认证即可；
   - 如果只有控制台 Cookie 会话可用 → 走 Kimi/LongCat 同款浏览器会话
     导入方案（仓库已依赖 SweetCookieKit），新增 `AliyunBrowserSession`。

## 落地改动

1. **只改 `Sources/TokenBar/AliyunProvider.swift`**：
   - 把抓到的响应贴进 `parse(data:)` 的 fixture（
     `Tests/TokenBarTests/TokenBarTests.swift` 的
     `AliyunProviderDecodeTests`），先让解析测试反映真实字段；
   - 按真实字段名调整 `parse` 里的别名列表（当前是按猜测写的宽容解析）；
   - 用真实 endpoint 实现 `fetchUsage(apiKey:)`，注意 401/403 →
     `UsageError.aliyunInvalidToken`，网络错误 → `UsageError.networkError`。
2. `AliyunUsageSnapshot` / `makeSnapshot` 的映射层**不需要动**——窗口 kind
   到 session/weekly/monthly 环的映射、到期时间、绝对请求数展示都已就绪。
3. 如果接口返回订阅到期时间，`PlanCardView` 的到期徽章与「订阅到期提醒」
   会自动生效，无需额外代码。
4. 若只有 Cookie 方案，参考 `KimiBrowserSession` / `LongCatBrowserSession`
   新增浏览器导入（设置页按钮 + Keychain 缓存 + `reimport…()` 接线）。
5. 更新 README/CHANGELOG，删掉 `aliyunNotActivated` 的“尚未开通”表述。

## 注意

- 不要提交任何真实 Key、Cookie 或含个人信息的响应原文（脱敏后再进 fixture）。
- `sk-sp-` Key 本身已按惯例存 Keychain（provider key `"aliyun-key"`），
  环境变量兜底名为 `ALIYUN_CODING_PLAN_API_KEY`。
