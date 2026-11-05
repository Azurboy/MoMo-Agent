# 时间线生活插画 · 2026-11-05

本次仅在 `feat/timeline-life-illustrations` 开发。Mac 生成成品，iPhone 与 Mac 通过同一份清单和 SHA-256 资产展示；没有生图结果时不显示占位。移除旧手账 Canvas、ImageCreator、画风切换、独立定位器、横幅和顶栏入口。

## 数据与执行

- `Context/life_illustrations.py` 保存独立 SQLite 设置、时段、完整证据、来源版本、场景简报、请求 ID、真实执行状态、图片哈希和变更游标。默认关闭；开启后默认每 3 小时，支持 2/3/4/6 小时，按逻辑日起点对齐。
- 首次启用只从当前时段开始，封口后等待 10 分钟；手机同步真实待转录帧范围，即使尚无正文也可阻止提前生成。总结和必要原文按完整内容读取，不使用 UI 预览。
- 地点只来自已同步的、精度可靠且有首尾时间的 Core Location Visit，至少重叠 5 分钟；不使用当前定位或从对话提及推断地点。未找到可靠记录时省略地点。
- 原文语义或时间发生变化、删除来源、可靠地点证据被撤销时发布 tombstone，并清理失效资产。标点与空格变化不重复生图。调整间隔或重新启用不重绘重叠旧时段。
- 独立后台线程在聊天空闲时处理队列，先提炼具体场景，再通过现有 Codex OAuth、必需请求头和 keepalive 客户端调用 Responses 原生 `image_generation`。仅 `openai-codex` 可用，Claude 与未登录不提交生成任务。
- PNG 必须通过解码校验，居中规整为 1360×1020，另存 680×510 缩略图；原图与缩略图分别按 SHA-256 落盘。风格固定为 Chiikawa / Nagano 绘本方向，提示词禁止画面内文字、标题、数字、水印和标识。

## 同步与界面

现有鉴权 `data_url` 通道及 RTC allowlist 新增：

- `GET/POST /v1/life-illustrations/settings`
- `GET /v1/life-illustrations/manifest?cursor=0&limit=100`
- `GET /v1/life-illustrations/assets/<sha256>`
- `POST /v1/life-illustrations/delete`，正文 `{ "id": "…" }`

清单可完整分页，删除资产对应的历史事件会返回 tombstone，避免离线设备被过期 ready 事件卡住。客户端合并增量后校验和缓存图片，不把凭证或服务端临时链接交给图片视图。账户切换、Claude 或未登录会隐藏缓存图片。图片响应保留 `Cache-Control: private, no-store`。

iPhone 在对应时段最后一条转录之后展示完整 4:3 图片，小字只显示时间与可靠地点。图片不接管时间线横向手势。后台插入通过转录 ID 和行偏移保护阅读位置；用户开始滚动即撤销旧插入锚点。全屏阅读器支持左右翻图、原生捏合缩放、下滑关闭、系统分享，以及上下文菜单中的来源和删除。跨天查看依据会加载对应日期。

Mac 在左侧原位展示，右侧阅读，支持方向键、空格、Esc 和右键菜单。设置只保留开关、间隔与订阅状态。

## 验证

- Python：61 项通过，覆盖队列、首次启用、时区/DST、去重、完整证据、来源/地点失效、并发删除、断流防重投、跨页删除、既有 Context/Summary/PhoneSources、Access 鉴权、真实 HTTP PNG 与缓存头。
- Swift：12 项定向测试通过，覆盖哈希与损坏缓存、增量游标、跨页删除、订阅隐藏、设置、待转录范围及同版本进度变化。
- iPhone 模拟器：真实 App 构建及 XCTest 通过，检查时间线原位、图片尺寸、全屏阅读、左右翻图、下滑关闭、关闭返回、设置入口与 Codex 状态。只启动本次专用 iPhone 模拟器，使用默认字号。
- Mac：`MoMoAgentMac` Debug/arm64 构建通过；未启动已安装应用、未操作真机。Mac 键盘交互已实现并通过类型检查，未做桌面运行验收。
- 本地化：WebKit 共 176 个共享键检查通过；本次新增 23 个原生键四语齐备，删除 32 个不再使用的手账词条。全量 `check-localization.py` 的既有基线含 548 个缺少语言的条目，本次没有扩展到修复其他功能的词条。

真实生图样本由本机已登录 Codex 订阅生成，三个场景为**虚构验收转录**（室内讨论模块、河边散步、夜间整理），不代表用户实际发生的生活事件。逐张检查无文字、水印或程序化假画。隔离运行时中的凭证副本已删除，生产配置与数据未写入。

截图与原图副本保存在用户指定目录：

`/Users/syh/.gemini/antigravity-cli/brain/e9875786-40b0-4535-b293-bae3226977e5/life_ill_screenshots/`

包含 `01_iphone_timeline_inline.png`、`02_iphone_fullscreen_viewer.png`、`03_iphone_settings_row.png`、`sample_code.png`、`sample_outdoor.png`、`sample_night.png` 和 `generation_evidence.json`。仓库保留小型测试日志，不提交图片、凭证、模拟器数据或编译包。

## 恢复边界

Codex 的 `store=False` 没有可依赖的结果补取 API。已收到完整 PNG 时先持久保存结果，重启可恢复；提交后断流且未保存图片时记录请求 ID 并置为 `needs_review`，不自动重投。明确未接纳的限流拒绝才有限重试。MoMo 可通过只读状态工具说明真实失败或待核查状态，不承诺不存在的恢复能力。

## 复现

真实图片需先通过上述原生生成链路取得。`Tests/Support/life-illustration-fixture-server.py --samples <样本目录>` 只从现成 PNG 提供隔离 API，不读生产账号、录音或数据库；配合 `PhoneUITestConfiguration` 的 `life-illustrations` 模式，通过正常客户端鉴权、清单与哈希缓存路径进入 App。

本次提交只交付分支代码和验收证据，不递增正式交付版本、不合入 main、不推送部署。

## 清理

验收后已删除本轮 iPhone/Mac DerivedData、SPM 测试 scratch、XCTest 结果包与导出中间文件、Python 临时缓存、隔离运行库和下载的构建缓存。专用模拟器已关闭并删除，隔离 HTTP fixture 已停止。仅保留代码、上述小型证据和指定目录中的最终图片；原有三个本地编译符号链接保留且不提交。未清理其他 worktree 或生产运行目录。

结束时 `df -h .` 实际可用空间为 **5.4 GiB**；这是共享磁盘当时读数，不将其他并行任务的空间变化计作本轮释放量。
