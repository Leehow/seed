# 上下文压缩 v2：清之前先摘要

- 日期：2026-08-16
- 状态：已拍板（推翻 [旧稿](2026-08-14-context-compact-design.md)「不做模型摘要」一条，其余保留）
- 前序：[上下文压缩](2026-08-14-context-compact-design.md)、[参考 Prime Agent](2026-08-16-delegate-refine-design.md)

## 1. 要解决什么

现在过线只把旧 tool 正文收成 `[old tool output cleared]`：确定性、零成本，但被清段的内容模型彻底忘了——读过什么、改过什么、为什么这么改，全没。Claude Code / Codex 这类产品过线时先让模型把前段对话压成一段状态笔记，再继续。

旧稿撤模型摘要的理由是「压缩是 loop 自己的事，不再打第二轮摘要」。这个理由对**兜底**仍然成立，对**唯一手段**不成立：清除拿回窗口，摘要保住要点，两者是先后关系不是二选一。

提议的入口是「完整 agent」提出的，但触发点（`prompt_tokens ≥ 窗口×0.70`、overflow 73）只有引擎看得见；按 edition 分支等于种子点名扩展，破约束。所以摘要放**引擎层、对所有 edition 生效**，简单版同样受益。这是改骨架，动 `build/loop.sh`。

## 2. 两层

| | 做法 |
|---|---|
| 摘要（新） | 过线时先把保护区之前的对话轧成文字稿，一次非流式调用压成状态笔记，插回保护点 |
| 清除（旧，保留） | 摘要落位后照旧把旧 tool 正文收成 `[old tool output cleared]`；摘要失败时**只**清 |

触发、保护区、`INIT_STOP_WHEN_READY` 不压、overflow 强制一次重试：全部照旧。

## 3. 形状

- 过线时，`agent_compact` 在清之前：用 jq 把保护区之前的消息轧成文字稿——每条最多 500 字符，总预算 12KiB，超长从最旧丢。
- 摘要提示词是新文件 `build/prompts/compact-summary.txt`（英文，pack.sh 加一行 emit）。模板定死五段：goal / done / key paths & findings / open / next。要求只复述文字稿内容，不发明。
- 调用复用 `model_turn`（带 tools 也无妨，只取 `.content`）。不是 loop 的一轮，不进 messages，无递归。
- 写回：摘要作为**一条 user 消息**插在保护点（保留区第一条之前），前缀机器话 `[earlier work summary]`。SYSTEM 不动，不删消息，不拆 tool 对。
- 兜底：摘要调用非 0（含 73）或 content 为空 → 放弃摘要，照旧只清，stderr 仍 `compact: pruned`；成功则 `compact: summarized`。
- 摘要是**对话状态**，不写进 `.agent-memory`（那是项目记忆，两种状态不混）。

## 4. 成本与风险

- 每次压缩多一次小调用（DeepSeek 的 thinking 已禁，非流式）。stub 驱动的离线测试里摘要调用吃 stub 回包，无害。
- 摘要幻觉：提示词约束「只复述」；真有漏，旧 tool 正文被清但消息壳还在，模型可用 shell 重读文件找回。
- 延迟：交互回合里多一次小请求。可接受；摘要失败的代价只是退回今天的行为。

## 5. 仓库交什么 / 合同

- `build/loop.sh`（摘要函数 + 接进 `agent_compact`）、`build/prompts/compact-summary.txt`（新）、`build/pack.sh`（一行 emit）。
- `tests/seed-package.sh`：旧断言「compact prunes old tool output」不动；机器行匹配 `summarized|pruned`；新增——摘要提示词文件在且被打包、stub 场景 messages 里出现 `[earlier work summary]`、`old tool output cleared` 仍在 loop.sh（兜底没撤）。
- 旧稿状态行加注：模型摘要一条由本稿接替，jq 清除留作兜底。

## 6. 明确不做

- 按 edition 分支压缩行为（种子不点名扩展）
- `hooks.after_turn` / `compact.sh`，任何形式的 plugin 压缩（维持已撤）
- `/compact` 人命令（以后要，也是 commands 提示词的事，不在本稿）
- 初始化里压（维持）
- 摘要的摘要、多级压缩结构
