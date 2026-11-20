# 第三方中转站

状态：QQ 回复仍固定请求 `https://api.deepseek.com`，改成用户填写的中转地址还没做。社交模块已经能填地址。密钥单独填写，不写进仓库，也不作为官方密钥。默认仍是官方。

中转站走 OpenAI 兼容的 `chat/completions`。模型名用该站自己的名单，不能假设官方的 `deepseek-flash` 一定存在。发给对方的只有 `choices[0].message.content`。`reasoning_content` 是思考过程，不进 QQ 消息。

## 已试

`https://sub.ciallo.cafe/v1` 鉴权通过。`GET /v1/models` 能列出模型。`deepseek-flash` 不在名单里。`deepseek-v4.1-flash` 能完成普通问话，也能看图。

同一把密钥向官方 `https://api.deepseek.com` 请求返回 401。

这家中转站即使请求里写了 `"thinking": {"type": "disabled"}`，响应里仍会带 `reasoning_content`。`max_tokens` 太小会把正文截断，结束原因是 `length`。普通问话把上限放到 1024 时，正文完整，结束原因是 `stop`。识图放到 4096 时，正文完整。

## 普通对话

`POST https://sub.ciallo.cafe/v1/chat/completions`

```json
{
  "model": "deepseek-v4.1-flash",
  "messages": [
    {"role": "user", "content": "晚饭吃面还是吃饭，随便给个建议。"}
  ],
  "max_tokens": 1024,
  "stream": false,
  "thinking": {"type": "disabled"}
}
```

这次返回的正文是：「吃面吧，热乎又省事，煮起来也快。」

## 识图

有图时，user 内容改成数组。图只放在这一条 user 消息的 `image_url` 里。`assistant` 历史不带图。格式与官方识图说明相同：<https://api-docs.deepseek.com/guides/vision>。

```json
{
  "model": "deepseek-v4.1-flash",
  "messages": [
    {
      "role": "user",
      "content": [
        {"type": "text", "text": "用一两句话描述这张图里能看见的内容。看不清就说没看清。"},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64,...", "detail": "auto"}}
      ]
    }
  ],
  "max_tokens": 4096,
  "stream": false,
  "thinking": {"type": "disabled"}
}
```

接受 JPEG、PNG、GIF、WebP。这次用一张图试过，`deepseek-v4.1-flash` 能说出画面里看得见的内容，没有编模糊的背景。QQ 里有图的回合仍要等识图结束再入发送队列，见 [VISION_QUEUE.md](VISION_QUEUE.md)。

## 接入

用户填写中转根地址、密钥和该站的模型名。程序把地址接到 `/chat/completions`，不另造模型名，不把这家中转站写成默认地址。一个站不支持识图时，按文字回复并说明没看到，不发半截正文。每个私聊、每个群可选。失败时换备用。
