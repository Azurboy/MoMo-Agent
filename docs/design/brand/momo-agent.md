# MoMo Agent 品牌

## 宣发视觉参考

团队选定以下两张原图作为 MoMo Agent 的宣发视觉参考。两张均为 1774 × 887 像素横图，沿用 MoMo 睁眼的角色轮廓和 Pebble 字标。

### 黑底白影 · 角色特写（01D）

![黑底白影。白色 MoMo 从画面右下方探出，白色字标位于左上角。](promo-avatar-closeup.png)

适合发布预告、社交分享卡和演示封面。大面积黑底衬出角色，左上角留给完整字标。改成方图或竖图时，可以让脸的下沿和侧边出画，同时保留一高一低的头顶轮廓和双眼，让小尺寸预览也认得出 MoMo。

### 白纸墨线 · 手绘日常（03D）

![白纸墨线。咖啡杯、车票、钥匙和腕表围绕中央的黑色 MoMo 图标与字标。](promo-daily-sketch.png)

适合功能介绍、使用故事和日常场景海报。围绕一个具体时刻挑选物件，用带有疏密变化的黑色笔触从画面边缘画入，中央留白承托图标和字标。例如讲手腕记录时，可把佩戴 MoMo 的腕表放在前景，让咖啡杯交代谈话发生的场景。

同一手绘形式的深色应用可参见 GitHub README 已采用的 [03E「炭纸夜绘」](../../assets/readme-cover.jpg)。

## 当前图标：正面睁眼 Avatar（2026-10-30）

用户要求所有应用图标使用既有 MoMo Avatar 的正面、双眼睁开姿态，不再使用 M。角色形状直接复用 `Vendor/BibleStrongAvatar/momoagent-avatar.json` 与固定版本的几何引擎；头部三轴旋转归零，两眼尺寸与高度一致，不采样眨眼或动画帧。静态导出提高轮廓采样密度，避免大尺寸图标出现折线；动态角色实现不变。

- `avatar-front.svg`：当前完整图标母版，沿用动态 Avatar 深色外观的 `#171717` 底色与 `#F4F4F4` 角色。
- `avatar-front-template.svg`：同一正面轮廓与透明眼睛，用于 Mac 菜单栏模板。
- 中英文 README 首图共用 `docs/assets/readme-cover.jpg`（03E「炭纸夜绘」）。原圆角图标 `docs/assets/readme-icon-rounded.png` 由同一矢量母版导出。从仓库根目录运行 `swift docs/design/brand/export-readme-icon.swift` 可重新生成；平台应用图标仍交给系统施加遮罩。
- iPhone、Watch：同源 1024 × 1024 不透明 PNG，由系统施加平台遮罩。
- Mac：使用 Icon Composer 原生矢量包 `MacAppIcon.icon`（`#171717` 满版底色 + `#F4F4F4` 角色矢量前景），由 `actool` 同时编译 macOS Tahoe Liquid Glass 无灰框满版图标栈与向下兼容的 `MacAppIcon.icns`；菜单栏使用透明模板。
- 应用内品牌入口、任务状态图、README 的 `app-icon.png` 与 `momo-avatar.png` 同步更新。Pebble 字标、Avatar 的动态表情、Bundle ID 与用户数据保持现有行为。
- `app-icon-source.png` 保留为此前用户提供的 M 原稿，仅作历史来源，不再参与当前导出。

从仓库根目录重新导出：

```sh
node Tools/Brand/export-avatar.mjs
swift Tools/Brand/export-icons.swift
```

公开版本仍为 0.0.1。此次按用户要求只保留新的安装包；源码与构建验证不能代替设备安装或系统图标缓存刷新。

本轮验证：13 个平台图标重复导出的哈希一致，6 个完整彩色品牌资源内容一致；iPhone/Watch 为无透明通道的 1024 像素 PNG。品牌动效回归与 32 项离线渲染资源校验通过，iPhone（包含 Watch/Widget）及 Mac Release 构建成功。29 项手机包检查按现有本地升级标识通过，四个包的签名均验证通过；Mac 交付包保留原证书和 designated requirement，并将运行源码路径指向稳定的主仓库。已核读编译后的手机与 Mac 图标，确认 Watch 编译资源包含 1024 像素 AppIcon，并检查三平台遮罩及 18/24/32 像素菜单栏预览。没有执行设备安装或刷新正在运行的应用。

## 2026-10-27 品牌切换历史

以下记录保留当时的素材、范围与验收结果，图标选择以以上 2026-10-30 决定为准。

2026-10-27 用户确认：产品名为 **MoMo Agent**，使用本次选定的三块不规则鹅卵石组成的 M 图标。助手昵称仍为 MoMo，既有角色形象保留。

## 资源

- 原稿：`app-icon-source.png`，直接保存用户选定的 1254 × 1254 PNG，未重绘、镜像或重新生成。
- 原稿 SHA-256：`a4db48f74f558ef21461d98ee81cd1546514e76558b94cd248e64fd1a7bcb31f`。
- iPhone、Watch：1024 × 1024 不透明图标；由系统施加圆角或圆形遮罩。
- Mac：16–1024 像素的完整图标集，保持既有 macOS 图标留白；菜单栏模板从同一原稿提取三个石头的透明轮廓。
- 欢迎页、侧栏、配对页共用 `PhoneBrandIcon` 与 `PhoneBrandWordmark`。产品字标为 MoMo Agent；MoMo 沿用已确认的 Pebble 矢量轮廓，Agent 为圆体文字轮廓，不依赖运行时字体下载。
- 任务状态复用同一 M 原稿轻微呼吸；保留离屏/后台暂停与减少动态效果行为。聊天等待继续使用三点。旧 W 动画不再用于运行中的 UI。

从仓库根目录重新导出：

```sh
swift Tools/Brand/export-icons.swift
swift Tools/Brand/export-wordmark.swift
```

## 名称与兼容性

手机、手表、小组件、Mac 的 `CFBundleDisplayName` / `CFBundleName` 均为 MoMo Agent；Beta 为 MoMo Agent Beta。Mac 构建产物名为 `MoMo Agent.app`（Beta 为 `MoMo Agent Beta.app`），内部可执行文件名保持不变。

同步更新系统权限说明、配对提示、设置相关提示、菜单、四种语言的本地化文案、导出说明和 Hermes 的产品身份。已有 SOUL 只迁移精确匹配的自动生成开场，不覆盖用户人格或其余内容。

Bundle ID、Keychain service、App Group、URL scheme、配对协议中的 `application: MoMoAgent`、数据库与运行目录均保留，已有安装的数据和连接不因品牌名称变化而迁移或失效。上游 Hermes 等组件的名称及许可证保留原样；历史设计与验收记录不冒充新版本。

### 全仓命名范围（2026-10-27）

当前产品文案、README、方案及工具说明统一为 **MoMo Agent**；代码仓库为 `xilanhua12138/MoMo-Agent`。助手昵称 **MoMo** 不变。对旧方案只更新品牌称谓，不改变原来的日期、实现范围或验收结论。

搜索旧名仍会看到以下有意保留的内容，它们不能作为新产品文案复用：

| 范围 | 保留原因 |
| --- | --- |
| Bundle ID、App Group、Keychain、URL scheme、协议字段、插件标识、数据目录 | 已安装版本、历史数据、引用与配对继续兼容 |
| Xcode 工程 / scheme、Swift package / 类型名、内部可执行文件、资源文件路径 | 构建与调用标识；界面名称由独立的显示名称决定 |
| 旧 SOUL 精确匹配、迁移及兼容测试夹具 | 用于识别旧数据，不改写用户自定义内容 |
| `docs/implementation/` 中当时的安装、进程和外部控制台记录；旧 Pen 稿、截图、日志与验收 JSON | 保留实际观察到的历史事实；旧设计不作为当前品牌规范 |
| 第三方源码、许可证与出处 | 保留上游身份与来源 |

本轮清理未迁移上述兼容标识。语音运行库下载清单改用当前仓库地址，固定版本、附件名与校验值保持不变。上架材料只同步名称，其旧版架构与审核流程仍需发布前单独复核。

清理验证：运行时 `test_runtime.py` 的 13 项回归通过，覆盖旧身份迁移、定制人格和运行目录保护；文档链接目标及代码示例逐项保持，Pen 仅修改 5 处可见文案，JSON 解析通过。当前仓库的固定语音发行版本与 iOS / macOS 附件均由 GitHub API 读回确认。配置、原生应用源码、Swift packages 与上游源码无变更；本轮未重新构建原生应用。手机安装沿用已验证的 1.36.0 包，实际结果见设置资料来源的交付记录。

## 交付与验证

独立分支：`codex/momo-agent-brand-20261027`，基于 main `25d05eba309a820e9abc71a19e3665e7179328fd`。品牌实现提交为 `5ec45761`；用户随后明确授权合入本地 main。本次不推送、安装或重启正在使用的应用。版本沿用基线 1.35.1，仅生成无签名验证包；后续实际发布由集成任务按版本规则递增。

已完成：

- XcodeGen 2.46.0 生成工程。
- iPhone Release 构建成功，包含 Watch 与 Widget；Mac Release 构建成功。
- `Tests/Support/verify-release-bundle.py`：29 项静态检查全部通过。
- 读取四个实际构建包的名称、版本与 Bundle ID，确认新名称和原身份一致。
- `uv run --no-project python -m unittest discover -s Tests/AgentRuntime -p test_runtime.py -q`：13 项通过，包括品牌迁移幂等、保留定制 SOUL 和原运行身份。
- `swift test --package-path Packages/MoMoAgentAgentClient --filter PairingTests`（独立 scratch 目录）：5 项通过，旧配对协议继续有效。
- `node Tests/Support/brand-motion.test.cjs`：动画时钟、可见性、减少动态效果、销毁与恢复检查通过。
- `uv run --no-project python Tools/ChatRenderer/prepare-vendor.py`：32 项离线渲染资源校验通过。
- 使用实际编译资源及 `PhoneBrandIcon` / `PhoneBrandWordmark`，以默认字号渲染 320 点宽的深浅色品牌行；字标完整且着色正确。另检查三个平台遮罩与菜单栏图标预览。

证据目录：`/Users/syh/Documents/Codex/2026-10-21/jie-he/outputs/momo-agent-brand-20261027/`。`brand-preview.png` 为资源预览，`native-header-light-dark.png` 为原生组件渲染，均不是真机整页截图。构建日志、静态检查及实际包名称记录同在该目录。

未执行：签名发布、设备安装、SpringBoard / Dock 图标缓存刷新、真机或完整 App 界面验收。运行中的旧 App 不会因源码修改而立即更名。

后续用户授权的 **1.35.2** 三端签名安装与启动已完成，实际结果及验收范围见 [MoMo Agent 真机更新](../../implementation/momo-agent-install-20261027.md)。上面的未执行项描述品牌开发轮次，不代表后续交付状态。
