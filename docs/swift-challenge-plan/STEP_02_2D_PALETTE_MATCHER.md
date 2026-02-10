# STEP 02 - 2D 调色板匹配引擎

## 目标

将图像颜色稳定映射到拼豆色号，为 2D/3D 共用。

## 输入

1. `allcolors.json` 色表数据。
2. 当前 `ColorSystem`（MARD / 卡卡）。

## 输出

1. 可复用颜色匹配服务 `PaletteMatcher`。
2. 可配置匹配策略（快速/高精度）。
3. 稳定可重复的匹配结果。

## 实施步骤

1. 建立颜色转换工具：
   1. `RGB -> XYZ -> Lab`。
   2. 统一 D65/2deg 参考参数。
2. 初始化调色板缓存：
   1. App 启动或首次调用时预计算每个色号的 Lab。
   2. 按 `ColorSystem` 提供过滤和显示码映射。
3. 实现距离算法：
   1. V1：CIE76（性能优先）。
   2. V2：CIEDE2000（准确优先，可开关）。
4. 提供统一接口：
   1. `match(color: UIColor, colorSystem: ColorSystem) -> BeadColor`
   2. `batchMatch(pixels: [SIMD3<Float>], colorSystem: ColorSystem) -> [BeadColor]`

## 建议改动文件

1. `BeadInventory/Managers/PaletteMatcher.swift`（新增）
2. `BeadInventory/Models/BlueprintModels.swift`（新增）
3. `BeadInventory/Managers/InventoryManager.swift`（仅在需要时增加色表读取辅助）

## 完成定义（DoD）

1. 对固定输入样本结果一致（可复现）。
2. 支持按色系输出正确 display code。
3. 性能可接受（128x128 图片匹配不明显卡顿）。

## 测试清单

1. 用 20 组固定 RGB 样本做快照测试。
2. 同一图片重复匹配 5 次，统计完全一致。
3. MARD 与卡卡分别测一轮，确认色系隔离正确。

## 风险与回退

1. 风险：CIEDE2000 在大图上慢。  
2. 回退：默认 CIE76，CIEDE2000 作为可选高质量模式。
