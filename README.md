![大肥鱼](docs/assets/hero.png)

# 大肥鱼 · DaFeiYu

给 QQ 配一个有性格、有记忆的 AI。每个私聊、每个群各自选一种记忆模式。

本仓库 [FONG4514/dafeiyu-bot-ojousama](https://github.com/FONG4514/dafeiyu-bot-ojousama) fork 自 [SAKURAfan1023/dafeiyu-bot](https://github.com/SAKURAfan1023/dafeiyu-bot)，原作者 SAKURAfan1023。

[四种记忆](#四种记忆模式) · [本版本](#本版本在做什么) · [上手](#上手) · [文档](#文档)

上游发布的安装包不含本 fork 的记忆、人设和识图改动。要用这里的行为，用本仓库的源码或本仓库构建出的程序。上游安装包说明仍见 [v0.3.0-preview.3](https://github.com/SAKURAfan1023/dafeiyu-bot/releases/tag/v0.3.0-preview.3)。

## 四种记忆模式

每个群、每个私聊单独选一个模式，默认均衡。私聊可以读这个人自己在群里的记忆。群聊不能读任何私聊，也不能读别的群。查记忆时必须传回提示词里的群号或对方 QQ，对不上就不查。

前三种已经在本仓库里。MAX 是计划，还没有实现。

| | 超级记忆 | 均衡 | 极速 | MAX · 绝对专注记忆 |
| --- | --- | --- | --- | --- |
| 状态 | 已实现 | 已实现，默认 | 已实现 | 未实现 |
| 写什么 | 每条消息和回复都写入原始事件 | 每条消息写入原始事件 | 不写原始事件 | 沿用所在会话的记忆库，不另开一份 |
| 何时整理 | 8 条或 4 分钟。每日默认 200 次，用完当天改按均衡 | 20 条、6000 字或 10 分钟，面板可调 | 200 条或 240 分钟 | 不靠回复模型自己整理上下文 |
| 落盘 | 约 4 秒内快照 | 约 20 秒内快照 | 不因事件落盘 | 查找读已有库 |
| 上下文 | 输入到达预算的 80% 时只留最近 4 条原话，更早的靠数据库 | 每 12 轮（可调 6–50）用已有摘要加最近 4 条，不再为压缩另调模型 | 不压缩。按字数截掉最旧的部分 | 每一轮都是新的 session |
| 这一轮带什么 | 最近 4 条原话，加上同一个回复模型调用的 `recall_memory` | 滚动摘要和最近对话，并可调用 `recall_memory` | 只注入要点，不开放查记忆工具 | 可配置条数的聊天上下文，加上另一个 AI 从允许的记忆区里找出的记忆 |
| 状态从哪来 | 数据库，外加这 4 条原话 | 摘要和近期原话 | 当前这段还没被截掉的对话 | 比超级记忆更无状态。说话模型不靠自己的历史续接上一轮 |
| 费用 | 最高 | 中 | 最低 | 每轮多一次查找 |

超级记忆的「开新对话」只替换这一轮发给模型的短期历史，不清空数据库，也不擦掉群时间线。关闭长期记忆后，三种已实现模式都退回原来的短期上下文。

MAX 的查找不能越过群聊和私聊的隔离，也不能发送。回复优先于查找；查找没完成时，用上一份已经确认的记忆。条数可配置，不是固定的 4 条，也不是空的。计划细节见 [体验需求](docs/EXPERIENCE_REQUIREMENTS.md)。

均衡和极速上还可以再加一个尚未实现的超级压缩：接近该模型上下文上限时，单独整理出核心目标和一段高密度摘要。它不是第五种模式。

## 本版本在做什么

相对上游：

- 最多 3 个指定 QQ 各有一套人设。进入模型前按发言人 QQ 分流。群主动接话用触发者的人设。`/persona` 已停用。
- 本轮只注入发言人和被点到的人，卡片只写称呼和态度。名称只用来判断有没有提到他，不用于分流。
- 基础提示词不再要求对主人固定恭敬或撒娇。一轮道歉不应当成以后的态度。
- 识图走当前模型自己的多模态，不再把图交给智谱转写。DeepSeek 有图的回合使用 `deepseek-flash`。
- 每个群可以填写不接话的 QQ。这些消息不触发 @、不触发接话、也不增加计数。
- 戳一戳单独处理，不占用普通回复的工人。
- 可以按人设置只在真实 @ 时回复、每日上限、间隔，以及更容易触发接话的权重。

以上经过合成身份和本机夹具。真实 QQ 扫码和收发仍要在使用者自己的环境里验收。微信仍在测试。Mac 原生面板暂不能编辑指定 QQ 人设。

## 上手

QQ 和 NapCat 先准备好。NapCat 增加正向 WebSocket：`127.0.0.1:3001`，消息格式为数组，自设 Token，并打开自身消息上报。

在面板里填 `ws://127.0.0.1:3001`、机器人 QQ 号、OneBot Token 和模型 API Key。连接成功不会自动开始回复。选好好友或群，做一次单次验收，再持续运行。

本仓库的 Windows 构建和一键启动说明见 [Windows 指南](docs/WINDOWS.md)。Mac 与源码见 [开发说明](docs/QUICKSTART.md)。安装、停止和包内 MCP 见 [客户端安装指南](docs/DESKTOP_INSTALL.md)。

终端路线需要 Node.js 22+。请使用完整包名，`npx dafeiyu` 是另一个项目：

```sh
npx --yes @sakurafan1023/cli@0.3.0-preview.2 setup qq
npx --yes @sakurafan1023/cli@0.3.0-preview.2 qq panel
```

这条 npm 命令安装的是上游发布的模块，不含本 fork 的引擎。要跑本仓库的改动，按 [Windows 指南](docs/WINDOWS.md) 或 [开发说明](docs/QUICKSTART.md) 从源码构建。

MCP 只调用已经装好的 QQ 能力，不会自动登录或开始回复：

```sh
codex mcp add dafeiyu -- npx --yes @sakurafan1023/mcp@0.3.0-preview.2 --modules qq
```

## 文档

| 内容 | 文档 |
| --- | --- |
| 体验需求与尚未实现的实验功能 | [体验需求](docs/EXPERIENCE_REQUIREMENTS.md) · [实施顺序](docs/EXPERIENCE_PLAN.md) |
| 记忆库设计 | [记忆库计划](docs/MEMORY_DB_PLAN.md) |
| 回复、图片和模型 | [操作指南](docs/USER_GUIDE.md) |
| 数据和凭证 | [安全说明](SECURITY.md) |
| 命令 | [命令表](docs/COMMANDS.md) |

[界面预览](docs/SCREENSHOTS.md) · [真实对话案例](docs/CASES.md)

## 反馈与许可

遇到问题请提交 [Issue](https://github.com/SAKURAfan1023/dafeiyu-bot/issues/new?template=bug_report.yml)，附版本、系统、复现步骤和脱敏错误。不要上传密钥、完整控制地址、二维码、真实聊天或记忆。作者公开联系 QQ：**2807307652**，请备注“大肥鱼 / GitHub”。

项目代码采用 [MIT](LICENSE)。内置 NapCat 遵循其原始[有限再分发许可](docs/licenses/napcat/NapCat-LICENSE.txt)。QQ 安装文件的版权归腾讯。第三方声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
