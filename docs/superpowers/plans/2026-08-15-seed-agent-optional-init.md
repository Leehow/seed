# seed agent 可选初始化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 必选 init 的 retrieve 带上门；catalog 挂可选提示词包；模型自己拉、自己在本机搭 seed agent。种子不动。

**Architecture:** 引擎仍只拉 `required.init`。`optional.seed_agent` 只写在 catalog 里给模型看。六个 JSON 都是 `{ "prompt": "英文..." }`。合同只验字段和措辞，不验模型有没有写出 TUI。

**Tech Stack:** 提示词 JSON、`jq`、现有 plugin 根。离线合同 `/bin/sh tests/seed-package.sh`。

## Global Constraints

- 不改 `build/`、`seed.sh`、loop、工具数；不跑 `sh build/pack.sh`
- 不加第三种 `tool_calls`；引擎不加载 `optional`
- 提示词英文；对人问话用人刚才的语言
- 不把 API key 写进树或提示词例句
- 不往工作区根堆产物；写明安装目录 `agent-store/seed-agent/`
- `product.sh` / `product-system.txt` 不出现 `websearch` 或 `system.web`
- 用户没说提交就不 commit
- 规格：`docs/superpowers/specs/2026-08-15-seed-agent-optional-init-design.md`

## Files

- Modify: `plugins/agent/index.json`（version 18，`optional.seed_agent`）
- Modify: `plugins/agent/init.json`（`machine_tree.system.retrieve` 加门）
- Create: `plugins/agent/seed-agent.json`
- Create: `plugins/agent/skills.json`
- Create: `plugins/agent/commands.json`
- Create: `plugins/agent/models.json`
- Create: `plugins/agent/plugins.json`
- Create: `plugins/agent/tui.json`
- Modify: `tests/seed-package.sh`

---

### Task 1: 合同先红 — catalog 门 + 六份提示词 + 种子不点名

**Files:**
- Modify: `tests/seed-package.sh`（version 17 那段后面、retrieve 那段）
- Test: `tests/seed-package.sh`

**Interfaces:**
- Consumes: 现有 `ROOT`、`BUILD`、`fail` 计数
- Produces: 四条合同名：`agent plugin version 18`、`catalog has optional seed_agent`、`retrieve has seed-agent gate`、`seed-agent prompt pack`、`seed does not name seed-agent`

- [ ] **Step 1: 写会失败的合同**

在 `tests/seed-package.sh` 把 version 检查从 `17` 改成 `18`。在 `retrieve keeps human web queries` 那块**之后**插入（不要删掉 websearch / host 的否定）：

```sh
if jq -e '.optional.seed_agent=="seed-agent.json"' \
  "$ROOT/plugins/agent/index.json" >/dev/null 2>&1; then
  printf 'ok   catalog has optional seed_agent\n'
else
  printf 'FAIL catalog has optional seed_agent\n'; fail=$((fail + 1))
fi
if jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'ours.edition' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'seed-agent' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'only ask' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'oneshot' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'SEED_PLUGIN_ROOT'; then
  printf 'ok   retrieve has seed-agent gate\n'
else
  printf 'FAIL retrieve has seed-agent gate\n'; fail=$((fail + 1))
fi
sa_ok=1
for f in seed-agent.json skills.json commands.json models.json plugins.json tui.json; do
  [ -f "$ROOT/plugins/agent/$f" ] || sa_ok=0
done
if [ "$sa_ok" -eq 1 ] \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'skills' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'commands' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'models' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'plugins' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'tui' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'ours.seed_agent' \
  && jq -r '.prompt' "$ROOT/plugins/agent/skills.json" | grep -q 'agent-store/seed-agent/skills' \
  && jq -r '.prompt' "$ROOT/plugins/agent/skills.json" | grep -q '.agents/skills' \
  && jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q '/models' \
  && jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q '/tools' \
  && jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q '/help' \
  && jq -r '.prompt' "$ROOT/plugins/agent/models.json" | grep -q 'LLM_' \
  && jq -r '.prompt' "$ROOT/plugins/agent/models.json" | grep -q 'do not print' \
  && jq -r '.prompt' "$ROOT/plugins/agent/plugins.json" | grep -q '.seed-agent/plugins' \
  && jq -r '.prompt' "$ROOT/plugins/agent/tui.json" | grep -q 'bin/seed-agent' \
  && jq -r '.prompt' "$ROOT/plugins/agent/tui.json" | grep -q 'bin/agent'; then
  printf 'ok   seed-agent prompt pack\n'
else
  printf 'FAIL seed-agent prompt pack\n'; fail=$((fail + 1))
fi
if grep -q seed-agent "$BUILD/product.sh" \
  || grep -q seed-agent "$BUILD/loop.sh" \
  || grep -q seed-agent "$BUILD/prompts/product-system.txt"; then
  printf 'FAIL seed does not name seed-agent\n'; fail=$((fail + 1))
else
  printf 'ok   seed does not name seed-agent\n'
fi
```

- [ ] **Step 2: 跑合同，确认红在缺字段/缺文件**

Run: `/bin/sh tests/seed-package.sh`

Expected: `FAIL agent plugin version 18`、`FAIL catalog has optional seed_agent`、`FAIL retrieve has seed-agent gate`、`FAIL seed-agent prompt pack`。`ok   seed does not name seed-agent` 可以已经绿。不要改 `build/` 去「修」最后一条。

---

### Task 2: catalog + retrieve 门

**Files:**
- Modify: `plugins/agent/index.json`
- Modify: `plugins/agent/init.json`（只改 `machine_tree.system.retrieve` 字符串末尾，其它字段不动）

**Interfaces:**
- Consumes: Task 1 合同
- Produces: `optional.seed_agent == "seed-agent.json"`；retrieve 含门的英文句

- [ ] **Step 1: 改 catalog**

`plugins/agent/index.json` 全文：

```json
{
  "version": "18",
  "updated": "2026-08-15T06:40:00Z",
  "required": {
    "init": "init.json"
  },
  "optional": {
    "seed_agent": "seed-agent.json"
  },
  "context_window": 128000,
  "hooks": {}
}
```

- [ ] **Step 2: 在 retrieve 末尾追加门（必须是这一段英文）**

现有 retrieve 以 `Do not copy skill bodies into the tree.` 结尾。在它后面加一个空格，再接：

```text
If ours.edition is neither simple nor seed-agent: on an interactive turn, only ask whether to keep the simple agent or expand into seed agent; do not do the task this turn; reply in the human's language. On oneshot, do the task and leave ours.edition unset. If they choose simple, jq-write ours.edition=simple then do the parked task. If they choose seed agent, jq-write ours.edition=seed-agent, jq the local catalog.json optional.seed_agent, GET ${SEED_PLUGIN_ROOT:-http://127.0.0.1:7432}/agent/<that file>, save it under agent-store/plugins/, and follow it. If edition is already simple and the human asks to upgrade, do the same fetch and set ours.edition=seed-agent. Do not rewrite the human's task into index key names. Do not put API keys in the tree.
```

`init.json` 的 `prompt` 仍要求 keep retrieve 与模板一致，不要改 prompt 其它句子。

- [ ] **Step 3: 再跑合同**

Run: `/bin/sh tests/seed-package.sh`

Expected: version 18、catalog optional、retrieve gate 绿。`seed-agent prompt pack` 仍红。

---

### Task 3: 六份提示词

**Files:**
- Create: `plugins/agent/seed-agent.json`
- Create: `plugins/agent/skills.json`
- Create: `plugins/agent/commands.json`
- Create: `plugins/agent/models.json`
- Create: `plugins/agent/plugins.json`
- Create: `plugins/agent/tui.json`

**Interfaces:**
- Consumes: catalog 文件名；plugin 根 URL 规则
- Produces: 每份 `{ "prompt": "..." }`，合同能 grep 到 Task 1 里的短语

每个文件都是一行 JSON 也行，但必须 `jq` 能读。下面是 `prompt` 正文（英文）。写文件时用 `jq -n --arg p $'...' '{prompt:$p}'` 以免手残。

- [ ] **Step 1: 写 `seed-agent.json`**

prompt 必须含 `skills` `commands` `models` `plugins` `tui` `ours.seed_agent`：

```text
You are expanding this install into seed agent. Do not change bin/agent or its loop. Do not add API tools. Use only shell and edit.

Parked human task: the last human message before they chose seed agent. Finish the blocks below first, then do that task.

Plugin root: ${SEED_PLUGIN_ROOT:-http://127.0.0.1:7432}. Fetch with curl into agent-store/plugins/<file>. Files: skills.json, commands.json, models.json, plugins.json, tui.json.

Progress: jq ours.seed_agent on the Machine index (object; missing keys mean not done). Order: skills, then commands, then models, then plugins, then tui. For each name, if ours.seed_agent[name] is not done, GET /agent/<name>.json, follow that prompt, then jq-write ours.seed_agent[name]=done. Resume from the first name that is not done.

Put new files under the install directory agent-store/seed-agent/ unless a block says otherwise. Do not dump project source into the memory tree. Do not print API keys. If a GET fails, tell the human and stop; leave later blocks unset.
```

- [ ] **Step 2: 写 `skills.json`**

必须含 `agent-store/seed-agent/skills` 和 `.agents/skills`：

```text
Build the skill system. Skills follow https://agentskills.io/specification. One skill = one directory with SKILL.md (YAML name and description in the header).

Install-scoped skills: <install>/agent-store/seed-agent/skills/<name>/SKILL.md
Workspace skills: $PWD/.agents/skills/<name>/SKILL.md

Register every readable skill into the Machine index system.skills as {name, description, path, ok, note}. ok true only if the directory is readable and contains a file. Do not copy SKILL.md bodies into the tree.

Create the two root directories if missing. You may add a tiny example skill under agent-store/seed-agent/skills/hello/ that only says how to list skills.

When the human later says /skills: list name+description+ok; install copies or writes a directory; enable/disable flips ok. Until commands.json is done, still write the directories and the tree.
```

- [ ] **Step 3: 写 `commands.json`**

必须含 `/models` `/tools` `/help`：

```text
Build the slash command table at <install>/agent-store/seed-agent/commands.json.

Commands: /help /tools /models /skills /plugins. Each entry: {name, description, use}. use is English for the model: what to jq or run via shell. These are not new API tools.

If the human's message starts with / and there is no TUI, treat it as that command, not as a coding task.

/help lists the table. /tools lists (1) API tools shell and edit (2) every ok Machine-index entry that system.retrieve says to use. /models /skills /plugins follow the later blocks; until those exist, say they are not built yet.

Do not implement a TUI here.
```

- [ ] **Step 4: 写 `models.json`**

必须含 `LLM_` 和 `do not print`（小写即可，合同 grep `do not print`）：

```text
Build model management. Write <install>/agent-store/seed-agent/models.json as a list of {id, provider, api_url, model, note}. Do not store API keys in this file or in the Machine index.

Current model is the LLM_* fields in the install .env (LLM_PROVIDER, LLM_API_URL, LLM_MODEL, LLM_API_KEY, LLM_EXTRA). /models lists the file plus the current LLM_MODEL. Switching or adding a provider updates .env LLM_* via edit or a small shell rewrite. After writing .env, do not print the key; say "key set" only.

If the human adds a provider, ask for url, model, key in the same language they used. Never echo the key back. Never write the key into ours or system.
```

- [ ] **Step 5: 写 `plugins.json`**

必须含 `.seed-agent/plugins`：

```text
Build a Pi-like plugin directory, not a TypeScript runtime and not new API tools.

Install plugins: <install>/agent-store/seed-agent/plugins/<name>/
Workspace plugins: $PWD/.seed-agent/plugins/<name>/

Each plugin is a directory with plugin.json {name, description, ok, use} plus optional SKILL.md or shell scripts. The model follows use with shell and edit only.

Write an index at agent-store/seed-agent/plugins/index.json listing name, path, ok. /plugins lists it; enable/disable flips ok; install clones or copies a git/url tree into one of the two roots, then writes plugin.json.

Do not register new tool_calls. Do not pipe remote script bodies into sh without saving a local file first.
```

- [ ] **Step 6: 写 `tui.json`**

必须含 `bin/seed-agent` 和 `bin/agent`：

```text
Build a TUI launcher at <install>/bin/seed-agent that wraps the existing bin/agent. Do not edit bin/agent's loop. sh bin/agent must still open the simple > prompt.

The TUI should: show the conversation; intercept lines starting with / and handle /help /tools /models /skills /plugins using the files under agent-store/seed-agent/; otherwise send the line to bin/agent as today. Pick a language that exists on this machine (python curses, bubbletea, ink, etc).

If you cannot finish a polished TUI, write a minimal working launcher that still intercepts / and execs bin/agent for normal lines. Tell the human how to start it: sh bin/seed-agent from the install directory.
```

- [ ] **Step 7: 跑满合同**

Run: `/bin/sh tests/seed-package.sh`

Expected: `SEED-PACKAGE PASS`。四条新合同绿；旧的 init / compact / 无 host 仍绿。

- [ ] **Step 8: 提交（仅当人说了提交）**

```bash
git add plugins/agent/index.json plugins/agent/init.json \
  plugins/agent/seed-agent.json plugins/agent/skills.json \
  plugins/agent/commands.json plugins/agent/models.json \
  plugins/agent/plugins.json plugins/agent/tui.json \
  tests/seed-package.sh \
  docs/superpowers/specs/2026-08-15-seed-agent-optional-init-design.md \
  docs/superpowers/plans/2026-08-15-seed-agent-optional-init.md
git commit -m "$(cat <<'EOF'
加上 seed agent 可选初始化提示词：retrieve 先问，模型自己拉包搭完整版。

EOF
)"
```

---

## Self-review

| 规格 | 任务 |
|---|---|
| §3 门 / oneshot / 升级 | Task 2 retrieve 正文 |
| §4 catalog optional + URL | Task 2 index.json；retrieve 含 SEED_PLUGIN_ROOT |
| §5 调度顺序与进度 | Task 3 seed-agent.json |
| §6 五块磁盘与 `/` | Task 3 各文件 |
| §7 失败续跑 | seed-agent.json GET fail；进度键 |
| §8 合同 | Task 1 |
| §9 不改种子 | Task 1 最后一条；Global Constraints |
