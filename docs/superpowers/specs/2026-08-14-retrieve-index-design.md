# 检索树接上：init plugin 写协议，种子只留指针

- 日期：2026-08-14
- 状态：已拍板，按此实现
- 前序：[产物 agent](2026-08-14-agent-product-design.md)

## 要解决什么

机器树现在是通讯录：有路径、有 `ok`，日常对话不会去翻，skill 也没有 name/description。对照实验：同一句「用 TDD 写 add」，现在的 SYSTEM 不读树；加一句指针后会 `cat` 索引并打开 `SKILL.md`。

接上是 **初始化 plugin** 的活。种子不解析树、不加第三种 `tool_calls`。

## 两层

| | 种子 / `bin/agent` | init plugin |
|---|---|---|
| SYSTEM | 先钉住人的原话，再读机器树按 `system.retrieve` 做；宿主写入 ok skill 的 name+description | 把协议正文写进树 |
| skill | 不抽元数据 | 从 `SKILL.md` 头取 `name` / `description`，不烤正文 |
| CLI | 仍是 API 的 shell + edit | `ok` 的 tools/other 经 shell 用，不升格 |

## 种子指针

`product-system.txt`（英文，只加不拆）：

- `The task is the human's last message. Do not replace it with Machine index key names.`
- `Before acting, read the Machine index with shell (jq, not cat of the whole file) and follow system.retrieve.`
- 树是通讯录，不是题目。不要把人的问法改写成树上的键名。
- 问 skill / `SKILL.md`：先用 shell 打开 `https://agentskills.io/specification`。

人问有什么工具时：列出 API 工具，再列出 `system.retrieve` 说能用的 `ok` 条目。loop、工具 schema、磁盘验收枝名都不为检索或 web 新开一条。`system.web` / fetch 只写在 init plugin，不进种子 SYSTEM。websearch 槽已撤，上网用 `fetch`（shell + curl）。

宿主在 `product_system()` 里用 jq 抽出 `ok` skill 的 `name` / `description` / `path`，写成 `<available_skills>` 附在 SYSTEM 后面。不烤 skill 正文，不 `cat` 整棵树。匹配是对照这段目录，不是先把人的问题收成内部路径。

## 树上多出来的

`system.retrieve`：一段短英文协议。空模板就带上，初始化可以改、不可以删。内容固定为：

- 任务就是人上一句；不要换成树上的键名。SYSTEM 里若已有 skill 目录，先对照 name/description
- 用 `jq` 按人的原话筛 `ok` 条目，**禁止 `cat` 整棵树**
- `ok` 的 `system.tools` / `system.other` 用 shell 调，不是新 API 工具
- `ok` 的 skill 若 `name` / `description` / `path` 对上任务，则 `cat` 该目录 `SKILL.md`（或同等文件），只用 shell / edit 执行
- 任务需要 URL 或网上近况时：`jq system.web`，对 `ok` 的 `fetch` 按条目里的 `use` 用 shell 执行（提示词工具，不是新 API 工具）
- 不把 skill 正文写进树

`system.skills[]`：

```json
{ "name": "", "description": "", "path": "", "ok": false, "note": "" }
```

`name`：`SKILL.md` YAML `name:`，否则目录名。`description`：YAML `description:`，否则第一行标题，一行。目录可读且至少有一个文件才 `ok`。一条 skill 一个目录，不把父目录当一条。

`system.tools` / `system.other` 形状不变。

`system.web`：提示词工具，不是新 API 工具。空模板就带上，初始化可以改 `ok` / `note`，不可以删 `use`。

```json
{
  "fetch": { "ok": false, "name": "fetch", "description": "...", "use": "...", "note": "" }
}
```

`use` 教模型用已有 `shell` + `curl` GET 一个 URL。二进制不 dump。需要找页时自己 curl 已知官方地址或搜索页，不再单开 websearch 槽。`--update` 只保留 `system.web.fetch`，其它 web 键丢掉。

## 外壳验收

现有标准保留。种子只验：`system` 有 `retrieve` 且是非空字符串。`system.web` 是 init plugin 的枝，种子不点名、不验收。多出来的键可以留。

## 更新

agent 目录 `version` 升到 `11`。`--update` 换 plugin 正文；若本地树已在，且新包里的 `system.retrieve` 非空，把这段写回 `index.json`，不重扫 skill。`--update` 同时丢掉 `system.web` 下除 fetch 以外的槽。打开页面先用人的原话和 URL；skill / SKILL.md 去拉 https://agentskills.io/specification。

初始化顺序：先填 `system.tools` 和 `system.web`，立刻把机器树写成 `ready` true。`skills` 为空可以。skill 只在 ready 之后用一条脚本尽量扫，扫不完也不改回 `ready` false。种子不为此改验收。

模型常把有用的树写成错形状（`skills` 写在顶层、丢掉 `version` / `ours`）。外壳在验收前补合同枝：顶层 `skills` 数组挪到 `system.skills`，缺的 `version` / `ours` / 空 `retrieve` 从 init 模板补回。模型删掉整个 `system` 仍算失败。`ready: true` 但形状不对时，下次打开先修再进窗口，不重跑初始化。

## 明确不做

- 不把整棵树或 skill 正文塞进上下文；ok skill 的 name+description 由宿主写入 SYSTEM
- 不把别人的 skill 正文烤进树
- 不加 `retrieve` 工具
- 不加 `websearch` / `fetch` 的 `tool_calls`
- 不翻译 Claude/Codex 专有工具名；协议写明只用 shell/edit
