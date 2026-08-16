# 参考 Prime Agent：子代理委托 + /refine，全是提示词

- 日期：2026-08-16
- 状态：已拍板（delegate 块排调度最末；§5 那句入选）
- 前序：[可选初始化](2026-08-15-seed-agent-optional-init-design.md)、[检索树](2026-08-14-retrieve-index-design.md)、[上下文压缩](2026-08-14-context-compact-design.md)

## 1. 要解决什么

Prime Agent（PrimeIntellect-ai/prime-agent，pi-mono 之上）和 slab 赌的是同一件事：模型侧工具面收到极小，通用执行交给一个「有记忆的 REPL」。它的 REPL 是持久 IPython 内核；slab 的是持久登录 shell。研究结论：两个能力值得借，**都是提示词级，不动种子**：

1. **子代理是函数调用**（它的 `rlm(...)`）。shell 译法：在持久 shell 里递归调 `bin/agent --oneshot`，结果就是返回值。不加第三种 `tool_calls`。
2. **Continual Harness**（它的 `/refine`）。shell 译法：回顾 `.agent-runs` 证据，把教训蒸馏进 `.agent-memory`，小步、可回滚、永不碰基础提示词。

它的 IPython 内核、daemon、TUI、agent 间直接消息，不破种子的约束，不借（见 §7）。

## 2. 对应关系

| Prime Agent | slab 现状 | 本稿补什么 |
|---|---|---|
| 持久 IPython 内核，状态跨轮 | 持久 shell worker，`cd`/`export`/文件跨 tool call 存活 | 委托时显式用这一点：后台作业 + 轮询 |
| `rlm(...)` 起子代理 | 无 | `delegate.json` 提示块：递归 `--oneshot` |
| `/refine` 改可回滚的磁盘状态 | `.agent-memory/index.json`（notes/facts，已是空树） | commands 表加 `/refine`；retrieve 加读取闭环一句 |
| skill 元数据进启动提示 | `skill_catalog()` 已是 | 不动 |
| host 拥有 loop / provider / 会话 | 外壳拥有循环 | 不动 |

## 3. 子代理委托（`plugins/agent/delegate.json`，新块）

提示词教会的纪律，不是新工具：

- **怎么发起**：持久 shell 里 `sh "<安装目录>/bin/agent" --oneshot '<子任务>'`。安装目录由 system 里的 Machine index 路径推出（去掉 `/agent-store/index.json`）。子代理从 `.env` 拿 key，证据落自己 cwd 的 `.agent-runs/`。
- **子任务必须自包含**：子代理看不到父对话。提示词里给路径、给验收标准，要求「最后回答就是结果」。长结果让子代理写文件，父只读摘要。
- **180 秒线**：shell 工具默认 `ACTION_TIMEOUT=180`。短差事可同步等；可能超的一律后台——`> out 2>err & echo $!`，后续轮次用 `kill -0` / 看输出文件轮询。持久 shell 跨 tool call 存活，后台作业继续跑。
- **cwd 即作用域**：子代理的工作区 = 发起时持久 shell 的 cwd。想把它圈进子目录，先 `cd` 或让它自己 `cd`。
- **不重叠**：多个后台子代理共享同一工作区，委托前声明各自的文件范围。
- **不再委托**：子代理任务应自包含到不需要再委托。深度一层。
- **成本**：一次委托最多 `AGENT_MAX_ROUNDS` 轮。小事不委托。

落点：seed-agent 调度（`seed-agent.json`）文件列表加 `delegate.json`，顺序最末：

`skills` → `commands` → `models` → `plugins` → `delegate`

进度记 `ours.seed_agent.delegate`。这块没有磁盘产物，**done 的凭据是一次真实委托**：`.agent-runs/` 里多出一个非 `-init` 的证据目录，且父回收到了结果。检查写进提示词：

1. 真跑通一次 `--oneshot` 委托（短差事，如同步 `pwd` 类）并回收最后回答
2. 该证据目录存在，里面有 messages 和 usage
3. 委托命令不含 `--resume`、不含交互模式

检查不过，键留空，告诉人，停下。

## 4. `/refine`（改 `commands.json` 提示 + retrieve 一句）

**写入侧**：`commands.json` 提示的命令表加 `/refine`，`description` 中文一行，`use`（英文）写明：

- 回顾最近若干 `.agent-runs` 证据：人的纠正、edit 失败、返工、超时
- 蒸馏成小条进 `$PWD/.agent-memory/index.json` 的 `notes` / `facts`，每条带来源证据目录和 UTC 时间
- 改之前把 `index.json` 复制到 `.agent-memory/snapshots/<utc>.json`，可回滚
- **永不**改 `system.retrieve`、`build/`、`agent-store/` 里的提示词——对应 Prime 的「不动不可变基础 system prompt」
- 不回显 key，不 grep `.env` 上终端

**读取闭环**：现在 `product_system` 只把 `Project memory:` 路径印进 system，没人教模型读。`init.json` 的 `system.retrieve` 加一句（英文，模板措辞）：开工前 jq project memory（路径在 system 里）里与人话匹配的 notes/facts；不整个 cat。init.json 是 plugin 提示词，允许改；`version`/`updated` 顺带 bump，`--update` 会把新 retrieve 刷进已有的树。

`/refine` 的检查并进 `commands.json` 提示的「Check before done」：`/refine` 的 use 必须提到 `.agent-memory/index.json` 和 `snapshots`。

## 5. context-as-files（一行，`build/prompts/product-system.txt`）

Prime 把「大东西别进 messages」做到极致。slab 有 16KiB 截断和 70% 压缩兜底，但提示词没明说。product-system 加一句英文——大输出写文件，之后 grep/jq 查，不要整个重读进上下文。这是改脾气不是改骨架：改完 `sh build/pack.sh`，跑离线合同。

## 6. 仓库交什么 / 合同

交：`plugins/agent/delegate.json`（新）、`seed-agent.json`（调度加一块）、`commands.json`（`/refine`）、`init.json`（retrieve 一句 + bump），可选 `product-system.txt` 一句。仍是「线上 plugin 只是提示词」：不得交 `.sh` / `.py` 实现。

`tests/seed-package.sh` 加断言：

- `delegate.json` 在、有 `prompt` 字段、不含实现
- 调度提示词的文件列表含 `delegate.json` 且顺序最末；写明 done 凭据是真实委托的证据目录
- `commands.json` 提示含 `refine`，且写明 snapshots 回滚、不动 retrieve
- `init.json` retrieve 含 memory 读取那句，旧断言（门、`Never cat the entire index`）不回归
- `plugins/agent/` 除 JSON 外仍没有实现文件
- `build/` 除可选那一句外不为此改动；不加挂钩、不点名扩展

不测模型真的委托成功。那是线上行为，离线合同管不着。

## 7. 明确不做

- IPython / Python / 任何第三语言进种子、`bin/agent`、loop、两个工具
- daemon、attach/reattach、TUI、heartbeat、调度器
- 子代理之间直接消息（Prime 的 `agent_message` A2A）。只许「父发起、文本或文件回收」
- Python 包形式的 executable skills
- 第三种 `tool_calls`、改 `loop.sh`、引擎加载 `optional`
- 无限制递归委托；子代理再委托
- 把 Prime 的 TS host 概念抄成任何实现文件
