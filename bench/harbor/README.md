# Harbor 上跑官方 Terminal-Bench 2.1

官方 89 题走 Harbor + Docker，不是 Apple `container`。
adapter 把 standalone `seed.sh` 放进每道题的容器，再 `--oneshot` 原题指令。
adapter 将宿主 `.env` 上传到容器的 `$SEED_HOME/.env`，不通过 Harbor `--ae` 注入密钥，也不写进镜像或仓库。`LLM_EXTRA` 同样不经 `--ae`，避免 JSON 花括号被损坏。

容器里 adapter 只保证 `curl` + CA。jq / git / python 仍由种子或模型自己长。

```sh
# 需要：Docker Desktop 已开，uv tool install harbor
# 官方题优先用本地克隆 bench/harbor/tb21/tasks（gitignore），避免 Hub SOCKS/HTTP2 拉 89 题失败
sh bench/harbor/run.sh --env .env smoke-oracle
sh bench/harbor/run.sh --env .env smoke
sh bench/harbor/run.sh --env .env --all
```

覆盖次数和并发：

```sh
HARBOR_K=5 HARBOR_N=2 sh bench/harbor/run.sh --env .env --all
```

同模型对照（把 `LLM_*` 映射成 OpenAI 兼容接口；`LLM_API_URL` 若带 `/chat/completions` 会先剥到 `/v1`）。Jellytoken `deepseek-v4-flash` 并发很差，对照默认 `n=1`，且不要和 seed 全量叠跑。

```sh
# Harbor 自带 installed agent，架构上最接近 seed（bash 循环）
sh bench/harbor/run.sh --env .env --agent mini-swe-agent smoke
sh bench/harbor/run.sh --env .env --agent mini-swe-agent --all

# Harbor 自己的 reference agent（tmux 单工具，跑在宿主进程里，不是装进容器）
sh bench/harbor/run.sh --env .env --agent terminus-2 smoke
sh bench/harbor/run.sh --env .env --agent terminus-2 --all
```

对照公平性：mini-swe-agent 的官方 adapter 会预装 git / python3 / build tools 并在容器里 `uv tool install`；terminus-2 会装 tmux。seed 仍然只保证 curl + CA。分数要和这一条一起报。

`k=5` 才是榜单口径（445 trial）。默认 `k=1` 是先拿到官方任务集上的一遍分，不要写成 Harbor Hub 提交分。

结果在 `jobs/`（已 gitignore）。
