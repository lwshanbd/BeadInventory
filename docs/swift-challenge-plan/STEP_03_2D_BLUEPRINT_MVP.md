# STEP 03 - 2D 图纸生成 MVP

## 目标

从用户图片快速生成“可用图纸 + 数量统计”，并可直接创建计划。

## 输入

1. 原图（拍照/相册/分享扩展）。
2. 目标板尺寸（如 32x32、64x64、96x96）。
3. `PaletteMatcher` 匹配能力。

## 输出

1. 二维图纸网格（每格一个色号）。
2. 色号统计（`colorCode -> quantity`）。
3. 与 `ScanView.RecognizedItem` 兼容的数据。

## 实施步骤

1. 新建 `Blueprint2DService`：
   1. 接收图片和尺寸参数。
   2. 执行预处理（裁剪、缩放、归一化）。
2. 执行逐像素匹配：
   1. 每个像素映射到最近拼豆色号。
   2. 生成 `[[BeadCell]]` 网格。
3. 聚合统计：
   1. 输出颜色数量表。
   2. 转换为 `RecognizedItem`。
4. 构建最小 UI：
   1. 图片输入。
   2. 尺寸选择。
   3. 预览与统计列表。
   4. “创建计划”按钮。

## 建议改动文件

1. `BeadInventory/Managers/Blueprint2DService.swift`（新增）
2. `BeadInventory/Views/BlueprintCreateView.swift`（新增）
3. `BeadInventory/Views/ScanView.swift`（新增入口/数据接收）

## 完成定义（DoD）

1. 单张图片可在 10 秒内生成图纸结果。
2. 可一键创建计划，计划统计与图纸统计一致。
3. UI 无明显卡死，失败时有错误提示。

## 测试清单

1. 选择 5 张不同风格图片，验证都可生成。
2. 检查统计总数是否等于网格总格数（如 64x64 = 4096）。
3. 从结果页进入计划创建并查看项目详情数量。

## 风险与回退

1. 风险：细节过多导致视觉噪点重。  
2. 回退：在 MVP 阶段先保证统计准确，视觉优化放到 STEP 04。
