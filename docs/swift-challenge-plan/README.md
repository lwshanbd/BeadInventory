# Swift Challenge 项目总览（按步骤执行）

本目录是 `challenge` 分支的执行手册。  
目标：在离线环境下完成「2D/3D 拼豆图纸创建 + 自动统计 + 接入现有库存/计划流程」。

## 项目目标

1. 2D 图纸创建：上传图片后自动生成拼豆网格与色号统计。
2. 3D 图纸创建：利用 LiDAR/ARKit 扫描实体，生成分层 2D 图纸与总统计。
3. 业务接入：结果直接进入现有 `ScanView -> 计划创建/库存扣减` 链路。
4. 比赛约束：核心流程完全离线，不依赖云端 API。

## 执行原则

1. 每一步必须可独立开发、独立测试、独立回滚。
2. 先打通链路，再做质量与性能优化。
3. 优先复用现有模型和流程，避免平行系统。
4. 所有新功能默认走离线路径。

## 步骤索引

1. [STEP 01 - 离线护栏与基线对齐](./STEP_01_OFFLINE_GUARDRAILS.md)
2. [STEP 02 - 2D 调色板匹配引擎](./STEP_02_2D_PALETTE_MATCHER.md)
3. [STEP 03 - 2D 图纸生成 MVP](./STEP_03_2D_BLUEPRINT_MVP.md)
4. [STEP 04 - 2D 质量增强与编辑器](./STEP_04_2D_QUALITY_AND_EDITOR.md)
5. [STEP 05 - 3D LiDAR 采集](./STEP_05_3D_CAPTURE_WITH_LIDAR.md)
6. [STEP 06 - 体素化与分层图纸](./STEP_06_VOXEL_AND_LAYER_BLUEPRINT.md)
7. [STEP 07 - 对接现有业务流程](./STEP_07_INTEGRATE_EXISTING_FLOW.md)
8. [STEP 08 - 性能与稳定性](./STEP_08_PERFORMANCE_AND_STABILITY.md)
9. [STEP 09 - 测试与验收](./STEP_09_TEST_AND_ACCEPTANCE.md)

## 建议执行顺序

按 `STEP_01 -> STEP_09` 顺序推进。  
若中途发现架构问题，优先回到 `STEP_01` 的离线与边界约束重新收敛。

## 关键产出

1. `Blueprint2DService`：2D 图纸创建主服务。
2. `PaletteMatcher`：颜色匹配核心算法。
3. `LiDARCaptureManager`：3D 扫描输入能力。
4. `VoxelBlueprintService`：3D 分层图纸生成能力。
5. 新建图纸相关视图和现有 `ScanView` 对接入口。

## Apple 官方参考

1. ARKit Scene Reconstruction  
   https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/3521376-scenereconstruction
2. ARMeshAnchor  
   https://developer.apple.com/documentation/arkit/armeshanchor
3. LiDAR 深度采集  
   https://developer.apple.com/documentation/avfoundation/capturing-depth-using-the-lidar-camera
4. Object Capture  
   https://developer.apple.com/documentation/realitykit/creating-3d-objects-from-photographs/
5. Vision 矩形检测  
   https://developer.apple.com/documentation/vision/vndetectrectanglesrequest
