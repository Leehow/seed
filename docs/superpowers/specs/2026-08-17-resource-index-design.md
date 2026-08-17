# 资源索引：一次构建，探测-登记-使用，黑白名单测鲁棒

- 日期：2026-08-17
- 状态：已拍板
- 前序：[可选初始化](2026-08-15-seed-agent-optional-init-design.md)、[检索树](2026-08-14-retrieve-index-design.md)、[参考 Prime Agent](2026-08-16-delegate-refine-design.md)

## 1. 要解决什么

压测里出现了一个设计外的行为：模型发现宿主的 `codex` CLI，拿它当只读评审子代理，用得很熟练。这不是要堵的漏洞，是要接住的能力：**种子的承诺是「最小 shell 种子」，不是「不准用本机东西」。** 恰好相反——有现成的就不造轮子。

但这不能依赖运气。这次宿主恰好有 codex；别的机器可能没有，可能有别的。所以：

1. **一次构建。** 种子装出 `bin/agent` 就结束了（现状已如此）。不再靠「简单 / 完整」的第二段仪式长能力；能力靠资源索引按需长。门和五块不动（增量约束，§7 另说），但资源索引是**必选 init 的基础能力**，任何 edition 都有。
2. **资源索引。** 树状索引从「六个工具 + 一个 fetch」扩成通用资源目录：本机 CLI、网络检索源、社区/GitHub、服务、库。每条记：**能不能用（smoke 过）、干什么用、需要什么环境、本机环境实况**。
3. **先搜后用。** 开工查索引；索引没有就检索（本机 `command -v`、网络搜索），smoke 验证，登记，再使用。
4. **鲁棒性用黑白名单测。** 测试环境用 PATH 白名单（只有 POSIX 必需品）+ 黑名单（屏蔽 codex / rg / git 等），验证没有这些工具时装得了、跑得动、索引如实记录。

## 2. 资源索引形状

机器树加一支 `system.resources`（不动现有 `system.tools` / `system.other`，纯增量）：

```json
{
  "name": "codex",
  "kind": "cli | search | service | library | project | source",
  "path": "或 url",
  "purpose": "一行，干什么用",
  "use": "怎么调，一行",
  "needs": ["node", "key:EXA_API_KEY"],
  "ok": true,
  "note": "如烟out结果、沙箱档位",
  "probed": "UTC 时间"
}
```

- `ok` 只许在 smoke 通过后为 true；`needs` 里列环境依赖（命令、key、网络）。needs 缺了 → `ok:false` + note 写缺什么。
- 需要 key 的资源（firecrawl、exa）：如实登记 `needs:["key:..."]`，key 不在环境里就 `ok:false`。**模型不许发明 key；要 key 就问人。**
- 本机环境实况进 `system.env`：`{os, arch, shell, pkg managers( brew/apt/npm/pip 在不在), python 版本, network ok}`。init 时探一次，之后环境变了由模型重探。

`--update` 照旧只刷 retrieve；resources/env 是各机器自己的实况，不随包刷。

## 3. 网络检索源（`system.web` 从一格扩成多格）

现在是 `fetch` 一格（curl GET），保持不动——`--update` 会把 `system.web` 剪成只剩 `fetch`，检索源放这里会被刷掉。所以检索源登记进 `system.resources`、`kind:"search"`。候选清单制：提示词给候选，模型逐个 smoke，登记的只有验证过的：

- 无 key 优先：DuckDuckGo html/lite 端点、Wikipedia API、GitHub 搜索 API（未认证限流但可用）
- 要 key 的（firecrawl、exa）：登记形状同上，缺 key `ok:false`
- 每条 `use` 写明：怎么拼 URL、怎么从 HTML/JSON 里抠结果（curl + jq / sed），不许整页糊进上下文（接 context-as-files）

## 4. 使用纪律（retrieve 加一段）

现在 retrieve 管「读索引」。加「长索引」的循环，英文、和现有措辞同风格：

- 开工：jq 索引（已有），命中 ok 资源直接用
- 需要外部能力而索引没有：先本机（`command -v`、常见路径），不行再网络检索（用 `system.web` 里 ok 的源）；找到 → smoke → 登记 `system.resources` → 使用
- **现成优先**：能调现成工具/库/服务完成的，不自己造；造之前先检索
- 查外部资料确认事实（文档、规格、公式）同样登记，`kind:"source"`，URL 进 path，获取时间进 probed
- 委托子代理：`bin/agent --oneshot` 永远可用；宿主要有登记过的 agent CLI（带沙箱档位等 note），也可以用——登记即授权
- 条目失效（smoke 挂了）：标 `ok:false` + note，不删

## 5. init 流程改动

全在 `init.json` 提示词，引擎零改动：

1. 现有顺序不动（web.fetch smoke → 写 ready → 可选扫描）
2. 可选扫描扩成「资源普查」一条：一个 shell 脚本里 `command -v` 一批候选（常见 agent CLI、检索 CLI、包管理器），smoke 通过的进 `system.resources`；`system.env` 同时写好
3. 普查是 best-effort：找不到任何候选也合法，空数组 + env 也算完成

## 6. 黑白名单测试（鲁棒性合同）

`tests/seed-package.sh` 加一类「环境面具」测试：

- **黑名单**：造 shim 目录，只放 POSIX 必需品的符号链接（sh curl jq awk sed grep cat ls cp mv rm mkdir chmod ln ps kill sleep date uname mktemp tr sort wc dd head tail printf 等），**屏蔽** codex / rg / git / python。`PATH=shim` 跑安装 + stub 驱动的产物：装得上、loop 转得动、`system.tools` 里被屏蔽项如实 `present:false/ok:false`
- **白名单**：shim 里放假的 `codex` / `ddgr`（打印罐装输出的 stub 脚本），验证它们可被调用、被探测路径覆盖到
- 离线合同只断引擎级事实：面具环境下安装/loop 不死、索引如实。模型普查行为的质量（有没有真去找）线上验，不进合同——和「不测模型真写了什么」一致

## 7. 和门的关系

门（简单 / 完整）这稿不动。资源索引进必选 init 后，「完整版」五块的价值收缩为人机界面层（`/` 命令表等）；是否把门拿掉、让每次安装都直接长全，那是另一份稿的事，要先问人。

## 8. 仓库交什么 / 合同

- `plugins/agent/init.json`：树模板加 `system.resources` / `system.env` 空壳；retrieve 加 §4 那段；init prompt 加资源普查步骤；catalog bump
- `plugins/agent/delegate.json`：委托纪律加「登记过的宿主 agent CLI 也可用」一句
- `tests/seed-package.sh`：§6 黑白名单面具测试 + 静态断言（模板有新分支、retrieve 有探测-登记-使用措辞）
- 不动 `build/`、不动引擎探测那六个工具的既有逻辑

## 9. 明确不做

- 引擎代做资源普查（提示词级，模型探，引擎只验树的形状）
- 给任何具体工具写适配代码（codex / firecrawl 都不点名进种子；候选清单只活在提示词里）
- 拿掉门、拿掉五块（另一份稿的事，先问）
- 模型自己编造 key 或把 key 写进树
- 向量检索 / embedding 索引（jq + smoke 够用）
