# 方案：让阿里云百炼「浏览器登录」真正可用（数据获取收尾）

> 状态：**已执行完毕（2026-09-25）**，4 项偏差全部修复，228 测试全绿，
> 其中监听改动的 4 个真实 socket 用例通过；**只剩 §3 第 3 步「真人登录一次」待验证**。
> 决策记录见文末 §4。
> 结论先说：上一轮的接入是**契约正确**的，但**浏览器登录在这台 Mac 上根本无法启动**，
> 所以数据获取从未真正跑通。本文给出根因、修复项与验收方式。

## 1. 根因（已实测复现，非推测）

`/tmp/tokenbar-run.log` 里 09:36 的 4 次失败：

```
✗ 阿里云: console login failed: 阿里云控制台浏览器登录失败。
  （Network.NWError error 22 - Invalid argument）
```

用独立最小复现程序验证（同一台机器、同一网络环境）：

| 试验 | 结果 |
| --- | --- |
| `NWListener(using: .tcp)`（现写法） | `failed POSIXErrorCode(rawValue: 22) Invalid argument` |
| 指定固定端口 8899 | 同样 EINVAL |
| `requiredInterfaceType = .loopback` | 同样 EINVAL |
| `acceptLocalOnly = true` | 同样 EINVAL |
| `NWListener(using: .udp)` | 同样 EINVAL |
| **原生 BSD socket `bind(127.0.0.1:0)` + `listen`** | **成功，且 curl 打通完整 HTTP 往返** |

即：**只要监听就失败**，与参数无关；而原生 loopback socket 完全正常。
环境侧的原因是本机装有 **Proton VPN 的 WireGuard 网络扩展**（`systemextensionsctl list` 显示
`ch.protonvpn.mac.WireGuard-Extension [activated enabled]`，另有 9 个 utun 接口）——
Network.framework 的 listener 路径在该环境下不可用。用户日常挂着 VPN，
所以这不是偶发故障，而是「这个功能在用户机器上永远不可用」。

顺带发现一个潜在缺陷：`run()` 里 `readyPort(of:)` 已经 `start()` 过，
`run()` 又对同一个 listener 再 `start()` 一次（重复启动本身是非法状态）。
换成 socket 实现后该问题自然消失。

## 2. 与官方 CLI 逐条对拍的结果

契约来源仍是 `github.com/modelstudioai/cli`（本次重新拉取了
`auth/login-console.ts`、`shared/local-server.ts`、`usage/token-plan.ts`、
`usage/coding-plan.ts`、`core/console/gateway.ts`、`core/console/models.ts`、
`core/auth/refresh-token.ts` 逐一核对）。

**已核对一致（不改）**：登录 URL（含 `notice` 里字面的 `?`）、`state` 校验与 400 行为、
OPTIONS/CORS、回调体解析（query / urlencoded / JSON / `data` 嵌套）、64KB body 上限、
网关 URL 与 `params`/`region` 表单体、URLSearchParams 编码规则、`data.success==false`
错误信封、`unwrapResponse` 的 `data → DataV2 → data → data` 展开、Token Plan 比例区间
[0,1] 与 epoch 毫秒、AK/SK 换票的 action/version/host/`cliAccessToken` 字段。

**发现 4 处偏差，需要修**：

| # | 偏差 | 影响 | 修法 |
| --- | --- | --- | --- |
| 1 | 监听用 `NWListener` | 浏览器登录 100% 失败（本次阻塞点） | 改为绑定 `127.0.0.1:0` 的原生 socket + 独立 accept 线程；顺带比 `NWListener` 更严格（官方 `listenLocalServer` 也是 loopback-only + exclusive） |
| 2 | Token Plan 的 `Data` 是空对象，缺 `cornerstoneParam` | 官方 `buildGatewayParams()` 对**每次**调用都注入 `cornerstoneParam`，与套餐无关 | 让 Token Plan 调用带同一份 `cornerstoneParam`（`productCode=p_efm` 等），与 Coding Plan 对齐 |
| 3 | 收到 `state` 正确但**没有 token** 的请求 → 立即整体失败 | 控制台页面可能先发探测请求（无 token），会被误判为登录失败 | 对齐官方：仍回 200 并**继续等待**，最终由 10 分钟超时兜底；删除随之无用的 `.missingToken` 分支 |
| 4 | 文档与注释声称支持 multipart，代码里**没有** multipart 分支 | 若控制台用 `FormData` 提交（官方专门为此写了 `parseAccessTokenFromMultipart`），token 取不出来 | 补 multipart 解析（按 boundary 切段、匹配 `name="access_token"`），并加测试 |

偏差 2、3、4 都属于「登录修好后仍然可能读不到数据」的隐患，因此建议一次性做完。

## 3. 验收

1. `swift build` 0 warning、`swift test` 全绿（新增 socket 级用例：真实连接打通 GET/POST/
   multipart/state 不符/无 token 继续等）。测试只连本机 127.0.0.1，不发外网请求。
2. **模拟回调**端到端：起 app → 触发登录 → 用 curl 按官方信封把 token 回调到本地端口 →
   期望日志 `✓ 阿里云: console login succeeded`，Keychain 落 `aliyun-console`，
   随后自动刷新。
3. **真人登录**（唯一需要用户操作）：设置 → 阿里云百炼 → 浏览器登录 → 在浏览器完成登录，
   期望菜单栏出现 Token Plan 两环或 Coding Plan 三档。
   （注：09:35 那次 `Bad Request` 来自被网关拒绝的 `sk-sp-` key，**不能**当作
   `cornerstoneParam` 缺失的证据；偏差 2 只是与官方契约对齐，真正原因要等真人登录后的
   第一次成功查询才能判断。）

## 4. 决策与执行结果

- **D1 修复范围** → 用户选定「**全做 4 项**」。执行结果：
  1. `AliyunConsoleLogin.CallbackServer`：loopback-only 原生 socket + `DispatchSource`
     读事件；取消 source 是唯一的关 fd 处（超时/成功/`stop()` 都走 cancel handler），
     顺带消除了旧代码对同一 listener 调两次 `start()` 的非法转换；
  2. `cornerstoneParam` 移入 `AliyunConsoleAPI.gatewayCall`，两种套餐调用都会带上；
  3. state 正确但无 token → 回 200 继续等待，`LoginError.stateMismatch` /
     `.missingToken` 及其两条文案删除（已不可达）；
  4. `CallbackRequest` 补 `multipart/form-data` 解析；`parse` 改为按头部终止符
     做字节级切分，不再「按行拆分再拼回」重建 body。
- **D2 验证方式** → 用户选定「**先模拟回调，再请用户登录一次**」。
  模拟回调以**真实 socket 测试**落地（比人工 curl 更可重放）：真连接投递 token、
  伪 state 回 400 且继续等待、无 token 回 200 且继续等待、POST 表单投递、
  超时后端口确实释放。真人登录仍待用户执行（本文 §3 第 3 步 / aliyun-handoff §7）。
- README 无需改动：对外描述仍是「本地起端口接收回调」，本次只换实现。
- 测试计数：阿里云 31 → 40（+5 socket、+3 网关 body、+1 multipart），全量 219 → 228。

## 5. 真机登录后的第二轮结论（2026-09-25 深夜，用户实际登录后）

第一轮修完监听，登录确实通了（日志三次 `✓ 阿里云: console login succeeded`），但数据仍然出不来。
用登录态浏览器直接向 `/data/api.json` 重放同一个 `params` 体，拿到了**真实响应**，据此定位四处：

| 现象 | 真实原因 | 处理 |
| --- | --- | --- |
| 页面停在「授权中」，但令牌其实已到手 | 成功响应缺 `Access-Control-Allow-Origin: *`，跨域 `fetch` 读不到响应 → 页面判失败 | 所有回调响应统一带 CORS 头；重复点击改为取消上一次尝试（及时释放端口、不记失败日志） |
| 报「未找到有效的 Token Plan 或 Coding Plan 订阅」 | 个人版 **Essential** 的用量响应只有 `per1MonthPercentage` + `per1MonthResetTime`；官方 CLI 只打印 5 小时/每周两档，TokenBar 照抄 → 三档全无 → 误判为未订阅 | `parseTokenPlan` 增加月度档；缺哪档不显示哪档；用真实响应做固定向量测试 |
| 卡片没有到期日/倒计时 | 用量接口根本不含日期；到期日与套餐档位在**订阅记录**接口里（控制台同页会调） | 新增 `v2/subscription` 调用，取 `endTime` → 到期日、`specCode` → `Essential` 徽标；该调用失败只降级不报错 |
| 错误细节丢失 | 真机信封用 `errorMsg`，代码只读 `errorMessage` | 两个字段都认；两接口都"无数据"时把**两份原始响应**写进诊断文件 |
| 资源复核：登录后端口一直占着 | cancel handler 用 `weak self` 关 fd，而它在下一个队列轮次才跑——那时 server 已释放 → 关不掉 → 端口留在 `LISTEN` 且无人 accept（实测 7 小时后仍在，TCP 能连上但永不响应） | handler 改为**按值捕获 fd**；四条测试分别钉住成功/取消/超时/未 serve 四种结束方式后端口都已释放 |

顺带修掉的测试隐患：`browserTokenUsed` / `expiredBrowserTokenFallsBack` 会往共享 `AppSettings`
写假令牌并在退出时**无条件清空**，等于跑一次测试就把真机登录状态打掉；改为保存/还原。

**仍未解决、属于产品事实的一件事**：浏览器登录换来的 console 令牌只有几分钟寿命
（22:48:51 拿到 → 22:52:20 已 `Login.NotLogined`），而默认 5 分钟刷新一次，
所以纯浏览器登录必然周期性变红。官方 CLI 同样如此，它靠 AK/SK 续票。
要无人值守稳定出数，只能配 AK/SK（只读子账号 + `modelstudio:GenerateCLIAccessToken`）。
