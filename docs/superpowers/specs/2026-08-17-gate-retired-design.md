# 门退场：一次构建，人人都是 seed-agent

- 日期：2026-08-17
- 状态：已拍板
- 前序：[可选初始化](2026-08-15-seed-agent-optional-init-design.md)（门由此退场）、[资源索引](2026-08-17-resource-index-design.md)

## 1. 为什么退

资源索引（探测-登记-使用）成了必选 init 的基础能力后，「简单 / 完整」的 fork 失去存在理由：能力不靠选边长，靠索引按需长。用户拍板：构建一次成 bin/agent 就行，不再问。

同时全局命令定名 `seed-agent`（`~/.local/bin/seed-agent`，家 `~/.seed-agent`）——edition 概念退场后，这个名字归还给产品本身。注意：当年砍掉的只是 `bin/seed-agent` 这个 **TUI 启动器程序**（第二个程序），不是这个名字。

## 2. 退了什么

- `init.json` 的 `ask` 字段（中文选项问句）删除
- 引擎的 `agent_print_ask`（product.sh）及其调用点（agent.sh）删除
- retrieve 的 edition 门整段改写：不再写 `ours.edition`，不再问
- `agent_state_lines` 不再往 SYSTEM 里印 Edition 行
- SYSTEM 新增永远在场的 key 纪律：不读 `.env`、不把 key 放进命令/文件/消息，子代理自己从 `.env` 拿凭据

## 3. 现在的行为

- 打开就是 `>`（任何时候都不问）
- 块**按需懒构建**：任务需要哪块建哪块（`/` 先要 commands 块，模型台要 models 块，以此类推）；oneshot 永不构建；不为不需要的块拖延任务
- 首交互轮不再承担全量构建
- `/` 开头：按命令表做；表不在就先建 commands 块
- 已有安装：`--update` 把新 retrieve 刷进活树（catalog 31）

## 4. 合同改动

- 「不点名扩展」断言收窄回本意：loop 与产物 SYSTEM 零提及；product.sh 不许出现扩展文件名 / catalog 键；入口路径推导（`*/bin/seed-agent`、`~/.seed-agent`）允许这个名字
- 门相关断言全部反转：无 ask 字段、引擎无 `agent_print_ask`、打开不印中文选项、retrieve 无 `ours.edition`
- 新增：fake-HOME 全局安装运行时测试（入口/家/工作区三方分离）

## 5. 明确不做

- 不重命名 `ours.seed_agent` 进度键（存量树兼容）
- 不动五块提示词包本身（它们是按需构建的内容，不是门）
- 不清除老树上的 `ours.edition` 残留键（无害，忽略即可）
