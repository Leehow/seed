# 项目级记忆系统：memory tree v2

- 日期：2026-08-16
- 状态：已拍板
- 前序：[参考 Prime Agent](2026-08-16-delegate-refine-design.md)、[检索树](2026-08-14-retrieve-index-design.md)、[可选初始化](2026-08-15-seed-agent-optional-init-design.md)

## 1. 要解决什么

项目记忆现在只有形状：`{notes:[], facts:[]}` 两个空数组，retrieve 一句「开工前 jq」教读，`/refine` 一段教写。没有条目结构、没有生命周期、没有长短分工、没有卫生规则。参考 Prime（durable state + 显式 `/refine`）和 Claude Code（目录索引 + 主题文件），把 v2 定下来。

原则不变：**纯提示词级**。引擎只放空树，不验收内容；读写都是模型的 jq 纪律。

## 2. 磁盘形状

```text
$PWD/.agent-memory/
  index.json            目录，机器读（jq）
  notes/<slug>.md       长条目正文，人可读
  snapshots/<utc>.json  每次写入前的回滚点
```

`index.json` v2，`notes` / `facts` 两数组保留，元素从字符串升级为对象：

```json
{"title": "一行", "kind": "lesson|preference|decision", "text": "短正文", "source": ".agent-runs/<dir>", "utc": "...", "ok": true}
```

长条目把 `text` 换成 `"path": "notes/<slug>.md"`。更新不原地改：旧条 `ok=false` + `superseded_by` 指向新条 title。

分工：

- **facts**：项目客观事实——怎么构建、怎么跑测试、目录约定。发现即记。
- **notes**:`kind` 区分 lesson（人的纠正、返工点）、preference（「以后都…」）、decision（拍板的技术选型及原因）。
- 短条（≤280 字符）内联 `text`；长条正文落 `notes/<slug>.md`，条目带 `path`。

## 3. 读

retrieve 已有「开工前 jq Project memory」一句，细化出长短分工：按 `title` 匹配人话；命中且条目带 `path` 才 cat 那个文件；不整个 cat（旧句保留）。v1 的字符串条目不迁移，匹配时按整条文本对待——措辞上兼容，不另写迁移。

## 4. 写

- 三个入口：`/refine` 显式精炼（照旧）；人在对话里明说「记住 / 以后都 / 别再」时随手记一条；init 放空树，不预填。
- 写前快照（`snapshots/<utc>.json`，照旧）。
- 写前查重：jq 现有 title，同义就更新（supersede），不新增。
- 卫生：`/refine` 时 notes+facts 总数 > 50，先合并再新增。
- 禁存：key / `sk-` 任何东西、`/Users/` `/home/` 本机绝对路径、源码大段、一次性任务状态（那是对话摘要的事）。

## 5. 迁移与验收

- `init.json` 的 `memory_tree` 模板 `version` 升 `"2"`，仍空数组。引擎只在缺失时放树（`agent_place_trees` 不动）；老工作区的 v1 树不刷（`--update` 本来就不碰 memory_tree）。
- 外壳不验收记忆内容——不信嘴也不查，和 skills 一致。形状由 `/refine` 的检查项 jq 断言：每条有 title、`text` 或 `path`、utc、ok；全文件无 `sk-`。
- 落点：`init.json`（模板 bump + retrieve 细化一句）、`commands.json`（`/refine` 的写入规则细化 + 检查项）。全是提示词。

## 6. 仓库交什么 / 合同

- `init.json`：`memory_tree.version=="2"`；retrieve 加 title/path 分工措辞。
- `commands.json`：`/refine` 的 use 写明 kinds、快照、查重、supersede、50 条卫生、禁存清单。
- `tests/seed-package.sh`：模板 version 断言、retrieve 含 path 句、commands 含 kinds / 卫生 / 禁存（含 `sk-` 与 `/Users/`）；旧断言「refine command and memory read loop」不回归。
- 不测模型真写了什么记忆。内容质量是线上的事。

## 7. 明确不做

- 全局 / 跨项目记忆层（产物不携带住址；换项目另一份是特性）
- 每次任务后自动沉淀（显式 `/refine` 或人明说才写，防噪声）
- 引擎验收记忆内容、embedding / 向量检索（jq 匹配人话关键词够用）
- 把对话压缩摘要写进记忆（见[压缩 v2](2026-08-16-summary-compact-design.md)，两种状态不混）
