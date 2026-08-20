# slab

一颗可直接运行的 POSIX `/bin/sh` coding-agent 种子。

仓库根上的 [`seed.sh`](seed.sh) 同时是**唯一产品、唯一运行时、唯一源码**。没有生成步骤，没有 build/pack 双轨，也不会再安装出 `bin/agent`。运行只需要 `/bin/sh`、curl 和 jq；缺 jq 时种子会下载兼容二进制。

支持 Linux、macOS、WSL、Git Bash；不支持原生 cmd / PowerShell。

## 使用

先从 GitHub main 下载 `seed.sh`，不要 `curl | sh`。运行后插件 catalog 默认从同一仓库的 raw `plugins/` 拉取（`https://raw.githubusercontent.com/Leehow/slab/main/plugins`）；可用 `SEED_PLUGIN_ROOT` 覆盖。

```sh
curl -fsSL https://raw.githubusercontent.com/Leehow/slab/main/seed.sh -o seed.sh
cd 你的项目
/bin/sh /下载路径/seed.sh deepseek sk-你的key
```

第一次会把配置写入 `~/.seed/.env`，初始化机器能力索引，然后进入 `>`。空行或 Ctrl-D 退出。之后在任意项目目录直接运行同一个文件：

```sh
/bin/sh /下载路径/seed.sh
/bin/sh /下载路径/seed.sh -p "把安装说明写进 README"
```

任意 OpenAI 兼容接口（第三参模型名可省）：

```sh
/bin/sh seed.sh https://api.example.com/v1 sk-xxxx 模型名
```

在交互提示符输入 `/ini`，模型会尝试把当前 runtime 安装成全局命令；外壳会独立检查回执、PATH 和 probe。成功后：

```sh
seed
seed -p "任务"
```

工作区始终是启动命令时的当前目录。状态目录默认 `~/.seed`，可用 `SEED_HOME` 隔离。不要提交 `.env` 或运行证据。

## 开发

直接修改根 [`seed.sh`](seed.sh)，然后运行：

```sh
/bin/sh -n seed.sh
/bin/sh tests/seed-package.sh
git diff --check
```

agent catalog 仍在 [`plugins/agent/`](plugins/agent/)；其中发布的是提示词，不是另一套 runtime。设计与维护约束见 [AGENTS.md](AGENTS.md) 和 [docs/理念与设计.md](docs/理念与设计.md)。
