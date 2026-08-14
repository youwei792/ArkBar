# TokenBar

[English](README.en.md) · [安全报告](SECURITY.md) · [更新日志](CHANGELOG.md)

TokenBar 是一款原生 macOS 菜单栏应用，用于查看火山方舟 Coding/Agent Plan、OpenCode Go、DeepSeek、APINebula 中转站、智谱（Z.ai）与 Kimi For Coding 的剩余用量；不会显示 Dock 图标。

## 特性

- 面向 macOS 14+ 的原生 AppKit 界面。
- 分套餐展示会话、每周和每月的**剩余**用量与重置倒计时。
- 用量越低，圆环渐变颜色越深，便于快速识别风险。
- 支持自动选择、`arkcli` SSO、Volcengine AK/SK 和 Ark API Key。
- DeepSeek 监控（余额、今日/每月费用、Token 用量、请求次数、缓存命中/未命中/输出分类），余额圆环 = 本月已用 ÷ (本月已用 + 余额)，充值后随刷新自动更新。
- DeepSeek 凭据支持三种来源：设置页填写（存入 Keychain）、环境变量，以及**自动读取 Chrome 中已登录的 DeepSeek 平台会话**（无需任何 Key）。
- APINebula（new-api 中转站）监控：余额圆环 = 累计已用 ÷ (累计已用 + 余额)，今日/每月费用、Token、请求次数，以及**缓存读/未缓存/输出**分类（来自控制台使用日志）。
- APINebula 余额与日志是控制台接口：凭据来自浏览器登录会话（设置页显式导入并缓存到 Keychain），可选 API Key 兜底。
- 支持在 Ark、OpenCode Go、DeepSeek、APINebula、智谱（Z.ai）与 Kimi 之间即时切换，并隔离各边的刷新状态与错误。
- **概览**标签一览所有可见 Provider 的剩余百分比与胶囊进度条；点击某行进入对应完整卡片。可在「设置 → 通用」开关。
- 每个 Provider 可在自己的设置页中独立**显示/隐藏**，隐藏后从切换器移除并停止后台刷新。
- 菜单栏样式可选：进度条、进度条 + 百分比、仅百分比、仅 Logo、Logo + 百分比、Logo + 进度条；Logo 16pt、百分比使用系统字号，与 CodexBar 对齐。
- 支持跟随系统、简体中文和 English。
- 不含遥测；OpenCode/APINebula 浏览器接入只在用户明确操作时读取认证 Cookie。会话与 API Key 写入本机 Keychain，并镜像到应用支持目录下的凭据文件缓存，常规重启不弹钥匙串。

## 快速开始

### 从源码运行

要求：macOS 14+、Swift 6.0，以及任一受支持的数据源。

```bash
git clone https://github.com/youwei792/TokenBar.git
cd TokenBar
swift build
.build/debug/TokenBar
```

### 打包本地应用

```bash
./Scripts/package_app.sh
```

该开发脚本仅构建 Apple Silicon（`arm64`）版本，会替换工作目录的 `TokenBar.app` 和 `/Applications/TokenBar.app`，并进行 ad-hoc 签名；它不是公证过的正式发布安装包。

### Intel 与 Universal Binary（维护者参考）

`swift build` 默认针对当前 Mac 的原生架构构建。因此，在满足 macOS 14+ 与 Swift 6.0 要求的 Intel Mac 上，直接执行“从源码运行”中的 `swift build` 会构建 `x86_64` 可执行文件，不需要 Rosetta。

当前 `Scripts/package_app.sh` 明确只生成 `arm64` 的开发用 `.app`，不能用于制作 Intel 或 Universal 安装包。源码没有已知的 `arm64` 专属依赖，但 Intel 路径尚未经过 Intel 真机或 CI 验证；这是一份构建指引，不是已发布的兼容性承诺。

要发布 Universal Binary，请在发布流程中分别产出并验证两个独立切片（`arm64` 与 `x86_64`），再使用 macOS 自带的 `lipo` 合并：

```bash
lipo -create -output TokenBar <path-to-arm64-TokenBar> <path-to-x86_64-TokenBar>
lipo -archs TokenBar
# 预期同时列出：arm64 和 x86_64（顺序无关）
```

以上命令只生成 Universal **可执行文件**。制作 Universal `.app` 时，还需要将该文件放入 `TokenBar.app/Contents/MacOS/TokenBar`、重新签名，并分别在 Apple Silicon 与 Intel Mac 上测试后再发布。不要在这一步之后运行当前的 `package_app.sh`，因为它会再次用 arm64 单切片覆盖应用内的可执行文件。

## 认证与数据源

自动模式优先使用显式设置的凭据，随后回退到 `arkcli`；菜单会显示实际成功的数据源。

| 数据源 | 配置方式 | 覆盖范围与限制 |
| --- | --- | --- |
| `arkcli` SSO（推荐） | `npm install -g @volcengine/ark-cli`，随后执行 `arkcli auth login volc-sso` | 可读取 `arkcli usage plan` 提供的个人版/团队版 Coding 与 Agent Plan 用量。 |
| Volcengine AK/SK | `VOLCENGINE_ACCESS_KEY_ID` 和 `VOLCENGINE_SECRET_ACCESS_KEY` | 仅 Coding Plan，用 Volcengine V4 签名请求读取。 |
| Ark API Key | `ARK_API_KEY`；可选 `ARK_MODEL_ID` | 仅单个请求限额窗口。探测会发送最小 API 请求，可能消耗请求额度。 |
| OpenCode Go | 在“设置 → OpenCode Go”中明确点击“重新读取浏览器登录”，或选择手动 Cookie | 从 `opencode.ai` 的订阅页面读取其返回的套餐用量；不会用本地消费记录估算余额。 |
| DeepSeek | 三选一：设置页填写 API Key / Platform Token（存 Keychain）、环境变量 `DEEPSEEK_API_KEY` / `DEEPSEEK_PLATFORM_TOKEN`，或让 Chrome 登录 platform.deepseek.com 后自动读取 | 余额来自 `api.deepseek.com/user/balance`（或平台钱包）；今日/每月费用、Token、请求次数与分类明细来自平台 `usage/amount` + `usage/cost`。凭据优先级：设置值 > 环境变量 > Chrome 会话。 |
| APINebula（中转站） | 在“设置 → APINebula 中转”中显式点击“重新读取浏览器登录”（控制台会话缓存到 Keychain）；可选填 API Key | 余额/累计已用来自控制台 `api/user/self`；今日/每月费用、Token、请求次数与缓存读/未缓存/输出分类来自 `api/log/self` 使用日志（缓存 token 位于日志 `other` 字段）。余额与日志是控制台接口，API Key 仅保证 `/v1` 模型调用。 |
| 智谱（Z.ai） | 在“设置 → 智谱 Coding Plan”中填写 API Key（存 Keychain + 文件缓存）；可选环境变量 `Z_AI_API_KEY` 兜底；API 区域可选 Global（`api.z.ai`）或 BigModel 国内站（`open.bigmodel.cn`），默认国内站 | 读取 `api/monitor/usage/quota/limit` 返回的 Coding Plan 额度窗口：5 小时 + 每周（session/weekly 环），部分套餐另有每月 MCP 时间窗口（monthly 环）。凭据优先级：设置值 > 环境变量。 |
| Kimi For Coding | 在“设置 → Kimi For Coding”中填写 API Key（存 Keychain + 文件缓存）；可选环境变量 `KIMI_CODE_API_KEY` 兜底 | 读取 `api.kimi.com/coding/v1/usages` 返回的会员配额：总配额（每周，weekly 环）+ 5 小时限流窗口（session 环）。凭据优先级：设置值 > 环境变量。 |

Ark CLI 的最新安装方式请以官方 [Ark CLI 文档](https://github.com/volcengine/ark-cli) 为准。

请勿提交凭据。可在启动前设置环境变量：

```bash
export VOLCENGINE_ACCESS_KEY_ID='...'
export VOLCENGINE_SECRET_ACCESS_KEY='...'
export Z_AI_API_KEY='...'
export KIMI_CODE_API_KEY='...'
.build/debug/TokenBar
```

## 如何理解界面

- 所有核心百分比都表示**剩余**，不是已用。
- 菜单栏胶囊显示当前所选标签的 Session / 5 小时剩余量；在**概览**模式下显示所有可见 Provider 中剩余最低（最紧急）的那一侧。显示样式可在“设置 → 外观 → 显示模式”中选择进度条、百分比与 Provider Logo 的组合。
- 切换器最前为可选的「概览」；Provider 较多时切换器自动收成仅图标（完整名称在 tooltip）。
- 圆环中心显示会话（或 5 小时）剩余量；每一圈也按自己的**剩余**量填充，因此 100% 会显示为满环。
- 圆环右侧依次为会话、每周、每月剩余量；每项配有自身的重置倒计时。
- DeepSeek 标签页使用单个余额圆环：已用比例 = 本月费用 ÷ (本月费用 + 余额)，充值后余额增加，圆环在下次刷新时自动重算；圆环下方显示缓存命中/未命中/输出分类明细与常用模型。
- APINebula 标签页使用单个余额圆环：已用比例 = 累计已用 ÷ (累计已用 + 余额)；圆环下方显示缓存读/未缓存/输出分类明细与常用模型。
- 智谱（Z.ai）标签页显示 Coding Plan 额度圆环：5 小时窗口对应 session 环、每周窗口对应 weekly 环（部分套餐另有每月 MCP 时间窗口对应 monthly 环）；圆环与图例均按**剩余**填充。
- Kimi For Coding 标签页显示会员配额圆环：总配额（每周）对应 weekly 环、5 小时限流窗口对应 session 环；圆环与图例均按**剩余**填充。
- 刷新失败时会保留上次确认的数据，并标记为过期数据。
- 默认仅按“设置 → 刷新 → 间隔”自动同步；可开启“点开菜单栏图标时刷新”，在每次打开角标时额外刷新。重复触发会合并为一次请求。
- 手动“刷新”会保留面板，在原位置显示“刷新中”；成功后显示“刚刚更新 / X 分钟前更新”，失败时显示原因。
- 默认跟随系统语言，可在“设置 → 语言”中修改。

## 套餐到期日

配额重置时间不等于套餐到期日。只有数据源提供经过验证的订单终止时间时，TokenBar 才显示到期徽标。当前 `arkcli usage plan` 没有提供该字段，因此应用会隐藏它，不会用重置时间或本地缓存猜测。

## 隐私

- OpenCode 自动接入只会在用户点击“重新读取浏览器登录”后读取 `opencode.ai` 的认证 Cookie；不读取浏览历史，也不会扫描任意文件。
- TokenBar 只保留 `auth` / `__Host-auth` 认证项，并存入本机 macOS Keychain，同时镜像到 `~/Library/Application Support/TokenBar/credentials.json`（权限 0600）；常规启动、定时刷新和手动刷新优先读文件缓存，不反复触碰钥匙串或浏览器。
- 手动粘贴的 OpenCode Cookie 同样只保存在本机 Keychain + 文件缓存，不会写入 UserDefaults、源码或日志。
- DeepSeek 自动接入会在没有 Keychain/环境变量凭据时静默读取 Chrome 中 `platform.deepseek.com` 的 `userToken`（浏览器 localStorage 明文条目），仅用于调用 DeepSeek 平台接口；TokenBar 不会把它写入磁盘。结果按浏览器来源标签在设置页展示。
- APINebula 浏览器接入只在用户点击“重新读取浏览器登录”后读取 `apinebula.ai` 控制台的会话 Cookie（及 localStorage 中的账户 ID），仅用于调用余额/日志接口，并写入 Keychain + 文件缓存。
- 浏览器会话导入（OpenCode/APINebula）是显式设置操作；后台与启动刷新永不读取浏览器 cookie 库，也不会因 ad-hoc 重签而反复弹出钥匙串密码框。
- 在 DeepSeek 设置页填写的 API Key / Platform Token 只保存在本机 Keychain + 文件缓存，不会写入 UserDefaults、源码或日志。
- 在智谱设置页填写的 API Key 同样只保存在本机 Keychain + 文件缓存，不会写入 UserDefaults、源码或日志；区域偏好仅存 UserDefaults，不含任何凭据。
- 在 Kimi For Coding 设置页填写的 API Key 同样只保存在本机 Keychain + 文件缓存，不会写入 UserDefaults、源码或日志。
- `arkcli` 自己管理 SSO 会话；TokenBar 只运行 `arkcli usage plan --format json` 并解析输出。
- AK/SK 与 Ark API Key 仅从启动环境读取，TokenBar 不会把它们写入磁盘。
- 网络请求仅发送到所选数据源需要的火山方舟接口、`opencode.ai`、`platform.deepseek.com`、智谱配额接口（`open.bigmodel.cn` / `api.z.ai`）或 Kimi 配额接口（`api.kimi.com`）。

## 开发与测试

```bash
swift test
```

测试覆盖 Ark CLI/OpenAPI/OpenCode Go/DeepSeek/智谱/Kimi 解码、DeepSeek 余额与用量聚合、浏览器会话 token 提取、时间格式、图标渲染、刷新交互和菜单卡片视觉回归。GitHub Actions 会在 pull request 和 `main` 推送时执行同一测试命令。

## 目录结构

```text
Sources/TokenBar/          应用源码（含 DeepSeek/APINebula/Zai/Kimi Provider、浏览器会话导入、概览 SummaryRow、CredentialFileCache、单环卡片、ProviderLogo 与 Resources/provider 图标）
Scripts/package_app.sh   本地 Apple Silicon 打包脚本
Tests/TokenBarTests/       解码与视觉回归测试
```

## 许可证与致谢

TokenBar 使用 [MIT License](LICENSE)。CodexBar 与 SweetCookieKit 的相关许可详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
