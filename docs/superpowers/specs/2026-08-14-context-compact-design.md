# 上下文压缩：loop 里 jq 清旧 tool

- 日期：2026-08-14
- 状态：已拍板（只留一层 jq；模型摘要和 plugin 已撤）
- 前序：[产物 agent](2026-08-14-agent-product-design.md)

## 1. 要解决什么

messages 只增不减。单次 tool 已有 `MAX_OBS_BYTES`，整段对话仍会顶满窗口。清旧 tool 正文是 loop 自己的事，和截断输出一类，写在种子里。不新增 `tool_calls`，不再打第二轮摘要。

## 2. 谁写、写哪

| | 做法 |
|---|---|
| 种子 `build/loop.sh` | `agent_compact`：过线后用 jq 把保护区以前的长 tool 收成 `[old tool output cleared]` |
| plugin | 不写压缩。catalog 可带 `context_window` 数字 |

触发：上一轮 `usage.prompt_tokens`（或 `input_tokens`）≥ 窗口 × 0.70。窗口默认 128000；catalog `context_window` 或 `SLAB_CONTEXT_WINDOW` / `LLM_CONTEXT_WINDOW` 可改。初始化不压。API 报上下文超限：强制清一次再试，最多一次。

## 3. 一层

保护 SYSTEM。若至少 2 条 user，保护从倒数第 2 条 user 起；否则保护从倒数第 2 个带 `tool_calls` 的 assistant 起。更早的 `role=tool` 且正文超过 200 字符，收成 `[old tool output cleared]`。不删消息，不拆 tool 对。stderr：`compact: pruned`。

## 4. 明确不做

模型摘要、`hooks.after_turn`、`complete-request`、`/compact`、第三种工具、关 SSE、初始化里压。
