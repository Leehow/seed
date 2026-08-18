# slab — 给改这个仓库的人

slab 是一个实验：**POSIX `/bin/sh` 能不能撑住一个带工具的 coding agent。**  
不是再做一个 Claude Code。不是用 Python 写 loop 再套一层 `sh`。

人要带走的是打好的 **`seed.sh`**。安装把同一套 loop 写进 `bin/agent`，之后可以丢掉安装器；模型不另写一套程序。模型在某个工作区里长出的网页、脚本、项目代码，属于那个工作区，不属于种子。

理念长文：[docs/理念与设计.md](docs/理念与设计.md)  
安装契约：[docs/superpowers/specs/2026-08-13-seed-package-design.md](docs/superpowers/specs/2026-08-13-seed-package-design.md)

---

## 硬约束（破了实验就作废）

1. **`seed.sh` 和 `bin/agent` 的主 loop，以及种子自带的两个工具，只用 `/bin/sh` + curl + jq。** 禁止 python / perl / ruby 实现这层。
2. **工具只有两个，走 API `tool_calls`：** 持久 shell、精确替换 edit。没有 `<ACTION>`、没有 parse-reply、没有工具动物园。
3. **工作区 = 启动 `bin/agent` 时的 `$PWD`。** 禁止把 `/Users/`、`/home/` 或任何本机绝对路径写进产物。
4. **一份 POSIX 种子，跟宿主 `$SHELL` 走。** 不要为 Mac / Linux 维护两套，不要假设 Bash 5，不要用 `sed -i`、`head -c`、`pgrep`、`timeout(1)`。
5. **外壳拥有循环。** 不要改成「每条任务让模型写一段 controller 再自己调 llm」。
6. **种子对人零交互。** 安装不叫模型。状态和错误用英文机器话（`error:`、`installed:`）。产物第一次打开先 `initializing:`，就绪后直接 `>`；首个交互轮按需构建提示词包（资源索引、命令表等），没有 edition 选择。对话显示用户输入、带工具轮的过程说明、工具行和最后回答；终稿只印一次。
7. **不信模型口头说装好了。** 种子自己看磁盘验收。安装只写文件、写 shim、验磁盘。
8. **之后不限制语言。** 模型在工作区里写什么都行。那是产物在干活，不是外壳作弊。
9. **增量开发。** 只往上加。已经有的功能、可见行为（包括初始化/对话 SSE）默认留下。要拿掉或换成更“干净”的替代，必须先问人，点头再改。修 bug 靠补，不靠删。
10. **种子只产最小 agent。** 安装写出 loop + shell + edit + 通用 plugin 加载。`bin/agent` 出来之后，后续能力（`/`、模型台、skill、插件目录）都由产物里的模型自己构建。界面就是 `sh bin/agent`，不要再长一层 TUI。线上 agent plugin **只是提示词**，不交实现脚本。不要为新能力加厚 `seed.sh` / `build/product.sh`，也不要在 `plugins/agent/` 里代写启动器。种子可以跑 catalog 的通用 `hooks`，不能点名某个扩展。Mac / Linux / Windows 要各写一份外壳，种子一厚三份都要抄；扩展用提示词，模型在当前平台上自己想办法。

---

## 仓库里什么是什么

| 路径 | 角色 |
|---|---|
| `seed.sh` | **打包态 / 运行时。** 用户跑的就是它。测试也打它。 |
| `bin/agent` | 安装写出的产物引擎（自带 loop）。仓库里的 `bin/*` 仍是开发用薄入口。 |
| `bin/{edit,llm,shell}` | 指向 `bin/agent` 的薄入口。 |
| `tests/seed-package.sh` | 离线合同。不联网。必须绿。 |
| `build/` | **设计源。** loop、提示词、任务、工具实现分开放。改种子请改这里，再 `sh build/pack.sh`。 |
| `plugins/` | **扩展提示词。** agent / seed 目录。换能力改提示词，不改厚种子，不在这里预置实现。 |
| `docs/` | 给人读的理念和规格。 |
| `.env` | 本机钥匙。不进 git。日志和证据里不得出现 key。 |

不要提交：`.env`、`.agent-runs/`、`.runs/`、以及模型在这个工作区里随手造的项目文件（例如根上的 `index.html`）。

---

## 源码和打包态

已拍板：

- **在 `build/` 里设计。** 最小 loop、system prompt、安装目标、产物提示、edit、持久 shell，各是各的文件。
- **`seed.sh` 是最终打包态。** 换机器、给人用、跑测试，都只认这一份。
- **改完必须先打包，再跑、再测。** 不从 `build/` 直接当运行时，避免「源码能跑、打出来的跑不动」。

**禁止手改 `seed.sh`。** 改 `build/`，跑 `sh build/pack.sh`，再跑 `/bin/sh tests/seed-package.sh`。测试会核对打包结果和仓库里的 `seed.sh` 是否一致。对不上就先重新打包，不要在打包态上打补丁。

打包器本身也用 `/bin/sh`。它是作者工具，打出来的 `seed.sh` 仍须单独可跑：对方机器上没有 `build/` 也能 `sh seed.sh`。

拆分（不要另长一套）：

```text
build/
  pack.sh                 # 拼出仓库根上的 seed.sh
  loop.sh                 # 问模型 → 执行 tool_calls → 喂回
  model.sh                # curl + jq 拼请求、收 SSE
  edit.sh                 # 唯一字符串替换
  shell.sh                # 持久登录壳
  env.sh                  # .env、渠道、探测
  install.sh              # 写出 bin/agent、磁盘验收、安装入口
  product.sh              # agent plugin、初始化、两棵树
  agent.sh                # 给人用的窗口
  prompts/
    product-system.txt    # 产物 SYSTEM
    compact-summary.txt   # 压缩摘要提示词（清旧 tool 前先摘要）
    tools.json            # 两个 tool 的 schema
```

提示词和 loop 必须能分开改。改脾气改 `prompts/`，改骨架才动 `loop.sh`。

---

## 怎么跑

依赖：`/bin/sh`、curl、jq。Linux、macOS、WSL、Git Bash 可以。原生 cmd / PowerShell 不行。

```sh
sh seed.sh deepseek sk-xxxx    # 装到当前目录，写 .env
sh seed.sh api.example.com/v1 sk-xxxx my-model   # 任意 URL：补 https 并规整到 chat/completions；第三参是模型（可省）
sh seed.sh --global deepseek sk-xxxx   # 装到全局：~/.local/bin/seedagent，家 ~/.seed-agent
sh plugins/serve.sh            # 本地 plugin 根 http://127.0.0.1:7432
sh seed.sh qwen sk-xxxx        # 非内置渠道：拉 seed/index.json → models → 选一次
sh bin/agent                   # 交互；工作区是当前目录
sh bin/agent "任务"            # 一次性
/bin/sh tests/seed-package.sh  # 离线验收，改完必跑
```

种子默认 plugin 根 `https://pipi.aichattrpg.com/downloads/slab`（测试和本地 `sh plugins/serve.sh` 可用 `SEED_PLUGIN_ROOT` 覆盖）。安装只拉 seed 目录。`deepseek` 和完整 URL 不查目录。`bin/agent` 第一次打开才拉 `<根>/agent/index.json`，跑初始化，写 `agent-store/`。

用法只有这一行。不要安装目录参数，永远是当前目录。多传路径直接退出。只写 `sh seed.sh deepseek`（没有 key）必须报错要 key。`.env` 已在时可以 `sh seed.sh` 重装，但不必写进 usage。

换项目：先 `cd` 再开 `bin/agent`。它改的是启动时的当前目录，不是 slab 仓库。

换机器：拷仓库，自己准备 `.env`，不要带着旧电脑的绝对路径。

---

## 怎么改（对照）

```sh
# 错：在 loop / SSE / edit 里请 Python 代打
# 对：/bin/sh + jq

# 错：把工作区写死成 /Users/你/code/slab
# 对：启动时的 $PWD；shim 用 dirname 找 seed.sh

# 错：给模型加 read / grep / glob / todo
# 对：只有 shell + edit；看文件用 shell 的 cat

# 错：种子装的时候跟人聊天、直播思考、叫模型
# 对：写 .env 和 shim，验磁盘，印 installed:

# 错：手改打包好的 seed.sh 补一刀
# 对：改 build/，再 sh build/pack.sh

# 错：验收写死本机路径，或在安装目录里跑假 stub
# 对：假 tool_calls 必须在 $INSTALL 之外的临时目录跑

# 错：没问就把已有 SSE / 初始化过程流关掉，改成计数心跳
# 对：旧行为留下；要删先问；同意之前只加能力

# 错：把机器图谱、检索正文、某家搜索、TUI 写进 product.sh 或 plugins/agent/*.py
# 对：线上 plugin 只是提示词；bin/agent 出来后由模型在本机写实现；清旧 tool 写在 loop.sh
```

改完至少跑：

```sh
/bin/sh tests/seed-package.sh
```

测的是打包后的 `seed.sh`，不是 `build/` 散件。有真 Key、要确认没跑偏时，再在临时目录里 `sh bin/agent --oneshot '...'`。不要在仓库根上随手留模型产物。

---

## 两层不要混

| | 种子 `seed.sh` | 产物 `bin/agent` |
|---|---|---|
| 对人 | 不说话；stderr 最多英文状态 | `>` + 最后回答 |
| 工作区 | 安装目录 | 启动时的当前目录 |
| 工具和 loop | 同一对、同一个形状 | 同一对、同一个形状 |
| 扩展 | 不写。只留通用 hooks | 打开后拉提示词，自己在本机构建 |

安装时模型**不**为这台机器重写工具。工具已经在种子里。特化只有一件事：持久 shell 拉起本机 `$SHELL`（没有则 `/bin/sh`）。

---

## 提交

用户没说「提交」就不要 commit、不要 push。  
可以提交：`seed.sh`、`build/`、`bin/*`、`tests/`、`docs/`、本文件。  
不要提交：`.env`、证据目录、模型在工作区里造的无关文件。
