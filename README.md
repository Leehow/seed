# slab

实验：`/bin/sh` 能不能撑住一个带工具的 coding agent。

`seed.sh` 是种子。主 loop 和自带工具（持久 shell、edit）只用 shell + curl + jq。之后模型在工作区里长出的东西不限语言。

```sh
sh seed.sh deepseek sk-xxxx   # 第一次：凭据写入 .env，装好 bin/agent
sh seed.sh                    # 凭据已在 .env 时重装
sh bin/agent                  # 交互窗口
sh bin/agent "任务"           # 一次性
```

工作区是启动 `bin/agent` 时的当前目录。种子装的时候不聊天，只刷 token；产物只显示引导和最后回答。

```sh
/bin/sh tests/seed-package.sh
```
