# STEP 05 - 3D LiDAR 采集

## 目标

在支持 LiDAR 的设备上获取稳定的几何输入（网格/深度），作为 3D 图纸生成前置。

## 输入

1. 支持 LiDAR 的 iPhone/iPad。
2. ARKit 会话能力（scene reconstruction）。

## 输出

1. 可控的扫描会话（开始/暂停/结束）。
2. 网格数据快照（`ARMeshAnchor` 聚合结果）。
3. 不支持设备的降级提示流程。

## 实施步骤

1. 设备能力检测：
   1. `ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)`。
   2. 不支持则隐藏入口或提示仅可使用 2D。
2. 扫描会话管理：
   1. 创建 `LiDARCaptureManager` 包装 `ARSession`。
   2. 在会话中持续收集 mesh anchors。
3. 扫描 UI：
   1. 引导文案（环绕拍摄、距离建议、光照建议）。
   2. 显示当前扫描状态和覆盖率。
4. 结果导出：
   1. 结束时导出统一 mesh 数据结构供 STEP 06 使用。

## 建议改动文件

1. `BeadInventory/Managers/LiDARCaptureManager.swift`（新增）
2. `BeadInventory/Views/Blueprint3DScanView.swift`（新增）
3. `BeadInventory/Views/MoreView.swift` 或 `ScanView.swift`（新增入口）

## 完成定义（DoD）

1. 在 LiDAR 设备可完成一次扫描并拿到 mesh 数据。
2. 在非 LiDAR 设备不会崩溃，并有明确替代建议。
3. 扫描结束后可进入后续处理页。

## 测试清单

1. 真机执行 3 次扫描，确认都能完成导出。
2. 非 LiDAR 设备点击入口，确认降级提示正常。
3. 扫描中中断/返回前台后，状态可恢复或安全退出。

## 风险与回退

1. 风险：透明/反光材质深度数据差。  
2. 回退：加入扫描前提示并建议用户选哑光、纹理明显物体演示。
