# plugin 目录（第一颗：models）

- 日期：2026-08-14
- 状态：本地 localhost 模拟
- 范围：种子挂钩 + seed 目录 + models 插件；agent 目录地址见 [产物 agent](2026-08-14-agent-product-design.md)

## 1. 要解决什么

最小种子冻住。渠道名单会变，不能写进 `seed.sh`。种子只写死你们的根 URL，先下目录，再按功能下具体 plugin。

## 2. 写死的地址

- 根：`http://127.0.0.1:7432`（本地模拟；以后换成正式域名再打包）
- seed 目录：`<根>/seed/index.json`
- agent 目录：`<根>/agent/index.json`（加载与初始化见产物 agent 规格）
- 测试可用 `SEED_PLUGIN_ROOT` 覆盖根，避免抢端口

`deepseek` 和完整 `http(s)://` URL 不查目录。

## 3. 两级下载

```text
sh seed.sh qwen <KEY>
  GET <根>/seed/index.json
  → models → GET <根>/seed/models.json
  → 检索 qwen
  → 拉模型名单，问一次
  → 写 .env，装 shim
```

`index.json`：`{ "models": "models.json" }`。相对路径相对该 index 所在目录。

`models.json`：渠道名为键。

```json
{
  "qwen": {
    "api_url": "https://.../v1/chat/completions",
    "extra": {}
  }
}
```

- `models_url` 可省略：若 `api_url` 以 `/chat/completions` 结尾，换成同前缀的 `/models`；否则用 scheme://host + `/v1/models`
- `api_url` / `models_url` 以 `/` 开头：接到 plugin 根上（本地模拟用）
- 查无此渠道：exit 64，stderr 列出目录里的键

## 4. 只问一次

拉到 OpenAI 形名单 `{ "data": [ { "id": "..." } ] }`。打印编号列表，提示 `model: `。输入序号或 id。空行 / EOF：exit 64，不装。问完不再提问。

## 5. 明确不做（这轮）

- 不执行远程 shell
- 不改 loop / edit / 持久 shell
- 不实现 agent plugin 加载（已另开产物规格）
- 不缓存目录；每次带渠道名安装都重新拉
