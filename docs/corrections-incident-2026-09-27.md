# 事故报告：安全修复部署时误装陈旧二进制（2026-09-27）

> 状态：**已恢复**。正确版本已部署到 `/Applications/TokenBar.app` 并重启，
> OpenCode 数据恢复正常，`swift test` 233 测试全绿。
> 本文记录根因（已实测验证，非推测）、排查过程与预防措施。

## 1. 背景

代码审查提出 5 项优先修复（H1/H2/M1/M2/M4-M5），全部落地：

| # | 修复 | 文件 |
|---|------|------|
| H1 | 回调服务器 CORS `*` 改为仅允许百炼控制台 Origin | `AliyunConsoleLogin.swift` |
| H2 | 失败重试加入指数退避（1s→2s→…→60s 上限） | `UsageStore.swift` |
| M4/M5 | LongCat/StepFun/Nebula cookie 过滤改白名单 | 3 个 `*BrowserSession.swift` |
| M1 | Keychain 条目添加 `SecAccess` ACL | `CookieKeychainStore.swift` |
| M2 | 凭证文件缓存加 `.completeFileProtection` | `CredentialFileCache.swift` |

相关测试已同步更新（白名单断言、CORS Origin 断言＋新增外域拒绝用例）。

## 2. 事故现象

部署并重启后，用户报告 OpenCode 数据获取不到，设置里“重新读取浏览器登录”导入失败，
而部署前一切正常。

## 3. 根因（已验证）

**部署时拷错了二进制文件**——与 5 项修复本身无关：

1. `swift build -c release` 的产物目录是 `.build/out/Products/Release/`，
   可用 `swift build -c release --show-bin-path` 确认；
2. 排查时用的 `find .build -name TokenBar -path "*release*"` 命中了
   `.build/arm64-apple-macosx/release/TokenBar`——那是 **2026-09-15 的陈旧构建**，
   早于 OpenCode 控制台 API 迁移（09-21），走的已下线老接口；
3. 该旧二进制被 `cp` 覆盖到 `/Applications/TokenBar.app`，导致回归。

验证证据：

- `strings 旧二进制 | grep TOKENBAR_QA_REIMPORT_OPENCODE` → 0 条
 （QA 钩子是老代码，正常构建必然包含；缺失即证明版本不对）；
- 旧二进制 mtime 为 09-15，新构建产物 `.build/out/Products/Release/TokenBar`
  mtime 为 09-26 23:47 且包含 QA 字符串与白名单字符串（`sankuai_strategy`）；
- 换上正确二进制 + `TOKENBAR_QA_REIMPORT_OPENCODE=1` 启动后，诊断文件更新：
  `import browser=Chrome Profile 3 … cookies=__Host-console_session,…`，
  随后 `✓ OpenCode Go: 1 plan(s)`——导入与获取链路本身正常。

## 4. 恢复步骤（已执行）

1. `cp .build/out/Products/Release/TokenBar /Applications/TokenBar.app/Contents/MacOS/TokenBar`
2. `pkill -x TokenBar && open /Applications/TokenBar.app`
3. 确认进程存活、OpenCode 显示 1 plan，其余 provider（智谱/Kimi/阿里云/商汤/阶跃/DeepSeek）均 ✓。

## 5. 预防措施

部署前必须校验二进制新鲜度，二选一：

```sh
# 唯一可信的产物路径
swift build -c release --show-bin-path
# 或校验：mtime 应为本次构建时间，且包含本次改动的标记字符串
strings <binary> | grep <本次改动的唯一字符串>
```

禁止用宽泛 `find … -path "*release*"` 定位产物——`.build` 下存在新旧两套布局
（`arm64-apple-macosx/` 为残留旧布局，`out/Products/` 为当前布局）。
