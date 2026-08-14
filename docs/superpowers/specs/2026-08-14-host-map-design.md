# 机器图谱：init 后写 host 枝

- 日期：2026-08-14
- 状态：已撤销。扫机器这类事交给工作区里模型自己写的扩展，不进种子、不进 agent plugin。
- 前序：[检索树](2026-08-14-retrieve-index-design.md)、[产物 agent](2026-08-14-agent-product-design.md)

## 1. 要解决什么

初始化已经在记本机工具和 skill。人还要一张**这台电脑的短图谱**：什么机器、什么配置、家目录下一层有什么、常见工作区里有哪些 git 项目、能不能写、有没有免密 sudo。记进机器树，日常对话能 jq，SYSTEM 带几行摘要。

不扫全盘。不读项目源码。不把图谱做成第三种 API 工具。ready 仍先写，图谱补不上不挡门。

## 2. 谁写、写在哪

| | 做法 |
|---|---|
| 谁写 | **agent plugin 的 `host.sh`**。不用模型填，避免再把树写歪 |
| 写哪 | 机器树顶层 `host`，和 `system` / `ours` 平级。不进记忆树 |
| 何时 | tools + fetch 写完、`ready` true 之后。缺枝或 `host.ok` 不是 true 时下次打开再补一次 |
| `--update` | 不重扫 `host`。只换 plugin 正文 / retrieve / 缓存的 `host.sh` |
| 种子 | 只跑通用 `hooks`：先落到 `agent-store/plugins/`，再 `/bin/sh` 本地文件。不点名 host，不把扫机器写进 `product.sh` |

种子模板带空的 `host`（`ok` false，字符串空，数组空）。运行时按本机填。模板里不写任何本机绝对路径。

模型初始化提示加一句：不要改、不要删 `host`。宿主写完以磁盘为准。

## 3. `host` 形状

```json
{
  "ok": false,
  "kind": "",
  "os": "",
  "arch": "",
  "release": "",
  "cpu": "",
  "mem": "",
  "disk": "",
  "user": "",
  "home": "",
  "home_top": [],
  "projects": [],
  "write": { "home": false, "workspace": false },
  "sudo": false,
  "note": ""
}
```

`projects[]`：`{ "name": "", "path": "", "vcs": "git" }`。

字段怎么来（全是便宜命令，失败写 `note`，不中断）：

| 字段 | 来源 |
|---|---|
| `kind` | `uname -s` 归成 `mac` / `linux` / 原样小写 |
| `os` / `arch` | `uname -s` / `uname -m` |
| `release` | macOS：`sw_vers -productVersion`（没有就空）；Linux：`/etc/os-release` 的 `PRETTY_NAME` |
| `cpu` | macOS：`sysctl -n hw.ncpu`；Linux：`getconf _NPROCESSORS_ONLN` 或 `/proc/cpuinfo` 行数 |
| `mem` | macOS：`sysctl -n hw.memsize` 换成 GiB；Linux：`/proc/meminfo` MemTotal |
| `disk` | `df` 看 `$HOME` 所在卷，记可用空间一行 |
| `user` | `id -un` |
| `home` | 当时的 `$HOME` |
| `home_top` | `$HOME` 下一层目录名。点目录只留已存在的 `.claude` / `.codex` / `.agents`。不列 `.Trash`、不递归 |
| `projects` | 只在这些根里找带 `.git` 的**一层或两层**子目录：`$HOME/leehow/code`、`$HOME/code`、`$HOME/src`、`$HOME/Projects`、`$HOME/Desktop`、`$HOME/dev`，以及启动时的 `$PWD`（若其本身是 git 根）。最多 40 条。`name` 是目录名，`path` 是当时的路径 |
| `write.home` | 在 `$HOME` 里建再删一个临时文件，成功则 true |
| `write.workspace` | 对启动时的 `$PWD` 同样探一次 |
| `sudo` | `sudo -n true` 退出 0 则为 true；没有 `sudo` 或要密码则为 false，不弹密码 |
| `ok` | 至少写出了 `kind`、`os`、`user` 则为 true |

不写：`.env`、API key、`~/.ssh` 私钥内容、每个文件的 ACL、项目源码。`~/.ssh` 若存在，可以在 `note` 里写 `ssh_dir=yes`，不列文件。

## 4. SYSTEM 和 retrieve

plugin 的 `host.sh blurb` 在 skill 目录之外再附一段短英文（有 `host.ok` 才附）：

- 一行：`kind` / `os` / `release` / `arch` / `user`
- 一行：最多 8 个 `projects[].name`，多的写 `+N`

细节仍 `jq` 机器树的 `host`，禁止 `cat` 整棵树。

`system.retrieve` 加一句（英文）：问这台机器、配置、家目录或有哪些项目时，`jq` 顶层 `host`；不要把人的问法改成内部路径名。

种子 SYSTEM 仍不点名 `system.web`。可以点名 Machine index 里有 `host`（和现在点名 Machine index 一样）。

## 5. 初始化顺序（只加）

旧顺序留下：

1. 填 `system.tools` 和 `system.web.fetch`
2. 立刻 `ready` true（skill / host 空着可以）
3. 可选：一条脚本扫 skill

新加：ready 之后引擎跑 catalog 里的 `hooks.after_ready`（当前是 `host.sh`），写入顶层 `host`。和 skill 扫谁先谁后不重要；都挡不住 `ready`。失败只把 `host.ok` 留 false 并写 `note`。

SSE、过程行、两个 API 工具、fetch 槽，都不关。

## 6. 外壳

种子的 `agent_check_machine_tree` **不**点名 `host`。图谱缺了不挡 `ready`。

`agent_repair_machine_tree` 不补 `host`，不把模型删掉的 `system` 整枝复活。缺图谱由下次 `hooks.after_ready` 补。

`hooks.after_ready`：`host.ok` 已是 true 则不重扫；否则补扫一次。

`--update` 不重扫 `host`，不删 `host`。可换缓存的 `host.sh`。

合同测试（离线）：

- 空模板有 `host` 对象和 `ok`
- 假 `$HOME` / 假工作区跑 `host_inventory`：写出 `kind`、`user`、`home_top` 含下一层目录、带 `.git` 的目录进 `projects`
- 种子 / `product.sh` 仍不出现 `websearch` / `system.web` 字面量
- 现有 init / salvage / fetch-only 测试继续绿

agent plugin `version` 升到 `13`。`--update` 把新 `retrieve` 写回已有树，不重扫 skill，不重扫 host。

## 7. 明确不做

- 不递归整个 `$HOME`，不加未点名的工作区根
- 不把图谱升格成新的 `tool_calls`
- 不把 `host` 正文整段塞进 SYSTEM
- 不在种子里写死 `/Users/` 或任何本机绝对路径
- 不关初始化 / 对话 SSE，不把过程行收成心跳
