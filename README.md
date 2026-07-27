# ArkBar

[English](README.en.md) · [安全报告](SECURITY.md) · [更新日志](CHANGELOG.md)

ArkBar 是一款原生 macOS 菜单栏应用，用于查看火山方舟 Coding Plan 与 Agent Plan 的剩余用量；不会显示 Dock 图标。

## 特性

- 面向 macOS 14+ 的原生 AppKit 界面。
- 分套餐展示会话、每周和每月的**剩余**用量与重置倒计时。
- 用量越低，圆环渐变颜色越深，便于快速识别风险。
- 支持自动选择、`arkcli` SSO、Volcengine AK/SK 和 Ark API Key。
- 支持跟随系统、简体中文和 English。
- 不含遥测；不读取浏览器 Cookie、Keychain 或本地凭据文件。

## 快速开始

### 从源码运行

要求：macOS 14+、Swift 6.0，以及任一受支持的数据源。

```bash
git clone https://github.com/youwei792/ArkBar.git
cd ArkBar
swift build
.build/debug/ArkBar
```

### 打包本地应用

```bash
./Scripts/package_app.sh
```

该开发脚本仅构建 Apple Silicon（`arm64`）版本，会替换工作目录的 `ArkBar.app` 和 `/Applications/ArkBar.app`，并进行 ad-hoc 签名；它不是公证过的正式发布安装包。

### Intel 与 Universal Binary（维护者参考）

`swift build` 默认针对当前 Mac 的原生架构构建。因此，在满足 macOS 14+ 与 Swift 6.0 要求的 Intel Mac 上，直接执行“从源码运行”中的 `swift build` 会构建 `x86_64` 可执行文件，不需要 Rosetta。

当前 `Scripts/package_app.sh` 明确只生成 `arm64` 的开发用 `.app`，不能用于制作 Intel 或 Universal 安装包。源码没有已知的 `arm64` 专属依赖，但 Intel 路径尚未经过 Intel 真机或 CI 验证；这是一份构建指引，不是已发布的兼容性承诺。

要发布 Universal Binary，请在发布流程中分别产出并验证两个独立切片（`arm64` 与 `x86_64`），再使用 macOS 自带的 `lipo` 合并：

```bash
lipo -create -output ArkBar <path-to-arm64-ArkBar> <path-to-x86_64-ArkBar>
lipo -archs ArkBar
# 预期同时列出：arm64 和 x86_64（顺序无关）
```

以上命令只生成 Universal **可执行文件**。制作 Universal `.app` 时，还需要将该文件放入 `ArkBar.app/Contents/MacOS/ArkBar`、重新签名，并分别在 Apple Silicon 与 Intel Mac 上测试后再发布。不要在这一步之后运行当前的 `package_app.sh`，因为它会再次用 arm64 单切片覆盖应用内的可执行文件。

## 认证与数据源

自动模式优先使用显式设置的凭据，随后回退到 `arkcli`；菜单会显示实际成功的数据源。

| 数据源 | 配置方式 | 覆盖范围与限制 |
| --- | --- | --- |
| `arkcli` SSO（推荐） | `npm install -g @volcengine/ark-cli`，随后执行 `arkcli auth login volc-sso` | 可读取 `arkcli usage plan` 提供的个人版/团队版 Coding 与 Agent Plan 用量。 |
| Volcengine AK/SK | `VOLCENGINE_ACCESS_KEY_ID` 和 `VOLCENGINE_SECRET_ACCESS_KEY` | 仅 Coding Plan，用 Volcengine V4 签名请求读取。 |
| Ark API Key | `ARK_API_KEY`；可选 `ARK_MODEL_ID` | 仅单个请求限额窗口。探测会发送最小 API 请求，可能消耗请求额度。 |

Ark CLI 的最新安装方式请以官方 [Ark CLI 文档](https://github.com/volcengine/ark-cli) 为准。

请勿提交凭据。可在启动前设置环境变量：

```bash
export VOLCENGINE_ACCESS_KEY_ID='...'
export VOLCENGINE_SECRET_ACCESS_KEY='...'
.build/debug/ArkBar
```

## 如何理解界面

- 所有核心百分比都表示**剩余**，不是已用。
- 菜单栏胶囊显示当前 Session / 5 小时的剩余量。
- 圆环中心显示会话（或 5 小时）剩余量；每一圈也按自己的**剩余**量填充，因此 100% 会显示为满环。
- 圆环右侧依次为会话、每周、每月剩余量；每项配有自身的重置倒计时。
- 刷新失败时会保留上次确认的数据，并标记为过期数据。
- 默认仅按“设置 → 刷新 → 间隔”自动同步；可开启“点开菜单栏图标时刷新”，在每次打开角标时额外刷新。重复触发会合并为一次请求。
- 手动“刷新”会保留面板，在原位置显示“刷新中”；成功后显示“刚刚更新 / X 分钟前更新”，失败时显示原因。
- 默认跟随系统语言，可在“设置 → 语言”中修改。

## 套餐到期日

配额重置时间不等于套餐到期日。只有数据源提供经过验证的订单终止时间时，ArkBar 才显示到期徽标。当前 `arkcli usage plan` 没有提供该字段，因此应用会隐藏它，不会用重置时间或本地缓存猜测。

## 隐私

- 不读取浏览器 Cookie、Keychain 或任意文件扫描。
- `arkcli` 自己管理 SSO 会话；ArkBar 只运行 `arkcli usage plan --format json` 并解析输出。
- AK/SK 与 API Key 仅从启动环境读取，ArkBar 不会把它们写入磁盘。
- 网络请求仅发送到所选数据源需要的火山方舟接口。

## 开发与测试

```bash
swift test
```

测试覆盖 Ark CLI/OpenAPI 解码、时间格式、图标渲染和菜单卡片视觉回归。GitHub Actions 会在 pull request 和 `main` 推送时执行同一测试命令。

## 目录结构

```text
Sources/ArkBar/          应用源码
Scripts/package_app.sh   本地 Apple Silicon 打包脚本
Tests/ArkBarTests/       解码与视觉回归测试
```

## 许可证与致谢

ArkBar 使用 [MIT License](LICENSE)。部分架构和渲染思路改编自 CodexBar，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
