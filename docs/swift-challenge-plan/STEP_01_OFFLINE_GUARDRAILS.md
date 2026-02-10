# STEP 01 - 离线护栏与基线对齐

## 目标

先锁死比赛约束，避免后续功能开发走到在线依赖。  
完成后，图纸创建主链路应可在飞行模式下运行。

## 输入

1. 当前代码基线（`ScanView`、`InventoryManager`、`AIService`）。
2. `challenge` 分支规则：核心功能离线可用。

## 输出

1. 全局离线开关（默认开启）。
2. 创建图纸路径不触发任何远程 API。
3. 远程识别入口有清晰禁用说明和本地替代入口。

## 实施步骤

1. 新增挑战配置模型：
   1. `AppSettings.offlineOnlyForChallenge`。
   2. 默认值 `true`。
2. 在 `AIService` 增加离线断路：
   1. 离线模式下直接返回错误类型（如 `offlineRestricted`）。
   2. UI 层将错误映射为“请使用本地图纸创建”。
3. 在 `ScanView` 增加“本地图纸创建”入口，且优先展示。
4. 在设置页加入挑战说明，明确当前模式为离线优先。

## 建议改动文件

1. `BeadInventory/Models/AppSettings.swift`（新增）
2. `BeadInventory/Managers/AIService.swift`
3. `BeadInventory/Views/ScanView.swift`
4. `BeadInventory/Views/SettingsView.swift`

## 完成定义（DoD）

1. 飞行模式下可进入图纸创建流程。
2. 不会因为未配置 API Key 卡住图纸创建入口。
3. 页面提示明确，用户知道离线模式限制和替代路径。

## 测试清单

1. 打开飞行模式，冷启动 App。
2. 进入扫描页，确认可进入本地图纸创建。
3. 触发远程 AI 入口，确认显示“离线受限”提示，不崩溃。

## 风险与回退

1. 风险：误伤其他已有识别流程。  
2. 回退：对离线限制仅作用于 `challenge` 开关开启时；关闭开关恢复旧行为。
