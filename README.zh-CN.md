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
- **先找、验证、登记、复用，找不到才造。** 首次启动只记录机器身份和一次廉价的 `PATH` observation；任务按需调查候选、验证真正需要的能力，再登记复用。有 `rg` 就用 `rg`；干净机没有 `fd`，就查到 Debian 的包名 `fd-find`，验证 `fdfind` 后复用。发现能力是一项被打分的技能，不是桌面环境假设。
- **产品策略发提示词，通用边界留在内核。** [`packs/agent/`](packs/agent/) 发布 JSON prompt 和空树模板；原子状态写入、经验发布闸门、检索上限和安装回滚等通用完整性约束由 kernel 负责，垂直产品行为留在 pack。
- **不信模型的口头汇报。** `/ini` 是离线、确定性的 shell 事务：只从启动时冻结的 `PATH` 里选择已有、当前用户拥有且可写的目录，以内容标识发布 runtime，不覆盖已有 `seed`；精确核对字节与 `--probe` 身份，最后提交回执，失败只回滚本事务创建的文件。全程不调用模型、不改 profile、不用 `sudo`、不联网。

## Agent Kernel 架构

收窄的问题有了答案，而且答案可以推广：Seed 不去追赶功能齐全的 coding agent——它是垂直 agent 从中长出来的 **Agent Kernel**。决策记录在 [`docs/adr/0001-seed-as-agent-kernel.md`](docs/adr/0001-seed-as-agent-kernel.md)。三层各答一问，互不越界：

- **Capability = CLI**——这台机器能做什么。Machine index 分三层：**observations**（看见了什么——启动时一次廉价的 `PATH` 枚举，加上任务途中注意到的东西）、**capabilities**（调查并验证过什么，每条都带着那条决定 `ok` 的 `probe` 命令）、**resources**（机器之外已经找到过的现成东西）。没有固定工具字段：`git`、`python`、`docker`、`opkg`、某仪器厂商的 `device-cli` 是同一种记录，所以进到 BusyBox 或 OpenWrt 盒子里不会被问六个桌面问题。硬编码的是发现机制，不是环境知识。LLM 只保留 `shell`、`edit` 两个 primitive。新能力 = 一条新索引记录加机器上的一个 CLI，永远不是一个新的 function tool。详见 [`docs/adr/0002`](docs/adr/0002-machine-index-as-cognition.md)。
- **Skill = 怎么做事情。** 按 agentskills.io 规范写的 SKILL.md，只登记 name/description/path，正文命中任务才 `cat`（渐进披露）。蒸馏出的经验就是 skill——方法复用只有一个机制，不是两个。
- **Pack = 让 Seed 长成什么。** 发布的 pack 只有提示词；安装 pack 永远不改 `seed.sh`。coding pack 长出 coding agent，security pack 长出 Strix 式 agent。同一个 kernel、同样的两个工具，不同的 pack。

### 记忆系统（[`packs/agent/memory.json`](packs/agent/memory.json)）

跨会话的方法复用由普通文件、只用英文的内部记录、prompt 策略和确定性 kernel 闸门共同完成——没有数据库、向量索引或常驻服务：

- 四层：**L0 规则**（`rules.md`，永远最高优先）→ **L1 事实**（项目 notes/facts 加机器索引）→ **L2 经验**（按 id 一目录、带生命周期）→ **L3 证据**（只追加的 `runs/*.jsonl`）。
- 经验有生命周期：`candidate → active → degraded → quarantined / stale / retired`；retired 归档进 attic，不删除。
- 模型只有**提案权**。`/maintain` 和 `--maintain` 是不调用模型的离线 runtime 命令：kernel 只规范化无歧义的 SKILL 元数据（包括补上完全缺失的 frontmatter）、store-relative catalog/evidence 写法和启动路径写法，再从启动目录为每条非空、非 no-op 的 `verify[]` 启动全新 shell 并写入自己的精确收据；已有但无效的 frontmatter 和任何不受 containment 约束的路径仍会被拒绝。只有 16 字段 schema、时间、路径 containment、规范 SKILL frontmatter、同步 catalog 行和 runtime evidence 全部一致才发布。
- 检索只有一个 runtime 漏斗：OS/工具 scope → active 或带警告的 degraded → 英文关键词打分 → 确定性排序 → 最多 3 条 metadata。命中才加载 `SKILL.md`；模型不得扫描 experience index 另造激活通道。
- 经验即 skill：通过校验的 active/degraded 经验在每个任务后合并进 `agent.skills`。能力变成 `ok:false` 时，依赖它的经验立即不可用，maintenance 再将其转成 `stale`。memory prompt 缺失时由 runtime 按 catalog 获取；自动 pack 更新仍须显式设置 `SEED_AUTO_UPDATE=1`。

### Pack 生态

- [`packs/agent/`](packs/agent/) 保存 `init`、memory、commands、skills、models、packs、delegation、delivery 和 Web IDE 的 prompt policy。当前 agent catalog 只声明 `init` 为必需、`memory` 为 runtime 管理的可选策略；产品 bundle 可把其余 prompt 安装到 `agent-store/packs/`。
- catalog [`index.json`](packs/agent/index.json) 带版本号；只有显式设置 `SEED_AUTO_UPDATE=1` 才在启动时刷新，否则已安装的 prompt policy 保持固定。显式 `/packs` 安装不受影响。
- `/packs install <slug>` 把已发布的 pack 落到 `agent-store/packs/`；`/packs` 列出全部。

### 委派

子 agent 就是一条 shell 命令——`seed --oneshot '<自包含任务>'`——证据落在 `.agent-runs/` 下。没有调度器、没有编排进程：Unix 进程树就是多 agent 运行时。

## 规划中

方向已在 ADR-0001 定下；run provenance（`SEED_PARENT_RUN_ID` / `SEED_RUN_ROLE`）已经实现。剩余工作：
- **Seed Console。** 读 `.agent-runs/` 下 run 文件的 Web UI，渲染 run graph。它是 runtime 自己证据的一个视图——不是第二套 agent loop，也刻意不叫 Web IDE。
- **Capability contract 收紧。** Machine index 里 `probe`、`scope`、`ok` 的语义更明确。
- **垂直 pack 生态。** security（Strix 式）、microscope、research——每个都是同一 kernel 上的纯提示词 pack。

## 它能做什么

- 在任意项目目录当 coding agent：交互式 `>`，或 `-p "任务"` 一次性执行。
- 为任务写**任何语言**的代码——POSIX 限制罩住的是 runtime，不是产物。
- 自己修环境：缺 jq 下载 jq，任务需要什么就 `apt-get install` 什么，装之前先查对包名。
- 探测并复用本机已有的 CLI、解释器、服务，连用途、调用方式、smoke 结果一起登记进能力索引，跨任务摊销探测成本。
- 把自己安装成全局命令（`/ini`），装完由外壳验收。
- 跑官方 Terminal-Bench 2.1 全套 89 题（Harbor + Docker）：每道题的容器里只放同一份 `seed.sh`。
- 把成功任务蒸馏成可复用的经验（skill），晋升走确定性检查；后续任务经由 scope + 关键词检索漏斗取回。
- 把自包含的子任务委派给子 agent（`seed --oneshot`），运行证据落在 `.agent-runs/`。

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

### 一台平板，在浏览器里给自己编程

我们用 adb 把种子敲进一台普通安卓平板的 Termux：无 jq 环境自愈、初始化、打开 `>` 提示符。然后只给了一个任务——「做一个 3D 网页游戏」——平板上的 agent 独立完成了剩下的一切：写出单文件 three.js 游戏，`nohup python -m http.server 8080` 起服务，自己 `curl localhost:8080` 验证 200 之后才汇报 URL，浏览器打开即玩。

接着我们问：这台平板能不能干脆不要终端。第二个 pack [`web-ide.json`](packs/agent/web-ide.json) 不含任何代码，它描述的是一份证据契约和十一条验收检查，控制台由 agent 在本机长出来。它被约束的设计很窄——loop 仍归 shell，服务端把运行流渲染成 HTML，页面只是「一次运行本来就落盘的证据」的一个视图。控制台里没有任何一处重新实现轮次、工具分发或流式传输。

控制台绑在 `127.0.0.1`，持着 Termux 唤醒锁。有人在平板上，往它的输入框里敲了一句话：

> make a 3d game i can play on this tablet

十七轮之后——没给路径、没给库、没提框架、没说要起服务也没说要验证——平板上出现了 **3D Speeder**：三个文件、三条车道、随存活时间加速的障碍物、因为那句话里有「平板」而自带的屏幕方向键、存在 `localStorage` 里的最高分，以及一个撞车结算页。agent 自己起了 `python -m http.server`，把三个文件逐个 curl 到 200 才开口回话。

**一句话的结果，比它前面那条详细提示词的结果更好。** 要求「单文件、用 three.js、戳旋转方块得分」，拿到的就恰好是这些、再无更多——约束把产出封在了提问者的想象力上。要规定的是检查，不是产品。

两个游戏都没有人写过一行代码。干这件事的 runtime，还是那同一份 shell 文件，跑在一块手机级 ARM 板子上。

### 安装公证与离线合同

- `/ini` 的验收覆盖离线执行、已有命令拒绝、PATH 污染、精确内容校验，以及发布命令入口前后两阶段的回滚。
- 离线产品合同（假 pack transport + LLM stub，不联网、不要真 key）覆盖 20+ 项：SSE 分片合并、断流触发重试、空回复不当终稿等。

## 使用

先从 GitHub main 下载 `seed.sh`，不要 `curl | sh`。pack catalog 默认从本仓库 raw `packs/` 拉取（`https://raw.githubusercontent.com/Leehow/seed/main/packs`）；可用 `SEED_PACK_ROOT` 覆盖。

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

在交互提示符输入 `/ini` 会运行确定性的离线安装事务。它只使用启动 `PATH` 中已有、当前用户拥有且可写的目录，不改 shell profile、不覆盖另一个 `seed`；精确内容、PATH、probe 和回执全部通过才成功。之后可运行：

```sh
seed
seed -p "任务"
```

工作区始终是启动命令时的当前目录。状态目录默认 `~/.seed`，可用 `SEED_HOME` 隔离。不要提交 `.env` 或运行证据。

## 开发

这个 GitHub 树**就是**产品：[`seed.sh`](seed.sh) 加上提示词 catalog。改种子，然后：

```sh
/bin/sh -n seed.sh
/bin/sh tests/test_seed_agent_kernel.sh
/bin/sh tests/test_seed_modes.sh
/bin/sh tests/test_seed_pack_manager.sh
```

[`packs/agent/`](packs/agent/) 里发布的是提示词，不是另一套 runtime。产品策略放在那里；跨 pack 的安全与原子性约束放在 kernel。

## 这个仓库里有什么

| 路径 | 角色 |
|---|---|
| [`seed.sh`](seed.sh) | 完整 runtime——下载就能跑 |
| [`packs/agent/`](packs/agent/) | 提示词 catalog：初始化、skills、commands、记忆、懒构建扩展 |
| [`docs/adr/`](docs/adr/) | 架构决策记录（ADR-0001：Seed as Agent Kernel） |
| [`packs/seed/`](packs/seed/) | provider / model catalog |
| [`packs/jq/`](packs/jq/) | jq 回退说明与拉取脚本 |
| [`LICENSE`](LICENSE) | MIT |

## 诚实的边界

- TB 2.1 分数是单次尝试（k=1），不是榜单口径（k=5）；社区提交目前关闭，这里不声称任何榜单名次。
- 种子依赖支持标准 `tool_calls` 的模型；中途停下来提问的模型在 benchmark 条件下得分会差。
- 空工具箱**加**断网是这套设计的弱区——「先找后造」总得有地方可找。
