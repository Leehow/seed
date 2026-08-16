# 可选初始化：门 + seed agent 提示词包

- 日期：2026-08-15
- 状态：已拍板
- 前序：[产物 agent](2026-08-14-agent-product-design.md)、[检索树](2026-08-14-retrieve-index-design.md)

## 1. 要解决什么

必选 init 之后仍是最小 `>`。人可以选保持简单，或扩展成完整 **seed agent**（TUI、`/`、模型台、自己的 skill、像 Pi 那样的插件目录）。

种子封死。不改 `build/`、`seed.sh`、loop、工具数。引擎继续不加载 `optional`。**`bin/agent` 出来之后，后续全由它构建。** 线上 plugin 只是提示词；没有随包脚本或 TUI。模型自己想办法，用 shell / edit 在本机搭。

## 2. 两层

| | 种子 / `bin/agent` | agent plugin 提示词 |
|---|---|---|
| 必选 init | 照旧拉 `required.init`，验 `ready`，出 `>` | `init.json` 的 `retrieve` 带门 |
| 问人 | 不问、不 stdin | 第一次交互任务：先问完整还是简单 |
| 完整版 | 不读 `optional`，不跑第二套 loop | 模型 `jq` catalog，自己 GET 提示词，按序搭 |

## 3. 门

机器树 `ours.edition`：`simple` | `seed-agent` | 缺省（还没选）。

`system.retrieve` 加（英文，必选 init 模板就带上）：

- `ours.edition` 不是 `simple` 也不是 `seed-agent` 时：先问保持简单还是扩展成 seed agent。这一回合只问，不干活。
- 人选简单：`jq` 写 `ours.edition=simple`，再做上一句任务。
- 人选完整：写 `ours.edition=seed-agent`，`jq` 本地 `catalog.json` 的 `optional.seed_agent`，从 plugin 根 GET 该文件，落到 `agent-store/plugins/`，按它做。
- 已是 `simple`：人以后说要升级，同样拉可选提示词并改成 `seed-agent`。
- oneshot：不先问，先干活，`edition` 留空；下次交互再问。

问话用人刚才的语言。不要把人的任务改写成树上的键名。

## 4. 目录

`<根>/agent/index.json` 增加（引擎仍只拉 `required`）：

```json
"optional": {
  "seed_agent": "seed-agent.json"
}
```

分提示词与调度同级，相对 `agent/`：

```text
seed-agent.json    调度
skills.json
commands.json
models.json
plugins.json
tui.json
```

模型用已有 plugin 根拼 URL：环境变量 `SEED_PLUGIN_ROOT`，没有则 `http://127.0.0.1:7432`。路径 `/agent/<文件>`。拉失败：告诉人，`edition` 保持 `seed-agent`，下次从缺的那块续。retrieve 里写明这一句，不把本机绝对路径写进树。

`--update` 只换必选包和 catalog。可选正文仍由模型按需拉。

## 5. 调度

`seed-agent.json` 是英文提示词，不写实现。顺序：

`skills` → `commands` → `models` → `plugins` → `tui`

进度记在 `ours.seed_agent`（对象，键是块名，值 `done` / 缺省）。缺哪块拉哪块。任务（门之前那一句）还在，各块做完再做。**写了文件不算完**：每块提示词带检查，模型用 shell 跑过才许标 `done`；检查失败则该键留空。

产物落在**安装目录** `agent-store/seed-agent/`，不往当前项目根堆。不改 `bin/agent` 的 loop，不加第三种 `tool_calls`。不把 API key 写进树或对话。

## 6. 各块要长出什么

提示词写清磁盘形状和 `/` 行为。怎么实现由模型自己想办法；仓库不交实现。

| 文件 | 磁盘 | 行为 |
|---|---|---|
| `skills.json` | `agent-store/seed-agent/skills/`；工作区 `.agents/skills/` | 一条一个目录 + `SKILL.md`（agentskills.io）。登记 `system.skills`。`/skills` 列出、装、开、关。 |
| `commands.json` | `agent-store/seed-agent/commands.json` | `/models` `/tools` `/skills` `/plugins` `/help`。没有 TUI 时，以 `/` 开头的人话也按表做。`/tools`：API 的 shell、edit，加上树上 `ok` 的提示词工具。 |
| `models.json` | `agent-store/seed-agent/models.json` | `/models` 列出当前和已存的。切换、加供应商：改 `.env` 的 `LLM_*`，不回显 key。 |
| `plugins.json` | `agent-store/seed-agent/plugins/`；工作区 `.seed-agent/plugins/` | 像 Pi 的目录：一插件一目录，清单 + 提示词/脚本/`SKILL.md`。模型跟着做，不注册新 API 工具。`/plugins` 列出、启用、从 git/url 拷进来。 |
| `tui.json` | 安装目录启动器，例如 `bin/seed-agent` | 罩住现有 `bin/agent`：对话、拦截 `/`、模型/工具/skill/插件屏。模型在本机现场写，仓库不给 TUI 文件。`sh bin/agent` 的简单 `>` 必须还能用。 |

## 7. 失败

| 情况 | 行为 |
|---|---|
| 人选完整，GET 可选提示词失败 | 对人说失败；`ours.edition` 仍是 `seed-agent`；下次再拉 |
| 某一块搭到一半 | `ours.seed_agent` 只记已 `done` 的；下次从下一块续 |
| 人拒绝完整 | `simple`，做搁着的任务 |
| 简单版 | 不拉可选提示词 |

外壳不验收 TUI / skill 目录 / 启动器。不信模型嘴改 `ready`。

## 8. 仓库交什么

只交 `plugins/agent/` 里的提示词和目录字段，以及本规格。**不得**在 `plugins/agent/` 放 `.py` / `.sh` 或其他实现。合同只验：

- catalog 有 `optional.seed_agent`
- `retrieve` 含门（`ours.edition`、先问、oneshot 不先问）以及 plugin 只是提示词
- 六个提示词文件在、调度写明顺序；写明自己发明实现、不要等随包脚本
- `plugins/agent/` 除 JSON 外没有实现文件
- `build/` / `seed.sh` 相对上一拍板版本不为此增挂钩、不点名 seed-agent

不测模型有没有真的写出 TUI。

## 9. 明确不做

改种子、第三种 `tool_calls`、引擎加载 `optional`、用 TS 运行时抄 Pi、关掉简单 `>`、初始化里问（正文仍藏）、oneshot 先问、把 key 写进树、在仓库里代写 TUI / 启动器 / 其它实现给模型拷贝。
