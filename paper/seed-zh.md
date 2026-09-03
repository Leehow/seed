# Seed：面向带工具 coding agent 的 POSIX `/bin/sh` 运行时

> 中文阅读稿，与 `seed.tex` 对照。arXiv 仍以英文稿为准。作者、邮箱为占位。

**Leehow** · Independent Researcher · https://github.com/Leehow/seed · 2026 年 8 月

---

## 摘要

主流 coding agent 是带一整个函数工具动物园的 Node 或 Python 程序。本文问一个更窄的问题：POSIX `/bin/sh` 加上 `curl` 和 `jq`，能不能自己撑住 agent 主循环——流式传输、工具分发、持久 shell、精确替换编辑——底下不再叠第二套运行时？

我们描述 **Seed**：单文件 agent，模型看得见的接口只有两个工具（`shell` 和 `edit`）。宿主机上的能力通过 shell 去发现、验证、复用，而不是加成 API 工具。

在官方 Terminal-Bench 2.1（89 题，Harbor，官方 verifier）上，同一只模型、$k{=}1$，Seed 为 45/89（均值 0.506）。同一模型、同一 harness 下，mini-SWE-agent 为 66/89（0.742），Terminus-2 为 62/89（0.697）。缺口集中在超时（32 对 12 和 11），不是交了卷之后正确性崩掉。我们不报榜单名次：社区口径是 $k{=}5$。

贡献是存在性与诊断。一份 POSIX shell 文件能跑完官方终端套件；同模型下它输给成熟 Python harness，主要是墙钟结束前没把交付物落到磁盘上。另有非基准证据——只有 curl 的 Debian 冷启动，以及一台自己长出并提供可玩 3D 页面的 Android 平板——补的是 Terminal-Bench 量不到的东西：安装面和可携带性。

---

## 1 引言

Coding agent 已经收敛到厚栈：Python 或 Node 控制器、厂商 SDK、再加一份把 shell 已有能力再实现一遍的工具表（read、grep、glob、todo、子代理）。SWE-agent 表明，为模型专门设计的 agent–computer interface（ACI）在仓库修复上可以胜过裸 shell。mini-SWE-agent 后来走了反方向：以 bash 为中心的小循环在终端任务和 SWE 任务上仍然有竞争力。这两个系统，以及 Terminus-2，仍然是 **Python 进程去调用 shell**。

Seed 问的是：循环能不能 **就是** shell。

可下载的产物是一份 POSIX 文件 `seed.sh`。没有打包器，也没有生成出来的引擎。模型看见两个函数工具。其余一切——搜索、安装、测试、HTTP——都是持久登录 shell 里的普通命令，工作目录和环境跨回合保留。

这个约束就是产品，不是打算长大以后脱掉的残疾。一份可读的文件是可审计的控制器。机器上已有 `/bin/sh`，就能带着这个 agent 走，包括 Node 和 Python 不是启动假设的环境（Termux、接近 BusyBox 的盒子、只有 curl 的干净容器）。

于是评测问题不是「Seed 能不能在 Terminal-Bench 榜上打赢 Claude Code」，而是：

1. 这套运行时能不能在官方 verifier 下跑完官方 89 题 Terminal-Bench 2.1；
2. 模型固定时，和 Harbor 自带的 mini-SWE-agent、Terminus-2 adapter 比怎样；
3. 分差落在哪里；
4. 设计在基准之外独有地证明了什么。

结果先说：DeepSeek-V4-Flash，$k{=}1$，Seed 均值 0.506，mini-SWE-agent 0.742，Terminus-2 0.697。Seed 第三。本文按系统报告来写这个事实，外加一个可携带的运行时，不当成 SOTA 声明。

---

## 2 相关工作

**Agent–computer interface。** SWE-agent 认为语言模型 agent 需要为它们设计的接口，而不是为人类设计的接口，并且专用的编辑/搜索 ACI 在 SWE-bench 上优于仅 shell 的基线。Seed 站在这笔交易的另一边：ACI 停在两个原语，把宿主机 CLI 当作已经存在的接口。精神上更接近 mini-SWE-agent，而不是完整 SWE-agent。对主张要紧的差别只有一条：mini-SWE-agent 是发 bash 的 Python 程序；Seed 的循环、SSE 客户端和 `edit` 实现都是 POSIX shell。

**终端 agent 与 Terminal-Bench。** Terminal-Bench 2.0/2.1 在真实容器里评长期工作，看结果测试，不看命令轨迹。Harbor 跑这些题，并带 Claude Code、Codex、OpenHands、mini-SWE-agent 和 Terminus-2 的 adapter。Terminus-2 是基于 tmux 的参考 agent，逻辑在容器外。我们用后两个做同模型基线，因为它们是公开的「薄终端循环」里最近的点，不是因为它们和 Seed 一样用 POSIX 实现。

**造工具与生长。** Voyager 和 LATM 研究随时间发明工具的 agent。Seed 的规则反过来：先找、探测、登记机器上已有的东西；什么都验证不过，才发明包装。循环形状是 ReAct 式的交错思考与行动；Seed 把这个形状写死在 shell 里，模型不能每回合重写控制器。

---

## 3 设计

### 3.1 一份文件，两个工具，外壳拥有循环

运行时就是一份 `seed.sh`。写稿时大约 \(3.5\times10^3\) 行 POSIX shell；行数会动，接缝不会动：循环里没有第二种语言。运行时依赖是 `/bin/sh`、`curl` 和 `jq`（宿主机没有 jq 时，文件自己拉一份二进制）。

循环是固定的：

> messages + 两份工具 schema → 模型。若响应含 `tool_calls`，按序执行并追加观察。若没有，本回合结束。

`shell` 跑在一个持久会话里（`cd` 和环境变量会留下）。`edit` 用唯一的 `old_text` 换成 `new_text`；零次匹配或多次匹配都失败，文件不动。read、grep、glob 不是工具。

传输、重试、回合上限、以及什么算「这一回合完了」，都归 shell。没有 `tool_calls` 的空白 assistant 消息当成供应商毛刺，不当成「人说完了」。流式用停滞检测，而不是给 HTTP 客户端加死墙钟 `--max-time`——更早的硬切断会截断模型的长推理，再把失败错记到模型头上。

### 3.2 先找、验证、登记、复用

在一台有家底的机器上，git、ripgrep、Python 和第三方 CLI 本来就在。Seed 记下见过什么、理解过什么、哪条探测命令验证过，然后优先用这些条目，而不是另造一套工具链。当前索引形状区分观察、能力、以及机外资源；一条能力的 `ok` 位是所存探测命令的退出码，不是模型嘴上说的。

这是关于 **能力住在哪**（机器的 CLI）的政策，不是第三个函数工具。新能力是新的索引行加一个二进制，永远不是新的 JSON 工具 schema。

### 3.3 提示词当发行物；安装当公证

产品脾气——初始化、技能、可选记忆——以 JSON 提示词 pack 经 HTTP 分发，不是第二份可执行文件。把运行时装成全局命令 `seed` 是一笔 shell 事务：冻结启动 `PATH`、精确字节、`--probe` 身份、收据、失败回滚。不让模型自己宣布成功。

### 3.4 拒绝写进内核的东西

Harbor 从不把 `timeout_sec` 告诉容器里的 agent。「先落一份交付物；不会有人回答你的问题」这类前缀能抬 Terminal-Bench 分数，那是 **harness** 的事。我们把这类指令只放在 adapter 里。写进默认 pack，就是为考试优化 Seed，牺牲交互：交互里停下来问一句常常是对的。下面那轮同模型 Terminal-Bench 在 Harbor adapter 里用了很短的时间预算提示；没有加工具。

---

## 4 实验

除非另注，模型是经 OpenAI 兼容端点的 DeepSeek-V4-Flash。该端点并发差；对照作业用 Harbor `n_concurrent = 1`。

### 4.1 冷启动与索引（不是官方套件）

同一份 Seed 丢进 Apple `container` 的 Debian 12 aarch64 镜像。

**表 1。** 干净盒子：预装只有 curl 和 CA 证书。听起来像官方题名的，是 Terminal-Bench **指令** 加本地夹具，不是 Harbor 评分。

| 任务 | 结果 | 墙钟 | 实际做了什么 |
|---|---|---|---|
| hello-file | pass | 15s | 自拉 jq，初始化，写文件 |
| web-install-fd | pass | 14s | Debian 包 `fd-find`，二进制 `fdfind` |
| openssl-selfsigned-cert | pass | 50s | 安装 python3，写检查 |
| nginx-request-logging | pass | 35s | 安装 nginx，修 403 |
| fix-git | pass | 17s | 安装 git，合并 |

付过一次普查（54s，登记 11 个工具，含本机 Codex CLI）会摊销：随后 hello-file 6s，fix-git 10s。跳过普查，索引是空的；后面依赖它的任务会失败。这是「先找再造」的证据，不是 Terminal-Bench 分。

### 4.2 官方 Terminal-Bench 2.1

**协议。** Harbor 0.21.0，数据集 `terminal-bench/terminal-bench-2-1`（89 题），官方 verifier，$k{=}1$。Seed 的 adapter 上传 `seed.sh`，任务容器里只保证 `curl` 和 CA 证书；缺 jq、git、python 是 Seed 自己的事。mini-SWE-agent 的官方 Harbor adapter 会装 git、python3、编译工具，再 `uv tool install mini-swe-agent`。Terminus-2 在宿主机跑，用 tmux 驱动容器。这些安装面 **不相等**；我们和分数一起报。

**主结果。**

**表 2。** 同一模型（DeepSeek-V4-Flash），同一套 89 题，$k{=}1$。均值是过题数除以 89。超时是 Harbor `AgentTimeoutError`。

| Agent | 过 | Mean | 超时 |
|---|---|---|---|
| mini-SWE-agent | 66/89 | 0.742 | 12 |
| Terminus-2 | 62/89 | 0.697 | 11 |
| Seed | 45/89 | 0.506 | 32 |

在这套协议上 Seed 明显更差。有意思的不是名次。Seed 的 44 次未过拆成：超时 32、交卷但 reward 为 0 的 9、`NonZeroAgentExitCodeError` 3。mini-SWE-agent 的 23 次未过拆成：超时 12、reward 0 的 9、非零退出 2。Terminus-2 的 27 次未过里有 11 次超时；其余我们不再拆。相对 mini-SWE-agent 少过的 21 题，集中在 `AgentTimeoutError`（32 对 12），不是交到 verifier 的工作正确性崩了。这和「薄循环把墙钟花在规划上、被切断时磁盘上还没有交付物」一致。

评测用的 Seed 快照已经包含：流式停滞检测（SSE 不加 HTTP `--max-time`）、截断流重试、空补全不当成终回合、Harbor adapter 里很短的时间预算提示。它 **没有** 包含后来的提示词 pack 实验（考试风的交卷协议）。那种东西如果要有，只该活在 harness adapter 里；不在默认 pack catalog，试过之后也没有再跑 89 题。

**更早、不可比的一轮。** 在停滞检测替换 HTTP `--max-time` 之前，Seed + DeepSeek-V4-Pro 为 32/89（均值 0.360），大量截断流。那一轮把更弱的传输 bug 和另一只模型搅在一起，**不是** 对照行。写出来是免得有人把 0.506 当成我们印过的第一个数。

**这不是什么。** Terminal-Bench 榜单口径是 \(k{=}5\)。这几趟作业当时社区提交是关着的。表 2 是单次尝试、同模型脚手架对照，不是 tbench.ai 排名。

### 4.3 可携带性：平板

在一台原装 Android 平板上，Termux 经 `adb` 收到 `seed.sh`。种子自拉 jq、初始化、打开提示符。任务是做 3D 网页游戏：产出 three.js 页面、`python -m http.server`，并在报告 URL 之前用 curl 检查 HTTP 200。后来经提示词长出来的本机控制台，用一句话又做出另一页可玩的东西（分道的「3D Speeder」），同一套路：写文件、提供服务、验证，再开口。没有人写游戏源码。这是定性的。它支撑表 2 撑不住的携带性主张：在 Harbor 上输给 mini-SWE-agent 的控制器，就是在手机级 ARM、没有 Node 安装的那份文件。

### 4.4 离线合同

离线套件（桩 LLM、假 pack 传输、无密钥）覆盖 SSE 合并、截断流重试、拒绝空补全、以及安装路径攻击（PATH 污染、拒绝覆盖、回滚）。这些测试不依赖付费 API，单独支撑传输和公证主张。

---

## 5 讨论

**输了同模型基准，这就是结果。** 若论文需要 Seed 分高于 mini-SWE-agent，表 2 写不出来。若论文需要 POSIX 循环 **足够** 跑完官方套件，并诊断剩下的缺口，写得出来。少过的 21 题多半是时间：adapter 和默认提示词怎么对待「做完了」，不是证明 `edit` 这个原语选错了。

**不要靠把内核塞满来补缺口。** 加上 read/grep 工具，或在默认 pack 里强制「考试交卷协议」，会让 Seed 更不像对自己问题的回答。以后若均值动了，应当是告诉 **Harbor** 作业截止时间和「没有人」这条规则，或者让模型更早写文件——两工具契约不变。

**不相等的安装面。** mini-SWE-agent 的 Harbor 安装等于白送一套 Python 工具链。Seed 的 0.506 包含在题目里自己长 jq 和 apt 包。把镜像拉齐会抬 Seed，也会把冷启动故事藏起来。我们宁可要诚实的混淆，不要沉默的混淆。

---

## 6 局限

- 只有 \(k{=}1\)；不同随机种子的方差未测。
- 一个模型族；脚手架差距换模型可能缩小或放大。
- 没有断网消融（「先找再造」得有地方可找）。
- 平板和 Apple container 任务不是 Harbor 评分。
- `seed.sh` 是一份文件，但早已不是玩具；行数是会动的工程事实，不是复杂度证明。
- 提示词 pack 和机器索引政策仍在变；表 2 绑的是产物说明里点名的 Harbor 作业，不是之后每一笔提交。
- 源码树里有 Windows capsule 和 launcher；本文主张的是 POSIX `seed.sh` 运行时，不是那套打包。

---

## 7 结论

Seed 表明：带工具的 coding agent 可以住在 POSIX `/bin/sh` 里——两个 API 工具、外壳拥有的循环、其余接口就是宿主机 CLI。在官方 Terminal-Bench 2.1 上，同模型、$k{=}1$，这套运行时过大约 51% 的题，落后 mini-SWE-agent 和 Terminus-2 大约二十个百分点，几乎全是超时。对照当测量，可携带的单文件设计当贡献，超时形态当下一个工程目标——不在内核的工具表里。

---

## 产物

代码：https://github.com/Leehow/seed

Harbor 作业（不进 git）：`2026-08-19__21-31-54`（Seed），`2026-08-20__20-35-52`（mini-SWE-agent），`2026-08-21__19-42-10`（Terminus-2）。
