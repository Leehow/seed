# 对照说明（给文章用）

跑在 Apple `container` 1.2.2，Debian 12 bookworm，aarch64，`--dns 8.8.8.8`。
种子是仓库里的 `seed.sh`，密钥只在宿主持 `source` 后按变量名注入，不进镜像。

## 我们跑了什么

| 环境 | 预装 | 题目 | 终态 | 墙钟 | 它实际怎么干的 |
|---|---|---|---|---|---|
| clean | 只有 curl + CA | hello-file（冒烟） | pass | 15s | 自装 jq → init → 写文件 |
| clean | 同上 | search-needle | pass | 4s | `grep -r`，没有 rg |
| clean | 同上 | web-install-fd | pass | 14s | 查 Debian：`apt-get install fd-find`，用 `fdfind` |
| clean | 同上 | openssl-selfsigned-cert（TB 2.1） | pass | 50s | 镜像里已有 openssl（CA 依赖）；缺 python3 就 `apt-get install`，再写 check 脚本 |
| clean | 同上 | nginx-request-logging（TB 2.1） | pass | 35s | `apt-get install nginx`，修 403，8080/404/限流/日志都绿 |
| clean | 同上 | fix-git（TB 2.1） | pass | 17s | 夹具现装 git，再 `git merge wip` |
| rich | git / rg / python3 / jq / openssl / Codex 0.147.0 | search-needle | pass | 89s | 首次 init 普查；检索仍用了 grep，没用 rg |
| rich | 同上 | fix-git（TB 2.1 原题指令） | pass | 11s | `git branch` / `git log` / `git merge wip` |
| rich | 同上 | list-tools（探测修复后） | pass | 17s | 名单含 git / rg / python / **codex** / apt |
| rich | 同上 | openssl-selfsigned-cert（TB 2.1） | pass | 27s | openssl 自签 2048/365 天，写 verification + check_cert.py |
| rich | 同上 | nginx-request-logging（TB 2.1） | pass | 59s | apt 装 nginx，修 403 权限，8080/404/限流/日志都绿 |

同一条 TB 指令，干净机也能过：openssl 50s（现装 python3），nginx 35s（现装 nginx）。富环境 openssl 更快（27s）；nginx 富环境 59s，慢在装包和排 403，不是 init。

`list-tools` 探测修复前有两轮失败：第一轮其实写出了 `/usr/bin/git`、`/usr/bin/rg`、`codex`，当时验收只认裸名字，误判 fail；第二轮模型信了被盖成全 false 的 `system.tools`，名单缺 git/rg，是真 fail。引擎改为 init 后和每次就绪重探之后，同一富环境再跑是 **pass**。

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
4. **和 TB 的关系**：本地 Apple container 那三题仍是同指令、本地夹具。官方 89 题改走 Harbor + Docker，见下节。
5. **索引摊销**：见下节。第一题若只写文件，init 可能跳过资源普查；先跑 `census-tools` 才会登记 Codex。

## 这轮暴露的种子问题（别藏）

1. Apple `container --env-file` 不会拆 `.env` 里 `LLM_EXTRA` 的 JSON 引号，`disable_thinking` 会把字符串和对象相加直接退出。harness 已改成宿主持 source 再 `--env KEY` 继承。
2. 富环境里引擎的 `system.tools` 六格曾被模型盖成 `present:false`（`system.resources` 仍正确登记了 codex）。已修：引擎在 init 后和每次就绪打开时重探；Debian 上 `python` 会落到 `python3`。同一份假阴性索引再打开后，六格都变成 ok；`list-tools` 复跑 pass。
3. 第一题若只要求写文件，模型可能把 `ready` 标真却留下空的 `system.resources`。墙钟会摊销，Codex 不会进索引。要完整普查得显式跑 `census-tools`，或把普查写进引擎而不是只靠提示词。

## 索引摊销

`sh bench/apple-container/run.sh --env .env --amortize`：全新 `shared-amortize-rich`，先普查再连续干活。

| 序 | 题目 | 终态 | 墙钟 | 索引在干什么 |
|---|---|---|---|---|
| 1 | census-tools | pass | 54s | 付 init + 普查；登记 git / rg / python3 / openssl / apt-get / **codex 0.147.0** |
| 2 | hello-file | pass | 6s | 已 ready，直接写文件 |
| 3 | list-tools | pass | 16s | 只读索引，11 个 ok 名含 Codex |
| 4 | search-needle | pass | 6s | 复用状态；检索仍走 `grep`，没用已登记的 rg |
| 5 | fix-git | pass | 10s | 直接用本机 git |

对照：第一题若换成 `hello-file`（只要求写文件），init 29 秒就标 ready，`system.resources` 仍是空数组，下一题 `list-tools` 缺 Codex 而 fail。墙钟照样摊销（随后 search 6s、fix-git 10s），但索引不完整。

更早那次富环境第一题 `search-needle` 89 秒，是同一现象的另一面：普查写进了第一道题。

## Harbor 官方 Terminal-Bench 2.1

Harness：Harbor 0.21.0 + Docker Desktop，数据集 `terminal-bench/terminal-bench-2-1`（89 题）。
adapter：`bench/harbor/seed_agent.py`，把仓库里的 `seed.sh` 装进每道题容器再 `--oneshot`。
密钥：宿主机 env 上传到容器 `$SEED_HOME/.env`，不走 `--ae` 传 `LLM_EXTRA`（JSON 花括号会被弄坏）。不要把 key 写进本文件。

Jellytoken（`https://aiservice.jellytoken.com/v1`）冒烟：

| 模型 | 题 | k | 终态 | 墙钟 | 备注 |
|---|---|---|---|---|---|
| kimi-k2.7-code | fix-git | 1 | reward 0.0 | 2m 24s | 鉴权通；找到 detached commit 后停下来问要不要 merge |
| deepseek-v4-pro | fix-git | 1 | reward 1.0 | 4m 12s | SSE 后续空 `name`/`id` 不再盖掉第一片；官方 verifier 绿 |

| 跑法 | 题 | k | 终态 | 墙钟 | 备注 |
|---|---|---|---|---|---|
| oracle | terminal-bench/fix-git | 1 | reward 1.0 | 46s | Harbor / 数据集 / Docker 通 |
| seed + DeepSeek 直连 | terminal-bench/fix-git | 1 | reward 1.0 | 3m 44s | 官方 instruction + 官方 verifier |
| seed + jellytoken/deepseek-v4-pro | 全套 89 题 | 1 | Mean **0.360**（32/89） | 12h 6m | 本地 `tb21/tasks`，Harbor 2 并发；作业 `jobs/2026-08-18__07-47-33` |

这是官方任务集上的一遍分，**不是** k=5 榜单分。社区提交目前关闭；COMPARE 里不要写成 Harbor Hub 提交成绩。

全量例外：`AgentTimeoutError` 32（其中部分仍 reward 1.0）、`RuntimeError` 8（无 reward）、`NetworkConnectionError` 1。Harbor 表里 Trials 81 = 有 reward 的题；Mean 按 89 题算，32÷89≈0.360。
