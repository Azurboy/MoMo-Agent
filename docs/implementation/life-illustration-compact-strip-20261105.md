# 时间线生活插画小条

2026-11-05，工作区 `life-ill-strip`，分支 `fix/life-illustration-compact-strip`。本轮交付为本地代码提交、真实生成样图与模拟器验收证据。

## 实现

- iPhone 与 Mac 共享单行小条，可视高 34pt、触摸区域高 44pt，包含 22pt 色样、单行时间地点和箭头。内容轴缩进 26pt，左侧 1pt 时间线贯穿插画行。
- 大图使用 24pt 横向边距、14pt 圆角和 0.5pt 边线。日期胶囊、时间地点与页码排列在画幅上方，完整日期地点通过可访问性标签提供。iPhone 使用原生 1–5 倍缩放、横向翻页、下滑关闭、分享和上下文菜单。Mac 提供键盘翻页、空格放大与 Escape 返回。
- 用户提供的真实风格板以 768×768 优化 PNG 保存于 `Apps/MacApp/Runtime/momo_character_reference.png`。该文件已受 Git 跟踪，由运行时打包脚本的源码清单收录，并随每次生成请求通过 `input_image` 传入。
- 生图采用 1024×1024、中等质量 PNG，提示词使用满幅矿物纸色、无描边象牙白 MoMo、稀疏书写墨线和大面积留白。事实、事件状态与可靠停留地点规则继续约束场景简报。
- 存图按完整画布中心适配至 1024×1024 和 512×512。保留 RGB / RGBA 数据与原有构图，拒绝全透明和纯色空图。透明旧图的完整画布、半透明笔触与位置均有像素级回归检查。

## 验收

| 项目 | 结果 |
| --- | --- |
| Python `test_life_illustrations.py` | 28 通过 |
| Python `test_webrtc.py` | 14 通过，4 跳过 |
| Swift `LifeIllustrationTests` | 6 通过 |
| Swift `RemoteContextSyncTests` | 5 通过 |
| iPhone `LifeIllustrationJourneyTests` | 最终 2 通过，覆盖明暗模式 |
| iPhone `PhoneTimelineJourneyTests` | 9 通过 |
| `MoMoAgentMac` Debug / arm64 | `CODE_SIGNING_ALLOWED=NO` 构建成功 |

4 项 WebRTC 跳过项分别需要原生 RTC 探针（3 项）和真实 TURN 配置（1 项）。Mac 验收范围为编译。构建输出中的重复资源引用、WebKit 代理签名、权限代码类型转换等既有警告记录在验收 JSON 中。

iPhone 使用 iPhone 17 Pro / iOS 27 模拟器和默认系统字号。断言覆盖 44–52pt 小条高度、26pt 对齐、相邻转录可见、连续时间线像素、354pt 正方形大图、原生缩放还原、分页、下滑关闭、关闭按钮、分享入口及设置路径。首轮浅色测试的旧截图定位手势仅移动 6.4pt，被识别为点击。删除该定位操作后，明暗两项完整重跑通过。

三份虚构验收转录通过真实登录的 Codex 订阅与正式生成队列完成，每张均为一次生成。已逐张检查原图和缩略图，分别为雾蓝积木讨论、青瓷绿观察叶片、暖石色喝茶翻页。5 张模拟器截图均已逐张检查。

## 证据位置

用户指定目录为 `/Users/syh/.gemini/antigravity-cli/brain/e9875786-40b0-4535-b293-bae3226977e5/life_ill_screenshots/`。

- `sample_code.png`、`sample_outdoor.png`、`sample_night.png` 及各自的 `_thumbnail.png`。
- `generation_evidence.json` 保存场景原文、模型简报、请求 ID、响应 ID、尝试次数和图片哈希。
- `01_iphone_timeline_inline.png`、`01b_iphone_timeline_inline_dark.png`。
- `02_iphone_fullscreen_viewer.png`、`02b_iphone_fullscreen_viewer_dark.png`、`03_iphone_settings_row.png`。
- `compact_strip_validation.json` 保存测试计数、截图哈希、尺寸、构建警告、首轮测试修正和清理记录。

构建、SwiftPM scratch、TMPDIR 和临时证据均集中在 `/Users/syh/.cache/momo-life-ill-strip-build`。专用模拟器 `3D2E0003-467C-4182-8DF1-DBB0D74FB5D0` 已删除。提交后的最终清理结果及磁盘可用空间写入上述验收 JSON。
