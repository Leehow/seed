# slab — 给维护者

slab 的实验问题是：**POSIX `/bin/sh` 能不能撑住一个带工具的 coding agent。** 它不是 Python/Node agent 外面套一层 shell。

根 [`seed.sh`](seed.sh) 是仓库当前的**唯一产品、唯一运行时、唯一源码**。直接维护它；不存在设计源/打包态双轨，也没有 pack 步骤。runtime 不生成 `bin/agent`。人可以直接 `/bin/sh seed.sh`，或在 `/ini` 验收成功后运行全局 `seed`。

理念说明：[docs/理念与设计.md](docs/理念与设计.md)。`docs/superpowers/specs/` 和 `docs/superpowers/plans/` 是 archived 历史设计记录，不是当前契约，不要机械改写其正文。

---

## 硬约束

1. **runtime 只用 POSIX `/bin/sh` + curl + jq。** 主 loop、SSE、持久 shell、edit 不得由 Python / Perl / Ruby 代打。
2. **API 工具只有两个：** 持久 `shell` 和精确替换 `edit`，通过标准 `tool_calls`；不加 read/grep/glob/todo 等工具，不解析自创 `<ACTION>`。
3. **工作区是启动 `seed.sh` 或 `seed` 时的 `$PWD`。** 产物不得写死 `/Users/`、`/home/` 或本机绝对路径。
4. **一份 POSIX runtime 跟宿主 `$SHELL` 走。** 不假设 Bash 5，不用 `sed -i`、`head -c`、`pgrep`、`timeout(1)` 等不可移植捷径。
5. **外壳拥有循环，模型拥有判断。** 不让模型每轮另写 controller 再调用 LLM。
6. **保留现有可见行为。** 首次启动显示 `initializing:`，就绪显示 `ready` 和 `>`；对话保留工具过程行与 SSE 行为，最终回答只印一次。删除或替换已有行为前先问人。
7. **不信模型口头安装成功。** `/ini` 由模型选择用户可写安装法，外壳必须独立验回执、冻结的原始 PATH、可执行入口和 `seed --probe`。
8. **状态与工作区分离。** 默认状态在 `~/.seed`，只认 `SEED_HOME` 覆盖；不要增加旧身份 alias 或 fallback。
9. **扩展走提示词。** `plugins/agent/*.json` 保持 catalog 架构，只发布 prompt；不要在 plugin 里藏另一套启动器或实现脚本。
10. **模型在工作区写什么语言不限。** 语言限制罩住的是 runtime，不是它为任务生成的项目代码。

---

## 当前仓库结构

| 路径 | 角色 |
|---|---|
| `seed.sh` | standalone runtime，也是唯一可编辑实现 |
| `tests/seed-package.sh` | 完全离线的产品合同 |
| `plugins/agent/` | 初始化与懒构建扩展的提示词 catalog |
| `plugins/seed/` | provider/model catalog |
| `plugins/jq/` | jq fallback 镜像说明与维护脚本 |
| `bench/apple-container/` | Apple container bench |
| `bench/harbor/` | Harbor adapter 与 bench 驱动 |
| `docs/理念与设计.md` | 当前理念和运行契约 |
| `docs/superpowers/` | archived 历史记录 |

不要提交或输出：`.env`、API key、`.agent-runs/`、`.runs/`、bench 结果目录，以及模型在仓库根临时生成的项目文件。

---

## 使用和开发

```sh
/bin/sh seed.sh deepseek sk-xxxx             # 首次激活
/bin/sh seed.sh                              # 之后交互
/bin/sh seed.sh -p "任务"                    # 一次性
seed                                         # /ini 成功后的全局入口
seed -p "任务"
sh plugins/serve.sh                          # 本地 catalog 服务
```

修改 runtime 时直接编辑 `seed.sh`。不要创建 build/pack 流，也不要新增第二个根 runtime 文件。最低验证：

```sh
/bin/sh -n seed.sh
/bin/sh tests/seed-package.sh
git diff --check
```

离线测试使用假的 plugin transport 和 LLM stub，不得联网，不得依赖真实 key。需要真模型冒烟时，在临时工作目录运行，不能在 slab 根留下任务产物。

---

## 维护对照

```text
错：新增打包源，再生成 seed.sh
对：直接改唯一源码 seed.sh

错：安装到项目并生成另一份 agent loop
对：seed.sh 自己运行；/ini 只建立全局 seed 入口并由外壳验收

错：给旧身份保留环境变量、状态目录或 alias
对：SEED_HOME、~/.seed、seed.identity=seed

错：在 runtime 里用 Python 处理 JSON/SSE/edit
对：/bin/sh + jq + curl

错：插件提示词教模型调用已退出的项目入口
对：直接运行全局 seed；未安装时先让人执行 /ini

错：为了迁移重写 benchmark 逻辑或结果
对：只做必要命名/路径迁移，保留用户已有任务、参数和证据
```

用户没有明确要求时，不 commit、不 push、不联网。始终保留无关的未提交改动。
