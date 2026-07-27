# Cairn 迹

**编码代理在你看向别处时完成工作。Cairn 在每一处完成的地方留下一颗小石头。**

一个安静的原生 macOS 伴侣,陪伴 Codex、Hermes、Claude Code 和 OpenClaw 完成
的每一轮工作。当一轮结束,Cairn 以一枚浮动便签呈现结果,而不是系统通知或又
一个争抢注意力的窗口。点击便签,它会带你回到那一轮运行时所在的终端标签页。

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

[![CI](https://github.com/quentinzhang/cairn/actions/workflows/ci.yml/badge.svg)](https://github.com/quentinzhang/cairn/actions/workflows/ci.yml)
[![Website](https://img.shields.io/badge/website-GitHub%20Pages-1A9E8A.svg)](https://quentinzhang.github.io/cairn/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-14%2B-lightgrey)

- **没有 Dock 图标,没有系统通知,不抢焦点。** Cairn 住在菜单栏,绘制自己的
  非激活面板,从不夺走你的键盘。
- **一个控件。** 一小摞三颗河石:点击展开或收起队列,拖动放到更安静的角落。
  它会记住你放的位置。
- **每个会话一枚便签。** 同一会话的新一轮更新既有便签,而不是再叠一张。最多
  保留 50 个会话,同时可见六枚。
- **按代理着色。** Codex 青绿、Hermes 紫、Claude Code 赭红、OpenClaw 蓝。
- **说你 Mac 的语言。** 跟随系统或单应用语言设置,支持英文、简体中文、日文。
- **寻迹 — 沿着来路走回去。** 点击便签回到那一轮运行的地方:精确的 Terminal
  /iTerm2 会话、宿主应用窗口;Codex 桌面版的一轮则通过
  `codex://threads/<session_id>` 精确重开那次对话。
- **完全本地。** 没有账号,没有服务器,没有遥测。唯一的网络请求是每天一次、
  或你点击**检查更新**时,查询 GitHub Releases。

Cairn 不与代理集成——**它只是读一个目录**。任何能写 JSON 文件的东西都能留下
便签,所以支持一个新的运行时不需要改动这个应用。见
[inbox 协议](docs/inbox-protocol.md)。

---

## 安装

从 [Releases](https://github.com/quentinzhang/cairn/releases/latest) 下载已公证的
`.dmg`,或自行构建:

```bash
git clone https://github.com/quentinzhang/cairn.git
cd cairn
./Scripts/build_app.sh
open dist/Cairn.app
```

需要 macOS 14+;构建需要 Xcode 16+。没有任何依赖要拉取——只用系统框架和
Python 3 / Node.js 标准库。

然后连接你在用的代理。每个安装器只向你的现有配置合并一个处理器,保留其余一
切,也可以用 `uninstall` 精确移除同一个处理器。

```bash
python3 Scripts/install_codex_hook.py install       # Codex CLI 和桌面应用
python3 Scripts/install_claude_hook.py install      # Claude Code
python3 Scripts/install_openclaw_plugin.py install  # OpenClaw
python3 Scripts/install_hermes_plugin.py            # Hermes
```

各代理须知:

- **Codex** — 在 Codex 里运行 `/hooks` 并信任新的全局 hook;Codex 不会执行
  未受信任的 hook。
- **Claude Code** — 被打断的轮次和 API 失败不会触发 `Stop`,因此不产生便签。
- **OpenClaw** — 安装器会在启用对话访问权限、以及重启受管 Gateway 之前征求
  同意;可用 `--allow-conversation-access --restart-gateway` 一次性回答。桌面版
  或非受管安装可能需要手动重启。
- **Hermes** — 覆盖 Desktop、CLI 和 Gateway 中产生最终助手输出的轮次。

在任意已连接的代理里完成一轮,便签就会出现。随时可在 Cairn 菜单里使用**检查
更新**——Cairn 从不在你不知情的情况下下载或安装更新。

## 当便签没有出现

桥接器被设计成静默失败——完成 hook 绝不能破坏它所在的代理——所以有一个
工具的全部职责就是解释这份沉默:

```bash
python3 Scripts/cairn_doctor.py        # 加 --probe 端到端追踪一条测试便签
```

对你实际安装的每个运行时,它都会指名原因和修法:hook 指向了已移动的检出目录、
插件已链接但未启用、inbox 里卡着畸形负载、第二个应用副本在偷便签。它的输出
可以安全地贴进 issue:没有便签正文,没有提示词,没有检出目录之外的绝对路径。

## 隐私

每个桥接器从完成的一轮里只提取两样东西——**最终助手消息和最近一条用户提示**
——其余全部丢弃。没有推理轨迹,没有工具调用,没有文件内容。

便签以两个明文文件存放在你的主目录,权限 `0700`,未加密——像对待 shell 历史
一样对待它们:

```
~/Library/Application Support/Cairn/inbox/            每轮一个文件,读取即删
~/Library/Application Support/Cairn/completions.json  最近 50 个会话
```

核心队列**不需要**任何 macOS 隐私权限。辅助功能与自动化是让寻迹更精确的
可选升级,在菜单栏的**访问权限**里逐应用授予;缺少权限只会降级为激活应用,
再降级为打开 Finder。完整细节,包括如何彻底移除 Cairn,见
[SECURITY.md](SECURITY.md)。

## 其他一切

对照 [`docs/inbox-protocol.md`](docs/inbox-protocol.md) 写一个生产者——CI 流水线、
长时间构建、另一个代理运行时。最短的版本只有一行:

```bash
echo "All 214 tests passed." | python3 Scripts/cairn_save.py --source ci --prompt "nightly build"
```

## 有意保存一枚便签

```bash
python3 Scripts/install_agent_skills.py install
```

为 Claude Code 和 Codex 安装 `cairn-save` 技能。让任一代理"保存到 Cairn",或
运行 `/cairn-save`,它会发布一枚刻意的结论便签,并能寻迹回保存时的位置——与
自动 Stop hook 捕获不同。

## 开发

```bash
swift build && swift test                     # 应用本体
/usr/bin/python3 Tests/protocol_roundtrip.py  # 所有桥接器,对照协议
./Scripts/build_app.sh                        # 打包 dist/Cairn.app
```

协议测试和 Swift 测试分别锁定 [`docs/inbox-protocol.md`](docs/inbox-protocol.md)
的两端;改了一端,就等着另一端报错。设计系统是承重墙——每个颜色、圆角、时长
只在 [`Sources/Cairn/DesignSystem.swift`](Sources/Cairn/DesignSystem.swift) 定义一次,
并记录于 [`docs/design-system.md`](docs/design-system.md)。有意变更品牌后,用
`./Scripts/generate_app_icon.sh` 重新生成 Finder 图标。

发布会跑全部测试、本地签名与公证、打 tag,并上传 DMG:

```bash
CAIRN_NOTARY_PROFILE="cairn-notary" ./Scripts/release.sh --version 0.7.0
```

配置与故障恢复见[发布指南](docs/releasing.md)。

## 边界

- 覆盖带受信任的用户级 hook 的 Codex CLI/桌面会话、带用户级 `Stop` hook 的
  Claude Code 会话、启用插件的 Hermes 与 OpenClaw 会话。
- 应用只收到最终结果——没有流式进度,没有工具日志。
- 本地只保留最近 50 个会话。之外没有历史,也不在机器之间同步。
- 仅支持 macOS 14+。inbox 协议可移植;这个应用不可移植。

## 贡献

欢迎 bug 报告、其他运行时的生产者、以及寻迹修复。从
[CONTRIBUTING.md](CONTRIBUTING.md) 开始,提交任何东西之前先跑 doctor。

## 许可证

Apache-2.0 — 见 [LICENSE](LICENSE)。

代码是开放的。**"Cairn" 名称、跡 字标和石头标志**不随代码授权——见
[NOTICE](NOTICE)。可以自由 fork;如果你发布修改过的构建,请换成你自己的名字和
图标,让用户能把它与官方版本区分开。把你的工具描述为与 Cairn 兼容、或实现了
Cairn inbox 协议,永远是可以的。
