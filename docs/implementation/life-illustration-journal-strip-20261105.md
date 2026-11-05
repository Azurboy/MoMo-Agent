# 时间线底部邮票贴纸

2026-11-05，分支 `feat/life-illustration-journal-strip`。交付范围为代码提交、真实 Codex 样图、iPhone 模拟器验收与 Mac arm64 构建。

## 实现

- iPhone 和 Mac 共用 `LifeIllustrationStripView`。底栏高 68.5pt，单张邮票 104×52pt，水平间距 12pt，手机与桌面页边距分别为 24pt、16pt。两侧各四个内凹齿孔，细虚线分隔票根，42pt 透明贴纸按稳定 ID 轻微旋转，纸色适配明暗模式。
- 插画按选中记录日过滤、按时间排序，在时间线下方独立横排。iPhone 底栏位于迷你播放器上方。移除原插画行、插入锚点与相关偏移状态。相邻转录直接连接，搜索与无可用图时收起底栏。
- 全屏使用双细线收藏纸页、日期与等宽时间、页码和查看原文入口。iPhone 覆盖原生 1–5 倍缩放、横向翻页、下滑关闭、分享和上下文菜单。来源跳转按 `logicalDay` 的字面日期定位，再匹配重叠转录窗口。
- `CodexIllustrationGenerator` 使用既有参考板和真实 Codex 订阅，明确请求透明 PNG。场景采用不透明象牙白 MoMo、矿物色有机纸片与墨线。
- `LifeIllustrations.save_image()` 处理透明图的可见边界与低透明度杂点。独立 Pillow 模块生成 660px 以内画芯、平滑象牙白纸边、细切边和偏移阴影，输出 1024px 主图及紧裁后居中的 512px 缩略图。RGB 旧图使用既有中心适配流程。

## 验收

| 项目 | 结果 |
| --- | --- |
| Python 插画 | 29 通过 |
| Python WebRTC，含本地原生探针 | 17 通过，真实 TURN 配置依赖项 1 跳过 |
| Swift `MoMoAgentClientTests` | 136 通过，上游 Relay 外部服务依赖项 1 跳过 |
| `RemoteContextSyncTests` | 5 通过 |
| `PhoneTimelineJourneyTests` | 9 通过，空底栏断言更新后单项复测通过 |
| `LifeIllustrationJourneyTests` | 明暗两项通过 |
| `MoMoAgentMac` | arm64 构建通过，`CODE_SIGNING_ALLOWED=NO` |

模拟器为 iPhone 17 Pro / iOS 27，系统默认字号。UI 断言覆盖底栏全宽与高度、三张邮票尺寸和横向对齐、22:18 与 23:12 转录直接相接及时间线像素、页码、缩放还原、分页、两种关闭方式、来源导航、搜索收起、空状态和设置。

首轮 UI 发现背景延伸到 Tab 栏安全区，导致可访问范围高 151.58pt。限制背景安全区后明暗测试通过。Mac 首次下载固定依赖遇到 HTTP 504，复用已有缓存并通过原有校验后构建成功。原生 RTC 首轮直连失败，完整重跑通过。构建中的既有资源引用、ONNX 头文件与并发声明等警告记录于验收 JSON。

## 图片与证据

用户指定目录为 `/Users/syh/.gemini/antigravity-cli/brain/e9875786-40b0-4535-b293-bae3226977e5/life_ill_screenshots/`。

- `sample_code.png`、`sample_outdoor.png`、`sample_night.png` 与各自 `_thumbnail.png` 均由本轮生成，每张一次请求成功。逐张检查主图与缩略图，外侧四角透明、纸边颜色为 `#FAF8F2`。缩略图最长非零 alpha 边为 468px。
- 已导出并检查指定的五张 `01` / `01b` / `02` / `02b` / `03` 模拟器截图。
- `generation_evidence.json` 包含虚构验收场景、简报、请求与响应 ID、尝试次数和图片哈希。账号使用实际登录目录 `~/Library/Application Support/MoMoAgent/Agent`，场景与队列存放于隔离测试目录。
- `journal_stamp_validation.json` 包含测试摘要、图片尺寸与哈希、构建警告、重试记录和清理快照。详细测试日志位于 `journal_stamp_test_logs/`。

已停止测试服务并删除专用模拟器，清理本轮 iPhone、Mac、SwiftPM 编译目录、临时队列、测试包与结果包，以及四个本地依赖符号链接。清理后实际磁盘可用空间为 8.16 GiB，该数值为整盘快照。
