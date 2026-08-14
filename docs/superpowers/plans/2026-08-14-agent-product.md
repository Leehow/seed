# 产物 agent 脱离与初始化 Implementation Plan

> **For agentic workers:** Use executing-plans. User said 做吧 — implement in this repo, do not commit unless asked.

**Goal:** 安装把 loop 写进 `bin/agent`；打开后拉 agent plugin、跑一次初始化、维护两棵 JSON 树。

**Architecture:** `write_shims` 把打包正文拷到 `bin/agent`（basename 为 `agent` 时走 `agent_main`，不装）。`build/product.sh` 负责拉目录、落树、磁盘验收、`--update`。种子仍只拉 seed plugin。

**Tech Stack:** POSIX `/bin/sh`、curl、jq。离线合同 `tests/seed-package.sh`。

## Global Constraints

- loop 和两个工具只用 `/bin/sh` + curl + jq
- 不加第三种 `tool_calls`
- 不恢复 SSE
- `seed.sh` ASCII-only；禁止手改，改 `build/` 再 pack
- 状态英文机器话：`initializing:` / `error:`
- 不把 `/Users/` `/home/` 写进产物源码
- 安装不拉 agent plugin、不叫模型
- 测试不联网（本地 `http.server` + stub）

## Files

- Create: `build/product.sh`
- Create: `plugins/agent/init.json`
- Modify: `plugins/agent/index.json`
- Modify: `build/install.sh` (`write_shims`, `verify_install`)
- Modify: `build/agent.sh` (`product_root`, `agent_main`, `--update`, basename)
- Modify: `build/pack.sh` (include `product.sh`)
- Modify: `tests/seed-package.sh`
- Modify: `AGENTS.md`（产物不再是 seed shim）
- Modify: `.gitignore`（`agent-store/`、`.agent-memory/`）

### Task 1: 合同测试（RED）

现有打开 / oneshot / 交互 / verify 探测加 `SLAB_SKIP_INIT=1`。新增：自带 loop、删 `seed.sh` 仍能跑、缺 ready 会拉 init、stub 填树后只有 `>`、已 ready 断网能开、`--update` 才重拉、坏 stub 初始化失败。

### Task 2: 实现并 pack（GREEN）

按 `docs/superpowers/specs/2026-08-14-agent-product-design.md`。`/bin/sh tests/seed-package.sh` 必须绿。
