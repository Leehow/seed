# Apple container 上的 seed 对照 bench

不用 Docker。本机 `container` CLI（已确认 1.2.2）拉两套 Debian 12 环境，跑同一份 `seed.sh`。

| 环境 | 镜像 | 预装 |
|---|---|---|
| `clean` | `slab-bench-clean` | 只有 `curl` + CA。jq 由种子自己拉。 |
| `rich` | `slab-bench-rich` | git、ripgrep、python3、jq、openssl，并尽量装 Codex CLI。 |

密钥在宿主持 `source` 后按变量名注入（不要用 Apple `container --env-file`，它不会拆 `.env` 里的 JSON 引号），不写进镜像，也不放进公开目录。

```sh
sh bench/apple-container/run.sh --env .env --all
sh bench/apple-container/run.sh --env .env --amortize
sh bench/apple-container/run.sh --env .env clean hello-file
```

题目：

- `hello-file` — 冷启动冒烟
- `census-tools` — 强制普查并登记本机 CLI（富环境要含 Codex）
- `search-needle` — 在文件树里找 TOKEN（富环境应走 `rg`）
- `web-install-fd` — 网上查出并安装 `fd`，再列 `.md`
- `fix-git` — 对照 [Terminal-Bench 2.1 `fix-git`](https://github.com/harbor-framework/terminal-bench-2-1/tree/main/tasks/fix-git) 的原题指令
- `list-tools` — 索引里要出现 git / rg，有 Codex 则也要登记
- `openssl-selfsigned-cert` — 对照 TB 2.1 原题指令与官方测试要点
- `nginx-request-logging` — 同上

结果在 `out/results.tsv`（已 gitignore）。对照表和这轮数字见 [COMPARE.md](COMPARE.md)。
