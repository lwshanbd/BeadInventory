# STEP 07 - 对接现有业务流程

## 目标

把 2D/3D 新产物无缝接到当前的计划创建、库存扣减、历史记录链路。

## 输入

1. 2D 输出（单层网格 + 统计）。
2. 3D 输出（多层切片 + 统计）。
3. 现有 `ScanView` 与 `InventoryManager` 流程。

## 输出

1. 统一数据桥接层。
2. 支持“单项目”与“分层子项目”两种创建策略。
3. 与现有回滚/历史机制兼容。

## 实施步骤

1. 建立转换函数：
   1. `BlueprintStats -> [ScanView.RecognizedItem]`。
   2. `LayerStats[] -> parent/child ProjectRecord`。
2. 新增创建入口：
   1. 2D 结果页“一键创建计划”。
   2. 3D 结果页“合并创建 / 分层创建”。
3. 复用现有扣减逻辑：
   1. 由 `InventoryManager` 执行扣减。
   2. 保留品牌色系匹配校验。
4. 历史记录一致性：
   1. 保证新增项目可被撤销与追踪。

## 建议改动文件

1. `BeadInventory/Views/ScanView.swift`
2. `BeadInventory/Managers/InventoryManager.swift`
3. `BeadInventory/Models/SwiftDataModels.swift`（仅在需要时扩展字段）

## 完成定义（DoD）

1. 2D 结果可直接创建计划并执行。
2. 3D 结果可创建父子结构项目。
3. 扣减后库存变化与统计一致，且支持现有撤销机制。

## 测试清单

1. 2D 结果创建计划后检查项目详情。
2. 3D 分层创建后检查父子关系、合并统计。
3. 执行扣减后检查低库存提示与历史记录。

## 风险与回退

1. 风险：引入新模型导致历史/迁移复杂度上升。  
2. 回退：优先复用现有 `ProjectRecord` 字段，不新增复杂 schema。
