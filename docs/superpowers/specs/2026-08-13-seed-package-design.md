# seed.sh 三舱安装包设计

- 日期：2026-08-13
- 状态：已实现（离线 `tests/seed-package.sh` 通过）
- 范围：重写 `seed.sh` 为无头安装包；产物是可交互的 shell coding agent

## 1. 要解决什么

现在的 `seed.sh` 把 loop、提示词、验收、刷屏搅在一个近 900 行文件里；对人直播模型正文；用 `<ACTION>` 文本协议；还教产物去做一套和种子不同的工具。

改成：一个文件、三块舱、装的时候仍叫模型，但不聊天。装出来的 `bin/agent` 是给人编程用的交互窗口。种子和产物共用同一对工具、同一个 loop 形状。

## 2. 两层

| | 种子 `seed.sh` | 产物 `bin/agent` |
|---|---|---|
| 对人 | 无交互。不叫模型。最多 `installed:` | `sh bin/agent` 进窗口；只有 `>`、用户输入和最后回答 |
| 对模型 | 要。CLI 与现在相同 | 要。读已存的凭据 |
| 工具 | 持久 shell + edit | 同一对 |
| 协议 | API `tool_calls` | 同一套 |
| 工作区 | 安装目录 `$INSTALL` | **启动 `bin/agent` 时的当前目录**，禁止写死绝对路径 |

不采用「每条任务让模型写一整段 controller、自己再调 llm」的极端方案。外壳拥有固定循环。

## 3. 单文件三舱

`seed.sh` 仍是一个可执行文件。激活后在内存里拆成三块，不先在磁盘上摊源码：

```text
seed.sh
  ├─ LOOP     固定循环：带 tools 问模型 → 执行 tool_calls → 把结果喂回
  ├─ SYSTEM   给「正在安装的模型」的英文说明
  └─ TASK     任务：在 $INSTALL 装好可交互的 coding agent
```

改提示词只改 SYSTEM / TASK，不动 LOOP。

## 4. 启动

与现在相同：

```text
sh seed.sh deepseek <API_KEY>
```

- 渠道：`deepseek` | 完整 URL
- 安装目录：永远是调用时的当前目录。没有第三参数。多传路径 exit 64
- 续跑：`sh seed.sh`，凭据从当前目录 `.env` 读。不写进 usage

缺 curl / jq：exit 69。参数不对：exit 64。

## 5. 凭据：当前目录 `.env`

用户在种子阶段已经输入 key，种子把它写进**调用 `seed.sh` 时所在目录**的 `.env`，供以后复用。

格式（示例，deepseek）：

```text
LLM_PROVIDER=deepseek
LLM_API_URL=https://api.deepseek.com/chat/completions
LLM_MODEL=deepseek-v4-flash
LLM_API_KEY=sk-...
```

约束：

- 文件权限 600，目录不因此改成 777
- 种子启动时若当前目录还没有 `.gitignore` 对 `.env` 的忽略，则追加一行 `.env`（已有则不动）
- 同一份内容也写到 `$INSTALL/.env`（权限 600），这样即使用绝对路径调用 `bin/agent`、当前目录没有 `.env`，也能找到 key
- `bin/agent` / `bin/llm` 读凭据顺序：进程环境变量 → 当前目录 `.env` → `$INSTALL/.env`
- 证据、日志、stdout/stderr **不得**出现 key 或 Authorization 头
- 不要把 key 写进 `bin/agent` 源码

`$INSTALL/config` 不再作为主存放处；若实现时需要一份给旧 shim 读的文件，必须从 `.env` 生成且同样 600，不得成为第二套手写来源。

## 6. 两个工具

模型只能通过 `tool_calls` 调用这两项。没有 parse-reply、没有 `<ACTION>`、没有围栏兜底当协议。

### 6.1 持久 shell（对外仍可叫 bash）

- 背后一个**不退出**的本机登录壳。启动时探测 `$SHELL`，没有则 `/bin/sh`。Darwin 上通常是 zsh，Linux 上通常是 bash。不是去改系统自带的 bash 二进制。
- 每次调用：一条命令。返回 stdout、stderr、退出码、执行后的 cwd。
- 同一段会话共用该进程：`cd`、`export`、虚拟环境下一轮还在。
- 种子装的过程 = 一段会话。`bin/agent` 从打开到退出 = 一段会话。两条任务之间若在同一次 `bin/agent` 进程里，也共用这个 shell。
- stdin 关掉，避免命令停着等输入。
- 超时、输出截断用 POSIX `sleep`/`dd`/`ps`，不依赖 `timeout(1)`、perl、python。默认超时 180s，输出上限 16KiB，超出标明截断。
- 种子按本机特化出这个工具之后，**自己立刻用它**，再把同一份写到 `$INSTALL/bin/`。

### 6.2 edit（精确替换）

- 参数：路径、旧文本、新文本。旧文本必须在文件中**唯一**匹配，否则失败、不改文件。
- 看文件、列目录、跑测试、新建文件：全部走 shell（`cat`、`ls`、`git`、`cat > file`）。
- 不按 GNU/BSD 假设 `sed -i`。种子自带的 edit 用 `/bin/sh` 调 `jq` 做唯一匹配。
- 种子同样：先特化，自己用来写 `bin/agent`，再落到 `$INSTALL/bin/`。

## 7. LOOP

对种子和产物都成立：

1. messages 以 SYSTEM 开头，再加当前用户这句话
2. 请求带 `tools`：shell、edit；`stream:false`，一次完整 JSON
3. 若有 `tool_calls`：按顺序执行，把每项结果以 tool 角色喂回，继续
4. 若没有 tool_calls、只有一段文本：这一轮就是「最后回答」，印给用户
5. 轮数上限：产物每条任务默认 20，可环境变量覆盖
6. 超限：产物印英文 `round limit reached; task unfinished`，不崩掉整个窗口

安装不跑 LOOP。不把 content / reasoning 打到终端。没有 token 心跳。证据里保存 usage。

## 8. 提示词

对模型：英文。种子不对人说话（stderr 用英文状态/错误）。产物打开就是 `>`，最后回答给人看。没有开场白。

安装不叫模型：写 `.env`、写 shim、磁盘验收。

**产物打开**：只印 `>`。空行或 Ctrl-D 退出。没有开场白。

**产物 SYSTEM**：你是 coding agent。只有 shell 和 edit。shell 跨轮持久。工作区是启动时的当前目录。过程不要往终端倒；最后用一段话回答用户。

## 9. 工作区

- 种子干活：从 `$INSTALL` 开始（要写安装产物）。
- 产物干活：`sh bin/agent` **被调用时的 `$PWD`**。换项目就先 `cd` 再开 agent。
- 任何生成的脚本、提示词、默认值都不得嵌入某台机器的绝对路径。

## 10. 装完验收（种子自己看，不信模型）

写完 shim 后必须同时满足，否则 exit 76，并写明缺哪一项：

1. `$INSTALL/bin/agent`、`llm`、持久 shell、`edit` 存在，且用本机 shell 语法检查通过
2. 调用 seed 的当前目录有 `.env`（600），`$INSTALL/.env` 也有；字段能读出 key（验收时只检查「非空且文件权限」，不把 key 印出来）
3. 种子用**假的**一轮 tool_calls（不联网）驱动产物：必须在 `$INSTALL` **之外**的临时目录里启动 agent；能接到 shell 或 edit；工作区是那个临时目录；源码里没有写死的本机绝对路径（运行时探测到的 `$INSTALL` 除外）
4. `sh bin/agent` 无参数只有 `>`，没有开场白；stdin 给 EOF 后干净退出

不在安装结束时跑真模型黑盒任务。真模型留给用户之后在自己的项目目录里用。

中途失败退出码：64 参数 / 69 缺工具 / 71 网络 / 72 HTTP / 77 Key 拒 / 75 轮数 / 76 验收没过。

## 11. 证据

每次种子运行：`$INSTALL/.runs/<utc>-<pid>/`

每次产物任务：调用目录下 `.agent-runs/<utc>-<pid>/`（或 `$INSTALL/.runs` 若调用目录不可写——优先调用目录）

至少有：messages 快照、原始模型响应、每次 tool 的参数与结果、usage、退出码。无 key。

## 12. 装好后的目录

```text
$INSTALL/
  bin/agent      交互入口
  bin/llm        调模型（读 .env）
  bin/shell      持久 shell 包装（实现名可不同，契约不变）
  bin/edit       精确替换
  .env           凭据 600
  .runs/         种子证据
```

调用 seed 的当前目录：`.env`（600）。

## 13. 明确不做

- 极端「无固定 loop、模型生成 controller」
- 种子 REPL、直播思考 / 模型正文
- 工具动物园（read/grep/glob/todo/subagent 等）
- 第一阶段沙盒 / 凭据 broker（key 在用户自己的 `.env` 里，文档不声称纯 shell 能对模型藏住 key）
- 统一 Bash 5 容器；跟宿主 shell 走
- 把工作区写死成某一台机器上的路径
- `seed.sh` 和 `bin/agent` 的主 loop、以及种子自带的 shell/edit：只用 `/bin/sh` + curl + jq。之后模型在工作区里长出的脚本、工具、扩展不限语言

## 14. 成功标准

- `sh seed.sh deepseek <key>` 能在不叫模型的情况下装完，终端最多一行 `installed:`
- 之后在任意项目目录 `sh bin/agent` 进入交互窗口，没有开场白、过程不刷屏、能靠 shell + edit 改当前目录里的文件
- 换到另一台 Linux 机再跑同一颗种子，特化出的是那台的 shell，产物不携带本机绝对路径
