# slab

一颗 POSIX `/bin/sh` 种子。curl 下来，对着项目 `sh` 一下就能当 coding agent 用。

只要 `/bin/sh` 和 curl。Linux、macOS、WSL、Git Bash 可以。原生 cmd / PowerShell 不行。没有 jq 会自己拉。

## 用

先把 `seed2.sh` 拉到本地，再启动。不要 `curl | sh`。

```sh
curl -fsSL https://raw.githubusercontent.com/Leehow/slab/main/seed2.sh -o seed2.sh
cd 你的项目
sh seed2.sh deepseek sk-你的key
```

第一次把 key 写进 `~/.seed2/.env`，探测这台机器，然后出现 `>`。在提示符里说话即可。空行或 Ctrl-D 离开。

之后换目录再开，不用再带 key：

```sh
sh /刚才下载的路径/seed2.sh
```

一次性任务：

```sh
sh seed2.sh -p "把安装说明写进 README"
```

任意 OpenAI 兼容接口（第三参是模型，可省）：

```sh
sh seed2.sh https://api.example.com/v1 sk-xxxx 模型名
```

想装成全局命令：在 `>` 里输入 `/ini`。磁盘验收通过后，任意目录：

```sh
seed2
seed2 -p "任务"
```

工作区是启动时的当前目录。状态在 `~/.seed2`，不进项目。不要把 key 提交进 git。

## 这是什么

一个文件就是完整 runtime。两个 API 工具：持久 shell、精确替换 edit。其余能力靠本机已有的 CLI 和线上提示词自己长。

完整源码在 [`source`](https://github.com/Leehow/slab/tree/source) 分支。给改仓库的人看 [AGENTS.md](https://github.com/Leehow/slab/blob/source/AGENTS.md)。
