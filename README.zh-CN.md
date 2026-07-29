<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/cairn-mark-dark.svg">
  <img src="docs/assets/cairn-mark.svg" width="72" alt="">
</picture>

# Cairn

**让每一次任务都有迹可循。**

编码代理在你看向别处时完成工作，<br>
Cairn 在每一处完成的地方留下一枚便签——点开它，就能原路返回。

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

[![CI](https://github.com/quentinzhang/cairn/actions/workflows/ci.yml/badge.svg)](https://github.com/quentinzhang/cairn/actions/workflows/ci.yml)
[![Website](https://img.shields.io/badge/website-GitHub%20Pages-1A9E8A.svg)](https://quentinzhang.github.io/cairn/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-14%2B-lightgrey)
![Architecture](https://img.shields.io/badge/architecture-Apple%20Silicon-lightgrey)

### [⬇︎ 下载 macOS 版](https://github.com/quentinzhang/cairn/releases/latest)

</div>

---

## 普通用户

### 它做什么

当你的编码代理——比如 **Codex** 或 **Claude Code**——完成一轮工作，一枚便签就会栖在桌面上那一小摞三颗河石旁边。

- **从不打断。** 没有 Dock 图标，没有系统通知，没有争抢键盘的窗口。Cairn 只是告诉你有事完成了，从不要求你回应。
- **一切都能堆叠。** 每个会话一枚便签，按代理着色，同一代理在同一项目下的便签归为一摞。最多记住 50 个会话。
- **会寻迹。** 点开便签，Cairn 带你回到那一轮运行的地方——精确的 Terminal / iTerm2 标签页、宿主应用窗口，或 Codex 里的那次对话本身。
- **只属于你。** 没有账号，没有服务器，没有遥测。一切都留在这台 Mac 上。

### 安装

1. 从 [Releases](https://github.com/quentinzhang/cairn/releases/latest) 下载已公证的 `.dmg`，把 **Cairn** 拖进"应用程序"。
2. 打开它。首次启动时，Cairn 会检测这台 Mac 上已安装的编码代理并列出来——目前支持 **Codex**、**Claude Code**、**OpenClaw**、**OpenCode** 和 **Hermes**。
3. 在你在用的每一个上点**连接**，然后点**开始使用 Cairn**。

设置到此为止——**不用终端，不用运行脚本，不用改任何配置文件。** 连接会为该代理安装一项 Cairn 接入，并保留无关设置；**断开**只移除 Cairn 自己的接入。标着*需要处理*的那一行，点同一个按钮即是修复。之后随时可以从 Cairn 菜单里的**应用**重新打开这个窗口。

需要搭载 Apple Silicon 的 Mac，并运行 macOS 14 或更高版本。

有几个代理还需要它们自己的一步，Cairn 会在你连接后直接写在那一行里：

| 代理 | 连接之后 |
| --- | --- |
| **Codex** | 在 Codex 里运行一次 `/hooks` 并信任 Cairn 的处理器——未受信任的 hook，Codex 不会执行。 |
| **Claude Code** | 无需额外操作。（被打断的轮次和 API 失败不会触发 `Stop`，因此不产生便签。） |
| **OpenClaw** | Cairn 会询问一次是否允许读取最终消息，然后自动帮你重启受管 Gateway。 |
| **OpenCode** | 如果 OpenCode 已在运行，重启它。 |
| **Hermes** | 如果 Hermes 已在运行，重启它。 |

### 日常使用

- **石堆**待在桌面上：点击展开或收起队列，拖动放到更安静的角落。它记得你放的位置。
- **⌃⌥⌘C** 在任何应用里显示或隐藏便签——这是默认快捷键，可在设置里改成你的。
- **点开便签**会沿着来路走回去。
- **便签自成秩序**——按代理着色，并按代理、按项目堆成一摞。

### 使用边界

- Cairn 只接收最终结果，不接收流式进度或工具日志。
- 本地只保留最近 50 个会话；更早的内容不会保留，也不会在不同机器之间同步。
- 仅支持搭载 Apple Silicon、运行 macOS 14 或更高版本的 Mac。

## 从源码开发

以下命令都从仓库根目录运行，不依赖已安装 Cairn 内部的脚本。

每个命令、运行时 hook、安装器、共享模块与发布工具的用途，见[完整 Scripts 参考](Scripts/README.md)。

### 构建并运行

```bash
git clone https://github.com/quentinzhang/cairn.git && cd cairn
swift build && swift test                     # 编译并测试 Swift 可执行目标
/usr/bin/python3 Tests/protocol_roundtrip.py  # 对照协议测试所有桥接器
./Scripts/build_app.sh                        # 组装并签名 dist/Cairn.app
open dist/Cairn.app                           # 运行完整的本地 App
```

构建需要 Xcode 16+。没有任何依赖要拉取——只使用系统框架和 Python 3 / Node.js 标准库。

`swift build` 只会在 `.build/` 下生成 Swift 可执行文件和 SwiftPM 资源，不会组装 macOS App。`Scripts/build_app.sh` 会执行 release 构建，把所有桥接器和运行时插件——包括 OpenCode——复制进 `dist/Cairn.app`，再加入 App 资源、entitlements 并签名。

### 诊断便签未出现

桥接器被设计成静默失败——完成 hook 绝不能破坏它所在的代理——所以源码里有一个工具专门解释这份沉默：

```bash
python3 Scripts/cairn_doctor.py
```

对实际安装的每个运行时，它都会指名原因和修法：hook 指向已经移动的位置、插件已链接但未启用、inbox 里卡着畸形负载、第二个应用副本在偷便签。加 `--probe` 可以端到端追踪一条测试便签。输出不包含便签正文或提示词，并把主目录缩写为 `~`；贴到 issue 前，仍请检查其中为诊断保留的 App 与 checkout 路径。

### 隐私与存储实现

每个桥接器从完成的一轮里只保留两样东西——**最终助手消息和最近一条用户提示**——其余全部丢弃。没有推理轨迹，没有工具调用，没有文件内容。

便签以明文形式存放在你的主目录——像对待 shell 历史一样对待它们：

```
~/Library/Application Support/Cairn/inbox/            每轮一个文件，读取即删
~/Library/Application Support/Cairn/completions.json  最近 50 个会话
```

队列本身**不需要**任何 macOS 隐私权限。辅助功能与自动化是让寻迹更精确的可选升级，在**权限**里逐个应用授予；没有它们，点击只会降级为激活应用，再降级为打开 Finder。唯一的网络请求是每天一次查询 GitHub Releases。完整细节，包括如何彻底移除，见 [SECURITY.md](SECURITY.md)。

### 扩展 inbox 协议

Cairn 不与代理集成——**它只是读一个目录**。CI 流水线、一次长时间构建或另一个代理运行时，都可以对照 [`docs/inbox-protocol.md`](docs/inbox-protocol.md) 编写生产者。源码目录下最短的示例只有一行：

```bash
echo "Build completed successfully." | python3 Scripts/cairn_save.py \
  --source ci --prompt "nightly build"
```

### 连接脚本与主动保存

连接窗口执行的所有操作都可以直接从 checkout 调用：

```bash
python3 Scripts/cairn_connect.py status              # 检测到什么、连上了什么
python3 Scripts/cairn_connect.py connect claude      # codex · claude · openclaw · opencode · hermes · skills
python3 Scripts/cairn_connect.py disconnect claude
```

`skills` 是唯一没有按钮的目标，因为它是 Cairn 的功能而不是一个要连接的代理：它为 Claude Code 和 Codex 安装 `cairn-save` 技能。让任一代理"保存到 Cairn"，或运行 `/cairn-save`，它就会发布一枚刻意的结论便签，并能寻迹回保存时的位置——与一轮结束时的自动捕获不同。

原来那些单独的安装器（`install_*.py`）依然存在、依然可用；`cairn_connect.py` 正是驱动它们的那一层。

### 首次运行、设计与发布

首次运行的流程只会发生一次，因此最难测试。`python3 Scripts/cairn_reset.py` 把它整个走回去——断开所有代理，清空队列、偏好设置与隐私授权，但保留应用本身——下次启动就又是第一次启动。它默认只打印计划、不做任何改动，加 `--yes` 才执行；`--keep-permissions` 可保留授权。

协议测试和 Swift 测试分别锁定 [`docs/inbox-protocol.md`](docs/inbox-protocol.md) 的两端；改了一端，就等着另一端报错。设计系统是承重墙——每个颜色、圆角、时长只在 [`Sources/Cairn/DesignSystem.swift`](Sources/Cairn/DesignSystem.swift) 定义一次，并记录于 [`docs/design-system.md`](docs/design-system.md)。有意变更品牌后，用 `./Scripts/generate_app_icon.sh` 重新生成 Finder 图标。

发布会跑全部测试、本地签名与公证、打 tag，并上传 DMG：

```bash
CAIRN_NOTARY_PROFILE="cairn-notary" ./Scripts/release.sh --version 0.7.0
```

配置与故障恢复见[发布指南](docs/releasing.md)。

## 贡献

欢迎 bug 报告、其他运行时的生产者、以及寻迹修复。从 [CONTRIBUTING.md](CONTRIBUTING.md) 开始，提交任何东西之前先跑 doctor。

## 许可证

Apache-2.0 — 见 [LICENSE](LICENSE)。第三方组件保留各自的许可证，详见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

代码是开放的。**"Cairn" 名称、跡 字标和石头标志**不随代码授权——见 [NOTICE](NOTICE)。
