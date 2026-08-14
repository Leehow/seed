# 产物 agent：脱离、plugin、预置检索树

- 日期：2026-08-14
- 状态：待实现
- 范围：安装时把 loop 写进 `bin/agent`；打开产物后拉 agent plugin、跑一次初始化、维护两棵 JSON 树
- 前序：[plugin 目录](2026-08-14-plugin-system-design.md) 的 agent 占位由本文接上

## 1. 要解决什么

种子只负责安装：拉 seed plugin（渠道 / 多模型），写出产物，验磁盘，然后歇。人不再跑 `sh seed.sh`，除非删了产物要重来。

人打开的是产物。第一次打开要自动拉 agent plugin、按我们事先设计好的 JSON 树扫机器、建好知识 / 记忆 / 索引入口，然后才出现 `>`。之后不频繁重扫。`rg`、别人的 skill、fetch 只是树上的可用命令，不升格成新 `tool_calls`。

## 2. 两层

| | 种子 `seed.sh` | 产物 `bin/agent` |
|---|---|---|
| 何时 | 安装 | 人 `sh bin/agent` 之后 |
| 拉什么 | 只拉 seed plugin（models） | 只拉 agent plugin |
| 对人 | `installed:` / `error:` | 首次：`initializing:`，然后 `>`；已就绪：直接 `>`。同一窗口里后一句带着前面的 messages |
| loop | 打包源，安装时复制出去 | 自带一份，不再 `exec` 回 `seed.sh` |
| 工作区 | 安装目录 | 启动时的 `$PWD` |

出生证明不变：`/bin/sh` + curl + jq；工具只有 shell + edit；外壳拥有循环。模型不改 `bin/agent` 里的 loop。

重装：删掉产物（`bin/`、`agent-store/`、工作区 `.agent-memory/`）再跑一份还在的安装器。安装器可以是仓库里的 `seed.sh`，不是产物目录里必须再留一份引擎。

## 3. 复制脱离

安装把和种子同一套的循环、两个工具、`parse_turn` 整份写进 `bin/agent`。默认入口是 agent，不是安装器。

`bin/edit`、`bin/llm`、`bin/shell` 是指向 `bin/agent` 的薄入口（`--edit` / `--llm` / `--shell-cli`），不再 `exec` 回 `seed.sh`。

装完可以删掉原来的 `seed.sh`，`bin/agent` 仍能跑。`bin/agent` 用 `dirname` 算安装目录，禁止把 `/Users/`、`/home/` 写进产物。

产物走 SSE：初始化先打 `initializing:`，之后每一轮对话也把模型正在生成的正文打到 stderr，免得人以为卡死。只打 `content`，不打 thinking / `reasoning_content`，也不把这些字段写进下一轮 messages。安装器仍不叫模型。模型不改 `bin/agent` 的 loop。

## 4. 第一次打开

`bin/agent` 用自己的路径得到安装目录。工作区是 `$PWD`。两棵树必须两个名字：有人会在安装目录里开 agent，不能糊成一份。

```text
<安装目录>/agent-store/
  catalog.json              上次拉到的 agent 目录（version + updated）
  plugins/                  必选包正文
  index.json                机器能力 + 我们下发的槽

<工作区>/.agent-memory/
  index.json                这个项目的记忆
```

SYSTEM 只写这两条路径（运行时拼，不烤本机绝对路径的固定值）。正文在磁盘上，模型按需 `cat` / `jq`。

判断「第一次」：安装树不存在，或 `ready` 不是 `true`。

第一次：

1. stderr 打 `initializing:`
2. 本地没有可用 `catalog.json` 就 GET `<根>/agent/index.json`（根仍是 `http://127.0.0.1:7432`，测试用 `SEED_PLUGIN_ROOT` 覆盖）
3. 缺必选包再按目录下标拉正文，落到 `agent-store/plugins/`
4. 把包里的空树模板拷到 `agent-store/index.json`；工作区放空记忆树（写得成就写）
5. 用现有 loop 跑初始化 prompt（会叫模型；离线测试用 stub）
6. 外壳自己看磁盘：机器树仍是预置枝名，且 `ready` 为 `true`，才算出初始化成功
7. 再出现 `>`

以后打开：已 `ready`，直接 `>`，不联网、不重扫。

oneshot 若尚未 `ready`：先走 1–6，再做那条任务。

显式更新：`sh bin/agent --update`。只拉目录。`version` 或 `updated` 与本地 `catalog.json` 不同，才再拉必选正文。不自动重扫机器。拉失败则本地旧货不动，`error:` 退出。普通打开不走这条。

## 5. 目录和预置树

目录和 init 包是 JSON。`hooks` 列出的脚本先落到 `agent-store/plugins/`，再跑本地文件；不把远程正文直接 pipe 给 sh。相对路径相对该文件所在目录。

`<根>/agent/index.json`：

```json
{
  "version": "1",
  "updated": "2026-08-14T00:00:00Z",
  "required": {
    "init": "init.json"
  },
  "optional": {},
  "hooks": {}
}
```

`optional` 这轮只留空对象，不加载。

`init.json`：

```json
{
  "prompt": "English init instructions...",
  "machine_tree": { },
  "memory_tree": { }
}
```

`prompt` 是英文。`machine_tree` / `memory_tree` 就是下面两份空模板。分类写死，模型只填槽，不改枝名。索引库就是这两棵树，不另做数据库。

机器树 `agent-store/index.json`：

```json
{
  "ready": false,
  "version": "1",
  "updated": "",
  "system": {
    "retrieve": "Before acting, jq this index for ok matches. Never cat the entire index. Matching ok skills: cat SKILL.md; follow with shell/edit only.",
    "tools": {
      "sh":     { "present": false, "path": "", "ok": false, "note": "" },
      "curl":   { "present": false, "path": "", "ok": false, "note": "" },
      "jq":     { "present": false, "path": "", "ok": false, "note": "" },
      "rg":     { "present": false, "path": "", "ok": false, "note": "" },
      "git":    { "present": false, "path": "", "ok": false, "note": "" },
      "python": { "present": false, "path": "", "ok": false, "note": "" }
    },
    "web": {
      "fetch": { "ok": false, "name": "fetch", "description": "Fetch a URL as text via curl.", "use": "...", "note": "" }
    },
    "skills": [],
    "other": []
  },
  "ours": {
    "plugins": ["init"]
  }
}
```

记忆树 `.agent-memory/index.json`：

```json
{
  "ready": true,
  "version": "1",
  "notes": [],
  "facts": []
}
```

初始化 prompt 要求：写好 / 保留 `system.retrieve`；用 `command -v` 填 `system.tools`；对每个找到的命令做一次便宜的冒烟测试，只有退出码 0 才把 `ok` 设为 `true`，否则 `ok` 为 `false` 并写 `note`。保留 `system.web.fetch` 和它的 `use`；curl 可用时对 example.com 做一次便宜 GET，HTTP 2xx 才 `ok`。不再保留 websearch 槽。**tools + fetch 写完立刻把机器树 `ready` 设为 `true`**，空的 `skills` 可以。skill 一条一个目录，记 `{name, description, path, ok, note}`：`name` / `description` 从 `SKILL.md` 头抽取，不把正文烤进树；只在 ready 之后用一条脚本尽量扫，扫不完不挡门。预置槽装不下、但测过能用的进 `other`。不扫项目源代码来填记忆树。

SYSTEM 先钉住人的原话（任务就是上一句，不要换成树上的键名），再读机器树并遵守 `system.retrieve`。宿主把 ok skill 的 name+description 写成 `<available_skills>` 附在 SYSTEM 上。问 skill / SKILL.md 时先打开 https://agentskills.io/specification。人问有什么工具 / 能用什么时：再列出（1）API 工具 shell 和 edit，（2）`system.retrieve` 说能用的 `ok` 条目。只答 shell/edit 不算。fetch 只写在 init plugin 的树上，是提示词工具：模型按 `use` 用 shell + curl 执行，不升格成新 `tool_calls`，种子不点名。

检索：`jq` 查固定枝。缺枝就缺。以后加槽：改 plugin 包模板和目录 `version`，不改 loop。

初始化成功的磁盘标准（外壳验，不信模型嘴）：

- 机器树是 JSON
- 顶层有 `ready`、`version`、`system`、`ours`
- `system` 下有 `tools`、`skills`、`other`、非空字符串 `retrieve`
- `ready` 为 JSON `true`
- 预置的六个 tool 键还在，且每项有 `ok` / `present` / `path`

多出来的键可以留。删掉预置枝名 = 失败。

## 6. 失败

英文机器话。证据里不得出现 key 或 Authorization。

| 情况 | 行为 |
|---|---|
| 第一次打开，根连不上 / 目录不是 JSON / 必选 `init` 缺失 | `error: agent plugin ...`，退出，不出 `>`，不写 `ready` |
| 已 `ready`，根挂了 | 照常出 `>`，不联网 |
| `--update` 拉目录失败 | `error:` 退出，本地 `catalog.json` 和两棵树不动 |
| 初始化 loop 失败，或磁盘验收不通过 | `error: init failed`，机器树保持 `ready` 不为 `true`，下次打开再初始化 |
| 记忆树写不进（工作区只读等） | stderr 一行 `error: memory index not writable`；机器树仍可 `ready`，然后出 `>` |

退出码沿用现有：网络 71，HTTP 72，缺件 69，用法 64，初始化 / 验收失败 76。

## 7. 安装验收（种子，不叫模型）

`verify_install` **不**拉 agent plugin、**不**跑初始化、**不**叫模型。

只验：

- `bin/agent` 在、语法过
- 没有 `/Users/`、`/home/`
- `bin/agent` 正文不再 `exec` 回 `seed.sh`
- 用假 `tool_calls` 在安装目录**之外**的临时目录跑通
- 打开只有 `>`：探测时设 `SLAB_SKIP_INIT=1`，不得在安装目录留下 `ready: true` 的假树（否则人第一次打开会跳过初始化）

## 8. 离线合同

扩 `tests/seed-package.sh`，不联网。本地假 HTTP 根 + `SEED_LLM_STUB`。

1. 装完：`bin/agent` 自带 loop；删掉旁边的 `seed.sh` 后，stub oneshot 仍能跑。
2. 缺 `ready`：会拉 `agent/index.json` 和 `init.json`，落下空树；stub 把树填到验收标准之后，再打开（无 `SLAB_SKIP_INIT`）只有 `>`。
3. 已有 `catalog.json` 且 `ready`：假根关掉也能打开。
4. 目录 `version` / `updated` 变了：普通打开不重拉；`bin/agent --update` 才重拉。
5. stub 删掉预置枝名：初始化失败，`ready` 不是 `true`。
6. 证据里没有 key。

改完：`sh build/pack.sh`，再 `/bin/sh tests/seed-package.sh`。禁止手改 `seed.sh`。

## 9. 明确不做（这轮）

- 不把远程 plugin 正文直接 pipe 给 sh（hooks 只跑已缓存的本地文件）
- 不加第三种 `tool_calls`（没有 `retrieve`，没有把 `rg` / skill 升格成工具）
- 不让模型改 `bin/agent` 的 loop
- 不让模型自己写 SSE；流式由外壳打开，且不把 thinking 打到终端或攒进上下文
- 不加载 `optional`
- 不在每次打开时重拉目录、不自动重扫机器
- 安装期不拉 agent plugin、不叫模型
- 种子不解析检索树、不把树正文塞进 SYSTEM
