# slab

实验：`/bin/sh` 能不能撑住一个带工具的 coding agent。

给改这个仓库的人：[AGENTS.md](AGENTS.md)。  
理念和设计：[docs/理念与设计.md](docs/理念与设计.md)。  
安装契约：[docs/superpowers/specs/2026-08-13-seed-package-design.md](docs/superpowers/specs/2026-08-13-seed-package-design.md)。

`seed.sh` 是种子。主 loop 和自带工具（持久 shell、edit）只用 shell + curl + jq。`bin/agent` 是种子写的薄入口，不是模型另写的一套程序。之后模型在工作区里长出的东西不限语言。

```sh
sh seed.sh deepseek sk-xxxx   # 装到当前目录（内置，可离线）
sh plugins/serve.sh           # 本地模拟 plugin 目录（7432）
sh seed.sh qwen sk-xxxx       # 拉目录 → models 插件 → 问一次选模型
sh bin/agent                  # 交互；工作区是当前目录
sh bin/agent "任务"           # 一次性
sh build/pack.sh              # 改完 build/ 后打回 seed.sh
```

种子装的时候不叫模型。产物打开就是 `>`，只显示你的输入和最后回答。

需要 POSIX 环境：`/bin/sh`、curl、jq。Linux、macOS、WSL、Git Bash 可以；原生 cmd / PowerShell 不行。换机器把仓库拷过去，自己准备 `.env`，不要带着本机绝对路径。

```sh
/bin/sh tests/seed-package.sh
```
