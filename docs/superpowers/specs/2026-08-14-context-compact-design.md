# 上下文压缩：after_turn 两层压

- 日期：2026-08-14
- 状态：已拍板
- 前序：[产物 agent](2026-08-14-agent-product-design.md)、plugin 扩展规则

## 1. 要解决什么

messages 只增不减。单次 tool 已有 `MAX_OBS_BYTES`，整段对话仍会顶满窗口。需要自动压，不新增 `tool_calls`。

## 2. 谁写、写哪

| | 做法 |
|---|---|
| 种子 | 通用 `hooks.after_turn`：每轮模型返回后（以及下一轮开始时若已有上次 `prompt_tokens`）跑本地脚本。可应脚本之请再跑**一轮不带 tools** 的补全。初始化不跑。 |
| plugin | `plugins/agent/compact.sh`：阈值、清旧 tool、摘要提示、拼回 messages |
| 触发 | 上一轮 `usage.prompt_tokens`（或 `input_tokens`）≥ 窗口 × 0.70 |
| 窗口 | 默认 128000；catalog `context_window` 或 `SLAB_CONTEXT_WINDOW` / `LLM_CONTEXT_WINDOW` 可改 |

种子不点名 compact 算法（不写 stub 正文、不写摘要模板）。

## 3. 两层

1. **清旧 tool。** 保护 SYSTEM。若至少 2 条 user，保护从倒数第 2 条 user 起；否则保护从倒数第 2 个带 `tool_calls` 的 assistant 起。更早的 `role=tool` 且正文超过 200 字符，收成 `[old tool output cleared]`。不删消息，不拆 tool 对。摘要失败时这一层留下。
2. **模型摘要。** 摘要请求用**清之前**的中间段：超过约 2400 字符的 tool 只留头 1500 + 尾 800，短事实（文件头的 `MARKER_*`、尾部 block 行）还在。再叫一轮、不带 tools。结果插成一条 user，前缀 `[CONTEXT COMPACTION — REFERENCE ONLY]`。中间段删掉。摘要不打给人。提示词要求 Critical Context 逐字抄短事实，禁止把已经出现的值写成 unknown。

过线则两层都走。stderr：`compact: pruned` / `compact: summarized`。

## 4. 失败

摘要失败留下第一层。连败 2 次停止自动压。API 报上下文超限：强制压一次再重试，最多一次。

## 5. 明确不做

`/compact`、Grok 服务端 blob、第三种工具、关 SSE、初始化里压。
