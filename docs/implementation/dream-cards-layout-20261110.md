# Dream 聊天卡片布局修正

移除聊天输入框上方重复的晨间简报横幅，将 Dream 建议改为紧凑的横向纸色便笺。实现集中在 `Apps/ClientUI/ClientControls.swift`；已核对 `DesktopChat` 和 `RemoteConversationView`，两端继续复用原调用和回调。

- 点阵在 100 × 100 的逻辑画布内绘制，再按容器短边统一缩放并居中，六种纹样均不随容器宽高比变形。
- 宽窗口双列，窄窗口单列；只剩一张时占满宽度。同排卡片随最长内容等高，没有原来的固定大高度和纵向 Spacer。
- 使用 `MoMoPalette.paper / ink / muted / line`，保留点阵的原有配色。示例紧凑卡片高 72pt；标题、语境各允许两行。
- 每张卡片右上角独立关闭。iOS 关闭区域为 44 × 44pt，和选择卡片的按钮分开；右键或长按菜单继续提供简报、笔记本和收起操作。
- `DreamHomeCardsSection` 的初始化参数、`DreamBriefingDocument` 解析和 `assistant.suggestion.<card.id>` 保持不变。新增关闭标识 `assistant.dismissSuggestion.<card.id>`。

## 验证

Xcode 27.0 / Swift 6.4，系统默认字号：

- `MoMoAgentMac`：Debug、macOS arm64，最终构建成功。
- `MoMoAgent`：Debug、iOS 27.0 Simulator arm64，含内嵌 Watch 的测试构建成功。
- `LifeIllustrationJourneyLayoutTests` 原有 10 项全部通过；另运行 1 项临时 ImageRenderer 快照探针，合计 11 项、0 失败。导出后移除临时探针，既有测试文件未改动。
- macOS 直接渲染生产视图；iPhone 快照在 iOS 测试宿主内渲染生产视图。检查 760pt / 390pt / 320pt、明暗模式、单卡和长文案。
- 六种纹样在 64 × 64 与 360 × 64 容器中的居中区域逐像素比较：最大色值差仅 1/255，属于抗锯齿舍入；没有横向伸展。
- SwiftUI 静态扫描没有高风险项。未进行真机安装、VoiceOver 或完整键盘交互验收；本次交付范围为共享视图、构建与布局验证。

证据：[构建与测试摘要](evidence/dream-cards-20261110/validation.txt)、[桌面明色](evidence/dream-cards-20261110/desktop-760-light.png)、[桌面暗色](evidence/dream-cards-20261110/desktop-760-dark.png)、[长文案](evidence/dream-cards-20261110/desktop-760-long.png)、[单卡](evidence/dream-cards-20261110/desktop-760-single.png)、[iPhone 明色](evidence/dream-cards-20261110/iphone-390-light.png)、[iPhone 暗色](evidence/dream-cards-20261110/iphone-390-dark.png)、[点阵比例对照](evidence/dream-cards-20261110/motifs-square-and-wide.png)。快照以 2× 输出，四周另含验证用留白。

## 清理

构建期间曾因磁盘写满中断，清理后串行重跑成功。已删除本轮 `dream-cards-20261110` 构建目录、包缓存、临时渲染程序和测试包，以及确认无人使用的本项目旧 DerivedData、根目录 `.build`、`MoMoAgentAgentClient/.build`。仅保留约 500KB 的快照和验证摘要。

验证用 iPhone 18 Pro 模拟器已关闭；另一任务的 Processing Status 模拟器和构建目录继续保留。已安装应用、模型、用户数据、共享缓存及私有运行环境保留。收尾 `df -h /` 实测可用空间 **2.9GiB**；并行任务也在运行，因此不把空间变化全部计为本轮释放量。
