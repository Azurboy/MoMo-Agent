# 行程地图拖动与缩放轨迹零延迟贴合修复（0.4.12）

## 现象与根因

在手帐行程全屏地图（`LifeIllustrationJourneyMapView`）中拖动或缩放地图时，行程轨迹线、序号钉与底图街道存在明显的速度不一致与漂移感，定位到三处叠加原因：

1. **SwiftUI `Canvas` 跨层投影存在 1–2 帧渲染管线滞后：**
   - 底图由 `MKMapView` 底层 Metal 图层随触摸手势当帧平移，而原 `JourneyInkLayer` 依赖 `mapViewDidChangeVisibleRegion` 回写 `@State var projection`，触发整页 SwiftUI 视图树重算（含停留点聚合、卡片避让动态规划与 `updateUIView` 异步 `Task.yield()`），在下一帧甚至下两帧才绘制轨迹与钉点，手指拖动期间轨迹始终滞后于街道移动。
2. **屏幕像素空间（`CGPoint`）逐帧注入非线性正弦摆动：**
   - 原 `journeySmoothedPoints` 在每帧屏幕坐标上按 `< 4pt` 去重并注入 `7–18pt` 的法向波形偏移：缩放时像素振幅被非线性截断，平移或轻微缩放跨过 `4pt` 阈值还会改变点数奇偶导致整条路线摆动方向翻转，甚至把已匹配真实道路的 `MKDirections` 折线推离街道。
3. **拖动期间高频刷新无变化的 SwiftUI 状态：**
   - 卡片布局（`JourneyCalloutProjection`）在相机运动期间本就保持静止，但每帧仍向 SwiftUI 发布新投影，挤占主线程手势帧预算。

## 修复方案

1. **世界坐标曲线建模 + 原生 `MKOverlayRenderer` 绘制轨迹：**
   - 在 `LifeIllustrationJourney.swift` 新增 `journeyWorldCurvePoints` 与 `journeyWorldRouteSample`，在 `MKMapPoint` 世界坐标系一次性生成轨迹顶点：真实道路（`MKDirections`）仅做拐角微平滑以紧贴街道，离线折线在世界坐标生成恒定曲率弧线。
   - 在 `LifeIllustrationMapSurface.swift` 新增 `JourneyRouteOverlay` 与 `JourneyRouteRenderer`（`MKOverlayLevel.aboveLabels`），使描边底衬、墨线与方向箭头直接随 `MKMapView` 硬件瓦片层 `1:1` 同步平移与缩放，并在缩放停稳后按当前比例尺重绘保持恒定屏显线宽。
2. **原生 `MKAnnotationView` 渲染陶瓷序号钉：**
   - 新增 `JourneyStopAnnotation` 与 `JourneyPebbleAnnotationView`（`collisionMode = .none`、`displayPriority = .required`），序号钉与路线端点同处 `MKMapView` 原生坐标变换，保留无障碍标识与点击打开详情行为。
3. **地图内同步装饰层 + 拖动期零 SwiftUI 重排：**
   - 新增 `JourneyScreenDecorationView`（iOS 配合 120Hz `CADisplayLink`），在同一 UIKit/AppKit 提交帧内同步绘制卡片引线（奇偶裁剪避开序号钉轮廓）与路途时间胶囊；相机运动期间不再逐帧触发 SwiftUI `@State` 刷新，手势停稳后再一次性更新卡片排布。

## 验证

- `LifeIllustrationJourneyLayoutTests`（含新增世界坐标平移/缩放不变性回归测试）、`LifeIllustrationJourneyTests/testMapRepeatedZoomPinchPanAndReset` UI 测试，以及 `MoMoAgent` / `MoMoAgentMac` 双平台构建全部通过。
- 真机覆盖升级 `0.4.12` 验证版本、稳定性及拖动/缩放地图时轨迹与街道完全同步。
