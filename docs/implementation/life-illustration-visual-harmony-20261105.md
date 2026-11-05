# 时间线生活插画 · MoMo 视觉统一

分支 `fix/life-illustration-visual-harmony`。只修改 `life-ill-polish` worktree，不合并、不推送、不安装到真实设备；版本号保持不变。

## 画面与布局

- 每个时段只提炼一个有依据的瞬间，120–240 字。保留原文不可信输入、讨论/计划/尝试/完成区分、非用户经历与 SKIP 约束；可靠地点仍须来自已完成 CoreLocation visits，重叠至少 300 秒、精度不超过 200 米。
- 生成时通过 `input_image` 传入 `Runtime/momo_character_reference.png`。此 512px 参考图从 `docs/assets/momo-avatar.png` 缩小，保留同一角色的双隆起头型与竖椭圆眼睛；已进入 Git 文件清单，随 `bundle-mac-runtime.py` 一起打包。
- Codex 原生 `image_generation` 请求 1024×1024、medium、transparent、PNG。单一动作、白色/冷灰物件、炭黑线稿和一种小面积淡色，禁止宽幅分镜与纸色底块。
- 原图保存为 1024×1024 RGBA，缩略图 512×512 RGBA。根据可见 alpha 边界裁掉多余留白，四周保留 2px 细边，完整等比放入 860px 方框并居中。低于 9/255 的离散透明杂点不扩大裁边；全空图片拒绝发布。旧的不透明 PNG 仍可读取，不强制改写历史资产。
- 手机和 Mac 列表统一使用 96×96pt 图像，行高 112pt，时间说明在右侧。左侧 12pt 轴列与 14pt 间距对齐转录正文；连接线贯穿插画、标记区和下一行顶部，取消插画外部的大段留白。
- 浅色模式直接呈现透明图像；深色模式仅在方形图像下放置圆角冷白底，保护独立蒸汽线与动作线。手机全屏与 Mac 阅读器使用相同底面规则。
- 原有图片标识、来源/删除菜单、分享、分页和阅读位置逻辑保留。

## 验收方式

`Tests/Support/generate-life-illustration-samples.py` 在独立工作目录建立虚构转录和队列，通过真实 `LifeIllustrations` + `CodexIllustrationGenerator` 生成图片。生产账号仅提供现有 Codex 授权，不读取生产录音，也不写入生产插画数据库。三次生成均一次完成；最终保存再用修正后的 alpha 裁边规整，未重放图像请求。

三个新场景为桌边用积木讨论模块接口、两人观察地上的叶子、台灯旁喝茶翻画册。简报分别为 138、155、151 字，均未将未完成的动作画成已完成。逐张视觉检查 MoMo 轮廓、眼型、透明背景和单一焦点。

所有原图、缩略图、截图和请求/哈希证据位于用户指定的 `life_ill_screenshots` 目录。fixture server 读取这些真实 PNG，通过正常清单、鉴权、SHA-256 缓存路径交给模拟器 App。

Python 日志、Swift 测试日志、请求证据、截图哈希和构建摘要在[同名目录](life-illustration-visual-harmony-20261105/validation.json)中。

| 验证 | 结果 |
| --- | --- |
| Python `test_life_illustrations.py` | 26 通过；RGBA、边界、透明杂点、旧图、地点规则和原生图像请求 |
| Python `test_webrtc.py` | 14 通过，4 跳过；原生 probe 与 TURN 未配置，二进制插画与鉴权路由已执行 |
| Swift `LifeIllustrationTests` | 6 通过 |
| Swift `RemoteContextSyncTests` | 5 通过 |
| iPhone `LifeIllustrationJourneyTests` | 最终一轮 2 通过；深浅色、96pt 图像、相邻行对齐、连续连接线像素、缩放、分页、下滑关闭、设置入口 |
| iPhone `PhoneTimelineJourneyTests` | 9 个当前用例均通过：原轮 8 项通过，修正旧引用卡片预期后重跑第 9 项通过 |
| `MoMoAgentMac` Debug | `CODE_SIGNING_ALLOWED=NO` 编译通过；仅有既存警告 |

UI 验证仅使用默认字号、单台 iPhone 17 Pro / iOS 27 模拟器。系统 appearance 指令报告成功但未改变实际画面，因此仅在 Debug 且带有效 UI 测试 UUID 时，允许用测试环境选择原生 `preferredColorScheme`；普通运行和 Release 不覆盖外观。深色用例检查实际背景像素，避免导出误标为深色的浅色截图。缩放直接作用于原生图片滚动视图，并核对放大与还原后的图片边界。

旧时间线用例期待已移除的引用卡片，且 fixture 没有配对 Mac；现保留合并转录与回听验证，并检查讨论按钮禁用和聊天连接入口。原失败和最终通过记录均保留在 `ui-tests.txt`。未改动真实配对行为。

已逐张查看最终 `sample_*.png`、深浅色时间线、深浅色全屏和设置截图：没有宽幅底块，文字轴对齐，插画上下连接连续，深色底面保留独立细线。Mac 本轮完成编译与共享样式核对，未做桌面运行截图验收。

复现时将 `TMPDIR`、SPM `--scratch-path` 和 Xcode `-derivedDataPath` 全部放在 `/Users/syh/.cache/momo-life-ill-polish-build` 下；验收完成后删除该目录及本轮专用模拟器。

2026-11-05 14:19 收尾：fixture server 已停止；临时模拟器 `D9D7B450-8F10-47C4-8FF9-F5931E32CD42` 已关闭并删除；构建缓存整目录与本轮生成的 `Vendor/AgentDesktop/Cache` 已删除。清理前核对无活跃构建或打开文件依赖。磁盘实际可用空间读回 **8.00 GiB**；不将并行任务造成的空间变化计为本轮释放量。保留源码、原有模型/工具符号链接、实际安装应用与最终验证证据，详见 `cleanup.json`。

API 请求字段亦对照 [OpenAI 图像生成文档](https://developers.openai.com/api/docs/guides/image-generation)；订阅路径的可用性以本轮真实生成结果为准。
