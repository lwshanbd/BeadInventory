# 更新在线模型清单

App 每次启动、每次回到前台（包括收起控制中心、通知之后），都会静默拉取 `https://lwshanbd.github.io/BeadInventory/models.json`。
设置页「AI 提供商」下面能选的模型，就来自这份清单。

- 拉到了，而且跟手机上的不同：换上新清单，并存一份在本地。JSON 里没写的 provider，保留手机上已有的那份。
- 拉不到（没网、Pages 挂了、JSON 写坏了）：用上次存下的清单；从来没拉到过就用代码里写死的内置清单（`ModelCatalogManager.builtIn`）。

## 格式

```json
{
  "v": 1,
  "providers": {
    "Kimi": { "models": ["kimi-k2.6", "kimi-k3"], "default": "kimi-k2.6" }
  }
}
```

- `v` 必须是 1，否则整份不认。
- `providers` 的 key 必须跟 App 里的 provider 名字一字不差：`Kimi`、`OpenAI`、`Anthropic`、`Qwen`、`Gemini`。
- 某个 provider 不写，或者 `models` 是空的：那个 provider 保留手机上已有的清单。
- `models` 的顺序就是设置页里的显示顺序。
- `default` 必须在 `models` 里。写错了 App 会用 `models` 的第一个。`models` 和 `default` 两个字段都不能省略，任何一家少了字段或类型不对，整份清单都不认。
- 不认识的 provider key 会被忽略。以后加了新 provider，老版本 App 读到也不会出错（前提是新 provider 也带齐 `models` 和 `default`）。

## 用户的选择什么时候会被改

- 用户选的模型还在新清单里：**不动**。`default` 改成别的也不会覆盖用户的选择。
- 用户选的模型不在新清单里了（下线、改名）：换成新清单里这个 provider 的 `default`。
- 用户切换 provider 时，选中的是新清单里那个 provider 的 `default`。

所以下线一个模型，直接从 `models` 里删掉就行。

## 发布流程

1. 改 `docs/models.json`，本地先跑一遍检查：

   ```bash
   python3 tools/check_models_json.py
   ```

   它查格式、provider 名字、`default` 在不在列表里，并列出这次删掉了哪些模型（选着这些模型的用户会被换到默认模型）。

2. 提交并推送到 main。

3. 等 GitHub Pages 构建完（通常 1–2 分钟），打开 URL 确认内容：

   ```
   https://lwshanbd.github.io/BeadInventory/models.json
   ```

改了内置清单（`ModelCatalogManager.builtIn`）的话，记得同步改 `docs/models.json`，反过来也一样。
