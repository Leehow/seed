# seed

**一个 coding agent，整个就是一份 POSIX `/bin/sh` 文件。**

[English README](README.md)

仓库根上的 [`seed.sh`](seed.sh) 同时是**唯一产品、唯一运行时、唯一源码**。没有生成步骤，没有 build/pack 双轨，也不会再安装出 `bin/agent`。运行只需要 `/bin/sh`、curl 和 jq；缺 jq 时种子会自己下载兼容二进制。

支持 Linux、macOS、WSL、Git Bash、Android Termux；不支持原生 cmd / PowerShell。

```sh
curl -fsSL https://raw.githubusercontent.com/Leehow/seed/main/seed.sh -o seed.sh
cd 你的项目
/bin/sh seed.sh deepseek sk-你的key
```

安装到此为止。没有 Node，没有 Python 运行时，没有安装器，没有容器。在一台只有 curl 的裸 Debian 上，种子自己拉 jq、初始化、写出第一个文件，总共 **15 秒**。

---

## 这个仓库在问什么

主流 coding agent 都是 Node 或 Python 应用，带一整个工具动物园：read、grep、glob、todo、子代理、规划器。seed 问一个刻意收窄的问题：

> **只用 POSIX `/bin/sh` + curl + jq，能不能撑住一个带工具的 coding agent——包括 SSE 流式、持久 shell 和精确替换编辑？**

目前的答案：能，而且这个约束本身成了特性。一份可移植的文件意味着零安装摩擦、行为可审计（你可以通读你的整个 agent），以及一个能把自己带上任何有 shell 的机器的 agent——包括一台安卓平板。

## 设计原则

- **一个文件就是全部。** 下载 `seed.sh`，喂任意 OpenAI 兼容接口和 key，它就是完整 agent。这份文件同时是它自己的文档：agent 做的几乎每件事都是可读的 shell。
- **外壳拥有循环，模型拥有判断。** 主循环、SSE 流、错误处理、轮数控制在 shell 里；看什么、改什么、什么时候结束由模型决定。不让模型每轮另写 controller。
- **API 工具只有两个。** 持久 `shell`（`cd` 和环境变量跨调用保留）和精确替换 `edit`（匹配 0 次或多次都失败、文件不动）。不加 read/grep/glob/todo——那些都是 shell 里的普通命令。「只有两个工具」不等于「只能做两件事」：机器上有的一切都够得着。
- **先找、验证、登记、复用，找不到才造。** 首次启动普查本机能力，写入 Machine index：有 rg 就用 rg，装了 Codex 也登记。干净机上没有 `fd`，agent 查到 Debian 的包名是 `fd-find`、二进制叫 `fdfind`，装完接着完成检索任务。找工具是一项被打分的能力，不是一个假设。
- **扩展只发提示词，不发代码。** [`plugins/agent/`](plugins/agent/) 的 catalog 里是 JSON prompt 和空树模板。新能力由模型按提示词在本机自己长出来——绝不靠加厚种子。
- **不信模型的口头汇报。** 交互里的 `/ini` 让模型自选方式把 runtime 安装成全局 `seed` 命令，但外壳独立公证：回执、启动时冻结的原始 PATH、可执行入口、`--probe` 身份检查，全部对上才算成功。假回执和 PATH 污染都在测试套件里。

## 它能做什么

- 在任意项目目录当 coding agent：交互式 `>`，或 `-p "任务"` 一次性执行。
- 为任务写**任何语言**的代码——POSIX 限制罩住的是 runtime，不是产物。
- 自己修环境：缺 jq 下载 jq，任务需要什么就 `apt-get install` 什么，装之前先查对包名。
- 探测并复用本机已有的 CLI、解释器、服务，连用途、调用方式、smoke 结果一起登记进能力索引，跨任务摊销探测成本。
- 把自己安装成全局命令（`/ini`），装完由外壳验收。
- 跑官方 Terminal-Bench 2.1 全套 89 题（Harbor + Docker）：每道题的容器里只放同一份 `seed.sh`。

## 做过的实验

### 冷启动与能力索引（Apple container，Debian 12 aarch64）

同一颗种子分别丢进「只有 curl + CA 的干净机」和「预装 git / rg / python3 / jq / openssl / Codex 的富环境」。

| 环境 | 题目 | 终态 | 墙钟 | 它实际怎么干的 |
|---|---|---|---|---|
| 干净机 | hello-file | pass | 15s | 自己拉 jq → 初始化 → 写文件 |
| 干净机 | web-install-fd | pass | 14s | 查到 Debian 包名 `fd-find`，用 `fdfind` |
| 干净机 | openssl-selfsigned-cert（TB 2.1 原题） | pass | 50s | 现装 python3，自己写验证脚本 |
| 干净机 | nginx-request-logging（TB 2.1 原题） | pass | 35s | 装 nginx、修 403，四项检查全绿 |
| 干净机 | fix-git（TB 2.1 原题） | pass | 17s | 现装 git，合并分支 |

索引摊销：先付一次全面普查（54 秒，登记含 Codex 0.147.0 在内的 11 个工具），之后每题都便宜——hello-file 6s、list-tools 16s、fix-git 10s。跳过普查索引就是空的，后面依赖索引的题会挂。普查是付一次、全程收息的成本。

### 官方 Terminal-Bench 2.1（Harbor + Docker，89 题）

每道题的容器只拿到 standalone `seed.sh` 以及 curl 和 CA——jq、git、python 是种子自己的事。对官方原题指令 `--oneshot`，官方 verifier 打分：

- seed + `deepseek-v4-pro`，k=1 一遍分 **Mean 0.360（32/89）**。同任务集、同 verifier，但是单次尝试分，不是 k=5 榜单口径——我们照实标注。
- 第二轮 `deepseek-v4-flash`（修复流式停滞截断、加时间预算提示后）进行中，中期通过率高于第一轮。
- 同模型对照（mini-swe-agent、terminus-2）按同一任务集、同一 verifier 排队。
- 失败归因公开不藏：三大类是「没交卷」「时间耗尽没做完」「宣布完成但验收不过」。一个值得说的发现：早期流式 curl 的 `--max-time` 会掐断模型的长思考、把锅错算到模型头上——现已改为停滞检测。

### 一台安卓平板造了个 3D 游戏

我们用 adb 把种子敲进一台普通安卓平板的 Termux：无 jq 环境自愈、初始化、打开 `>` 提示符。然后只给了一个任务——「做一个 3D 网页游戏」——平板上的 agent 独立完成了剩下的一切：

1. 写出单文件 three.js（CDN）游戏 **Cube Tap**——戳旋转的方块得分；
2. 探测到本机 python3，`nohup python -m http.server 8080` 起服务；
3. 自己 `curl localhost:8080` 验证 200 之后才汇报 URL；
4. 平板浏览器打开即玩，触屏操作。

没有人写过一行游戏代码。干这件事的 runtime，还是那同一份 shell 文件，跑在一块手机级 ARM 板子上。

### 安装公证与离线合同

- `/ini` 的验收对抗过假回执和 PATH 污染：模型说装好了没有用；外壳用启动时冻结的 PATH 重新解析 `seed`，再跑 `--probe` 核对身份。
- 离线产品合同（假 plugin transport + LLM stub，不联网、不要真 key）覆盖 20+ 项：SSE 分片合并、断流触发重试、空回复不当终稿等。

## 使用

先从 GitHub main 下载 `seed.sh`，不要 `curl | sh`。插件 catalog 默认从本仓库 raw `plugins/` 拉取（`https://raw.githubusercontent.com/Leehow/seed/main/plugins`）；可用 `SEED_PLUGIN_ROOT` 覆盖。

```sh
curl -fsSL https://raw.githubusercontent.com/Leehow/seed/main/seed.sh -o seed.sh
cd 你的项目
/bin/sh /下载路径/seed.sh deepseek sk-你的key
```

第一次会把配置写入 `~/.seed/.env`，初始化机器能力索引，然后进入 `>`。空行或 Ctrl-D 退出。之后在任意项目目录直接运行同一个文件：

```sh
/bin/sh /下载路径/seed.sh
/bin/sh /下载路径/seed.sh -p "把安装说明写进 README"
```

任意 OpenAI 兼容接口（第三参模型名可省）：

```sh
/bin/sh seed.sh https://api.example.com/v1 sk-xxxx 模型名
```

在交互提示符输入 `/ini`，模型会尝试把当前 runtime 安装成全局命令；外壳独立检查回执、PATH 和 probe。成功后：

```sh
seed
seed -p "任务"
```

工作区始终是启动命令时的当前目录。状态目录默认 `~/.seed`，可用 `SEED_HOME` 隔离。不要提交 `.env` 或运行证据。

## 开发

这个 GitHub 树**就是**产品：[`seed.sh`](seed.sh) 加上提示词 catalog。改种子，然后：

```sh
/bin/sh -n seed.sh
```

[`plugins/agent/`](plugins/agent/) 里发布的是提示词，不是另一套 runtime。换脾气、换扩展，只改那些 JSON，不要加厚 `seed.sh`。

## 这个仓库里有什么

| 路径 | 角色 |
|---|---|
| [`seed.sh`](seed.sh) | 完整 runtime——下载就能跑 |
| [`plugins/agent/`](plugins/agent/) | 提示词 catalog：初始化、skills、commands、懒构建扩展 |
| [`plugins/seed/`](plugins/seed/) | provider / model catalog |
| [`plugins/jq/`](plugins/jq/) | jq 回退说明与拉取脚本 |
| [`LICENSE`](LICENSE) | MIT |

## 诚实的边界

- TB 2.1 分数是单次尝试（k=1），不是榜单口径（k=5）；社区提交目前关闭，这里不声称任何榜单名次。
- 种子依赖支持标准 `tool_calls` 的模型；中途停下来提问的模型在 benchmark 条件下得分会差。
- 空工具箱**加**断网是这套设计的弱区——「先找后造」总得有地方可找。
