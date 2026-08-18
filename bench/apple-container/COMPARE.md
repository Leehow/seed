# 对照说明（给文章用）

跑在 Apple `container` 1.2.2，Debian 12 bookworm，aarch64，`--dns 8.8.8.8`。
种子是仓库里的 `seed2.sh`，密钥只在宿主持 `source` 后按变量名注入，不进镜像。

## 我们跑了什么

| 环境 | 预装 | 题目 | 终态 | 墙钟 | 它实际怎么干的 |
|---|---|---|---|---|---|
| clean | 只有 curl + CA | hello-file（冒烟） | pass | 15s | 自装 jq → init → 写文件 |
| clean | 同上 | search-needle | pass | 4s | `grep -r`，没有 rg |
| clean | 同上 | web-install-fd | pass | 14s | 查 Debian：`apt-get install fd-find`，用 `fdfind` |
| rich | git / rg / python3 / jq / openssl / Codex 0.147.0 | search-needle | pass | 89s | 首次 init 普查；检索仍用了 grep，没用 rg |
| rich | 同上 | fix-git（TB 2.1 原题指令） | pass | 11s | `git branch` / `git log` / `git merge wip` |
| rich | 同上 | list-tools | 见下 | 17s / 8s | 登记了 **codex**；`system.tools` 被写成全 false |
| rich | 同上 | openssl-selfsigned-cert（TB 2.1 原题+官方测试要点） | pass | 27s | openssl 自签 2048/365 天，写 verification + check_cert.py |
| rich | 同上 | nginx-request-logging（TB 2.1 原题+官方测试要点） | pass | 59s | apt 装 nginx，修 403 权限，8080/404/限流/日志都绿 |

`list-tools` 第一轮写出了 `/usr/bin/git`、`/usr/bin/rg`、`codex`。当时验收脚本只认裸名字 `git`/`rg`，误判 fail；用放宽后的脚本复评，**第一轮是 pass**。第二轮模型信了索引里 `git`/`rg` 的 `ok:false`，名单里只剩 `apt/codex/curl/fetch/python3`，这轮才是真 fail。

## 和别人的 bench 怎么比

不要把我们的分数写成 Terminal-Bench 官方分。Harbor 的 89 题跑在 Docker + 他们的 oracle/测试上；我们只借了 **同一条人类指令**。

| 公开基准 | 我们借了什么 | 我们没跑什么 | 公开对照数字（别人的，不是我们的） |
|---|---|---|---|
| [Terminal-Bench 2.1 `fix-git`](https://github.com/harbor-framework/terminal-bench-2-1/tree/main/tasks/fix-git) | 原题英文指令；本地两提交夹具 | 官方仓库树、Harbor 评分、5 trial | 2.1 榜：Claude Code+Fable 5 **83.8%**，Codex+GPT-5.5 **83.2%**，mini-SWE-agent **76.2%**（全套 89 题，不是单题） |
| TB 2.1 `openssl-selfsigned-cert` / `nginx-request-logging` | 原题指令 + 官方 `test_outputs.py` 要点的 POSIX 验收 | Harbor 官方镜像/5 trial | 全套榜见上；我们单题都 pass |
| SWE-agent / mini-SWE-agent | 对照「搜索要不要专用 ACI」 | 没跑 SWE-bench | SWE-agent：专用搜索界面曾经比裸 shell 强；mini-SWE-agent：纯 bash 也能上 Verified |
| ThiqahOps / InfraBench | 运维终态验收的形状 | 没跑他们的套件 | InfraBench 最强配置约 40–88%，强调「当时绿了、事后却不稳」 |

文章里建议这样写：

1. **冷启动**：干净 Debian 只有 curl，种子自己拉 jq，15 秒写完第一文件。Claude Code / Codex 要先装 Node 或官方安装器，同一张表就能压。
2. **网上找工具**：干净机没有 `fd`，它查到 Debian 包名是 `fd-find`、二进制是 `fdfind`，装完列出两个 `.md`。这是 TB 不单独计分的能力。
3. **复用本机工具**：富环境里 Codex 0.147.0 被普查并登记；`fix-git` 直接用本机 `git` 11 秒过。但搜 TOKEN 时它仍用了 grep，没强制走 rg——「有工具 ≠ 会用」，要靠索引/retrieve 引导。
4. **和 TB 的关系**：`fix-git` 是同指令、本地夹具、磁盘终态。下一步才是 Harbor adapter 跑官方 89 题。

## 这轮暴露的种子问题（别藏）

1. Apple `container --env-file` 不会拆 `.env` 里 `LLM_EXTRA` 的 JSON 引号，`disable_thinking` 会把字符串和对象相加直接退出。harness 已改成宿主持 source 再 `--env KEY` 继承。
2. 富环境里引擎的 `system.tools` 六格曾被模型盖成 `present:false`（`system.resources` 仍正确登记了 codex）。已修：引擎在 init 后和每次就绪打开时重探；Debian 上 `python` 会落到 `python3`。同一份假阴性索引再打开后，六格都变成 ok。
