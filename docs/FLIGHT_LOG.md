# Flight Log - AI Change Records

> This file is automatically maintained by Claude Code's Flight Recording system.
> It serves as the single source of truth for AI-assisted code changes.

---


### [Bugfix] 2026-02-05T00:34:16.136412

**Summary**: 移除 deleteProject 中的 restoreStockFromProject 调用 (InventoryManager.swift:1133-1154)，删除项目不再恢复库存

**Risk Analysis**: Low - 简化了删除逻辑，修复了撤销操作导致库存重复增加的 bug

**Status**: ✅ Committed to Source of Truth

---

### [Feature] 2026-02-06T01:08:12.620089

**Summary**: Added remote announcement system: AnnouncementManager.swift (new), ContentView.swift (added alert), BeadInventoryApp.swift (trigger on launch), tools/generate_announcement.py (signing tool). Silent URL fetch with HMAC-SHA256 signature validation.

**Risk Analysis**: Medium - network request on every app launch (but with 10s timeout and silent failure); requires user to configure URL and HMAC key before actual use; no impact on existing functionality if URL is unreachable

**Status**: ✅ Committed to Source of Truth

---

### [Bugfix] 2026-02-06T01:21:29.222823

**Summary**: Fixed duplicate stock deduction in folder replenish suggestions and stock checks. Changed 3 calls from aggregatedBeadUsage to plannedAggregatedBeadUsage in PlannedProjectsView.swift (lines ~1389, ~2438, ~2575). These now only count unexecuted sub-projects.

**Risk Analysis**: Low - isolated fix replacing method calls with existing equivalent that filters by execution status. ProjectDetailView.swift display usage intentionally unchanged.

**Status**: ✅ Committed to Source of Truth

---

### [Feature] 2026-02-06T01:58:51.046525

**Summary**: Updated display references of mardCode to use displayCode(for:) in 6 view files: StatisticsView.swift (line 280), AddInventoryView.swift (lines 30, 52, 317), ShippingView.swift (AddPurchaseRecordView & AddColorToRecordSheet series grouping/sorting/display), ScanView.swift (ManualEntrySheetNew series grouping/sorting, ManualEntryColorRow display), PlannedProjectsView.swift (AddColorToProjectSheet search filter & display text). Also added kakaCode row to ColorConverterView.swift card and detail sheet. Internal/storage references (mardCode for data operations) kept unchanged.

**Risk Analysis**: Medium - displayCode changes affect how color codes are shown to users across multiple views. If currentColorSystem returns unexpected values, fallback to mardCode is built into displayCode(). Adding @EnvironmentObject to ColorAddRow and ManualEntryColorRow could cause crashes if these views are used without InventoryManager in environment. Series grouping by displayCode instead of mardCode may group differently for non-MARD color systems.

**Status**: ✅ Committed to Source of Truth

---

### [Feature] 2026-02-06T02:05:34.824845

**Summary**: Added brand color system (ColorSystem enum) supporting MARD/COCO/漫漫/盼盼/咪小窝/卡卡. New file: ColorSystem.swift. Modified: BeadColor.swift (kakaCode + displayCode/hasCode methods), Brand.swift (colorSystem property), CustomColor.swift (toBeadColor kakaCode), SwiftDataModels.swift (SDBrand colorSystemRaw), InventoryManager.swift (currentColorSystem, searchColors, findColor, addBrand, initializeStockForBrand, saveData), 10+ view files (InventoryView, AddBrandView, BrandSettingsView, HiddenColorsManageView, StatisticsView, AddInventoryView, ShippingView, ScanView, PlannedProjectsView, ColorConverterView), BackupManager.swift (backup/restore colorSystem), project.pbxproj (added ColorSystem.swift)

**Risk Analysis**: Medium - touches many view files and core models; backward compatible via decodeIfPresent defaults with .mard fallback; kakaCode data currently empty (to be filled later); needs testing with existing data migration and new brand creation with non-MARD color systems

**Status**: ✅ Committed to Source of Truth

---

### [Feature] 2026-02-06T17:10:37.738380

**Summary**: 加载卡卡色号映射：BeadColor.swift hasCode排除KK-前缀合成码，InventoryManager.swift新增loadKakaCodeMappings()从colorwithkaka.csv加载150个MARD↔卡卡映射+131个卡卡独有颜色，initializeStockForBrand统一过滤逻辑，project.pbxproj添加CSV资源引用

**Risk Analysis**: Low - 新增功能不影响已有MARD/COCO等品牌数据；KK-前缀排除逻辑确保MARD品牌不受影响；需验证卡卡品牌创建后颜色数量正确

**Status**: ✅ Committed to Source of Truth

---

### [Feature] 2026-02-06T21:28:21.997636

**Summary**: 卡卡模式扫描识别体系支持：(1) InventoryManager.swift - loadKakaCodeMappings() 去除CSV中文后缀(H1透明→H1); 新增 findColor(byCode:preferSystem:) 避免跨品牌色号冲突. (2) AIService.swift - recognizeImage/recognizeWithOpenAI/recognizeWithAnthropic/recognizeWithGemini 增加 colorSystem 参数; 新增 buildPrompts(mode:colorSystem:) 统一提示词生成，卡卡模式使用 B+数字 格式. (3) ScanView.swift - RecognizedItemRowNew 使用 displayCode 显示品牌色号; recognizeImage 传入 colorSystem 并将返回结果转为内部 mardCode; insufficientStockItems/排序 使用 displayCode; 品牌选择器前置到扫描按钮上方

**Risk Analysis**: Medium - AI提示词变更影响所有提供商的识别行为; findColor(byCode:preferSystem:) 改变了色号查找优先级可能影响其他调用点; 需要测试 MARD 品牌下行为不变、卡卡品牌下正确识别和显示

**Status**: ✅ Committed to Source of Truth

---

### [Bugfix] 2026-02-06T21:37:08.538256

**Summary**: InventoryView.swift: 普通网格和普通列表模式的 ColorCardView/ColorRowView 调用缺少 colorSystem 参数，导致卡卡品牌下库存页显示 MARD 色号而非卡卡色号

**Risk Analysis**: Low - 仅补充缺失参数，分组模式已有此参数，逻辑一致

**Status**: ✅ Committed to Source of Truth

---

### [Bugfix] 2026-02-06T21:43:40.923414

**Summary**: colorwithkaka.csv: 修正 H1透明→H1, H2白色→H2, H7黑色→H7，使其能正确映射到卡卡码 B1/B2/B11

**Risk Analysis**: Low - 仅修改 CSV 源数据，代码侧的 ASCII filter 保护仍保留作为兜底

**Status**: ✅ Committed to Source of Truth

---

### [Bugfix] 2026-02-06T21:57:08.287781

**Summary**: 修复两个高风险色号匹配问题：(1) loadKakaCodeMappings() 增加 assignedKakaCodes 去重，当 CSV 中同一卡卡码映射多个 MARD 码时（如 B133→B9/B15, B146→B6/B19, B43→E2/E20），保留首次映射并跳过后续重复，打印警告。(2) findColor(byCode:preferSystem:) 当 preferSystem != .mard 时不再回退到 findColor(byCode:)，避免卡卡的 B3 被错误匹配为 MARD 的 B3 导致跨体系误扣库存

**Risk Analysis**: Low - 去重逻辑仅影响重复卡卡码的后续映射（保留首次映射不变）；移除 MARD 回退后，未匹配的卡卡码会显示为未识别而非静默错扣，更安全

**Status**: ✅ Committed to Source of Truth

---

### [Bugfix] 2026-02-08T02:48:54.705151

**Summary**: InventoryManager.swift: (1) loadData() 新增空数据防护——如果 hasExistingData 标记为 true 但 fetch 全返回空，拒绝标记 isDataLoaded=true 阻止 saveData 覆盖。(2) saveData() catch 中新增 context.rollback() 清除失败后的残留变更。

**Risk Analysis**: Low - 纯防御性改动，不改变正常流程。hasExistingDataKey 首次使用时 UserDefaults 无此 key 默认为 false，不影响新用户。

**Status**: ✅ Committed to Source of Truth

---

### [Feature] 2026-02-08T04:00:19.831180

**Summary**: Consolidated all bead color data into unified allcolors.json (597 colors: 291 MARD + 306 Kaka-only, 0 gray). Removed DefaultBeadColors hardcoded struct (~411 lines), loadKakaCodeMappings(), loadKakaColorHexMap() from InventoryManager.swift. New loadAllColorsFromJSON() loads from single JSON. Replaced kakacolor.json refs with allcolors.json in pbxproj. Deleted superseded kakacolor.json.

**Risk Analysis**: Medium - All color data now loads from a single JSON file instead of hardcoded Swift + CSV at runtime. If allcolors.json is missing or malformed, app will have 0 colors. Verified build succeeds. colorwithkaka.csv still in bundle but unused (harmless).

**Status**: ✅ Committed to Source of Truth

---

### [Feature] 2026-02-08T04:31:53.914151

**Summary**: 统一颜色体系：为 ProjectRecord/SDProjectRecord 添加 colorSystem 字段，ScanView 独立色号体系选择器，PlannedProjectsView 色号体系标签和品牌过滤，SettingsView 默认色号体系设置，blueprint AI prompt 统一，v3 数据迁移，执行扣减防御性校验。涉及文件：BeadColor.swift, SwiftDataModels.swift, ScanView.swift, PlannedProjectsView.swift, SettingsView.swift, AIService.swift, InventoryManager.swift, DataMigration.swift, HistoryRecord.swift, HistoryManager.swift, BackupManager.swift, BrandPicker.swift

**Risk Analysis**: Medium - 影响扫描/计划/执行全链路，SwiftData schema 变更需要验证旧数据迁移，多处 ProjectRecord 创建站点需确认 colorSystem 正确传递

**Status**: ✅ Committed to Source of Truth

---

### [Bugfix] 2026-02-08T04:42:28.690054

**Summary**: 修复两个色系隔离问题：(1) ScanView.swift 色系选择器移除 selectedImage 条件，无图片时也可切换色系用于手动添加 (2) PlannedProjectsView.swift StockCheckSheet/MultiProjectStockCheckSheet/AllBrandsStockCheckCard/ReplenishSuggestionSheet 按项目 colorSystem 过滤品牌，确保库存检查和补豆建议只考虑本色系品牌

**Risk Analysis**: Low - 仅限制品牌显示范围，不影响数据逻辑，已有品牌色系绑定保证正确性

**Status**: ✅ Committed to Source of Truth

---

### [Bugfix] 2026-02-08T04:45:45.254330

**Summary**: Fixed hasExistingDataKey one-way lock bug in InventoryManager.swift: (1) saveData() now syncs hasExistingDataKey to actual data state after successful save, resetting to false when user legitimately empties all data; (2) allEmpty check in loadFromSwiftData() now includes customColors to prevent false positive empty detection

**Risk Analysis**: Low - the SwiftData glitch protection still works correctly: flag only resets after a successful saveData(), which requires isDataLoaded=true. If SwiftData glitches on load, isDataLoaded stays false, saveData is blocked, flag stays true. No regression path.

**Status**: ✅ Committed to Source of Truth

---

### [Feature] 2026-02-08T04:48:10.703100

**Summary**: Added search functionality to PlannedProjectsView (PlannedProjectsView.swift). Added @State searchText, filteredProjects computed property using localizedCaseInsensitiveContains on project name, .searchable modifier with prompt '搜索计划名称'. Select-all in multi-select mode operates on filtered results.

**Risk Analysis**: Low - additive change only, no existing logic modified. searchable is a standard SwiftUI modifier.

**Status**: ✅ Committed to Source of Truth

---

### [Feature] 2026-02-08T04:54:59.686600

**Summary**: UI优化三处: (1) StatisticsView.swift - 默认显示项目记录tab (selectedSegment=1); (2) StatisticsView.swift:442 - ProjectHistoryView多选按钮从'编辑'改为'多选'与PlannedProjectsView一致; (3) MoreView.swift - 新增'数据管理'section整合导出库存/导入历史/恢复备份/导入色号表，设置section描述更新，帮助section增加使用帮助; SettingsView.swift - 移除已迁移到MoreView的数据管理/关于/使用帮助sections及相关state

**Risk Analysis**: Low - 纯UI层变更，无数据逻辑修改。ExportDataSheet和ImportColorSheet定义仍在SettingsView.swift中，只是调用入口移到MoreView

**Status**: ✅ Committed to Source of Truth

---

### [Refactor] 2026-02-08T04:57:44.138593

**Summary**: 删除未实现的ImportColorSheet组件: MoreView.swift移除导入色号表入口按钮及相关state/sheet; SettingsView.swift移除ImportColorSheet struct(其importColors函数体仅为TODO注释)

**Risk Analysis**: Low - 删除的是从未实现的死代码，无功能影响

**Status**: ✅ Committed to Source of Truth

---

### [Feature] 2026-02-08T04:58:56.305866

**Summary**: CustomColorsView.swift 列表顶部添加提示footer; CustomColorEditView.swift 色号输入section添加footer提示: 自定义色号仅在MARD色号体系下生效

**Risk Analysis**: Low - 仅添加UI提示文本，无逻辑变更

**Status**: ✅ Committed to Source of Truth

---

### [Feature] 2026-02-08T05:08:18.581762

**Summary**: 卡卡色系系列索引和颜色过滤修复: (1) ColorSystem.swift 新增 colorSeries/standardPrefixes/defaultSeries 属性 (卡卡=[B,P,R], MARD=[A-ZG]); (2) AddInventoryView.swift 使用动态 colorSeries+defaultSeries，新增非 MARD 色号过滤; (3) ShippingView.swift AddPurchaseRecordView 按所选品牌色系动态显示系列+onChange 切换品牌重置; AddColorToRecordSheet 按记录品牌色系显示+onAppear 设默认系列; (4) ScanView.swift ManualEntrySheetNew 使用 colorSystem.colorSeries/standardPrefixes+onAppear 设默认系列

**Risk Analysis**: Medium - 影响 4 个视图的系列选择器和颜色列表过滤; 品牌切换时清空选择可能影响用户操作流程; 卡卡系列仅 B/P/R 三个，其余颜色归入'其他'或不显示; 需测试 MARD 品牌下行为不变

**Status**: ✅ Committed to Source of Truth

---

### [Bugfix] 2026-02-08T05:11:20.881433

**Summary**: ColorAddRow 色号显示使用硬编码 currentColorSystem 导致购买记录页选择 MARD 品牌时仍显示卡卡色号: AddInventoryView.swift ColorAddRow 新增可选 colorSystem 参数 (默认 nil 回退 currentColorSystem); ShippingView.swift AddPurchaseRecordView 传入 selectedColorSystem 确保按所选品牌色系显示

**Risk Analysis**: Low - ColorAddRow 新增可选参数，不传时行为不变; AddInventoryView 调用站不传此参数保持原有逻辑

**Status**: ✅ Committed to Source of Truth

---

### [Bugfix] 2026-02-08T05:14:19.391343

**Summary**: ScanView.swift 扫描页色系不匹配品牌时可继续扣减的 P0 风险: (1) 新增 brandMatchesScanSystem 计算属性校验品牌色系==扫描色系; (2) 扣减按钮 .disabled(\!brandMatchesScanSystem) 替代原来仅检查 brandId\!=nil; (3) applyToInventory() guard 增加 brandMatchesScanSystem 校验; (4) 提示文案区分'未选品牌'和'色系不匹配'两种情况

**Risk Analysis**: Low - 纯防御性改动，增加约束不影响正常匹配流程; 不匹配时按钮灰色+提示文案，applyToInventory 有双重 guard 保护

**Status**: ✅ Committed to Source of Truth

---

### [Bugfix] 2026-02-08T05:21:46.054506

**Summary**: Fixed PlannedProjectsView search+select interaction in PlannedProjectsView.swift: replaced Button wrappers in select mode with .onTapGesture on entire row to prevent keyboard dismissal from consuming taps; added .scrollDismissesKeyboard(.immediately) to List

**Risk Analysis**: Low - only affects select mode tap handling in planned projects list; non-select mode unchanged; visual behavior identical

**Status**: ✅ Committed to Source of Truth

---

### [Feature] 2026-02-08T05:27:22.611401

**Summary**: PlannedProjectsView.swift: 搜索结果添加复选框支持选择操作。PlannedProjectRow 新增 showSearchCheckbox 参数，搜索时在每行前显示复选框；点击复选框自动进入多选模式；行内容仍保持 NavigationLink 可导航

**Risk Analysis**: Low - 仅在搜索时新增复选框UI，不影响现有多选模式和导航功能；选择逻辑复用现有 selectedProjects 机制

**Status**: ✅ Committed to Source of Truth

---

### [Bugfix] 2026-02-08T05:33:38.377031

**Summary**: 3项修复: 1) PlannedProjectsView.swift - 操作按钮(库存确认/补豆建议/合并)移入List内部随列表滚动; 2) AddBrandView.swift/AddInventoryView.swift - 非MARD体系(如卡卡)隐藏预设颜色包,仅保留全选和自定义; 3) ContentView.swift - 浮动加号按钮仅在库存页(selectedTab==0)显示

**Risk Analysis**: Low - 均为UI层修改,不影响数据逻辑; 品牌创建切换色系时自动重置preset为.all防止无效选择

**Status**: ✅ Committed to Source of Truth

---

### [Bugfix] 2026-02-08T17:40:15.543895

**Summary**: Fixed scan edit showing MARD codes instead of current color system codes in ScanView.swift. Two changes: (1) Line 1237: editCode now uses matchedColor.displayCode(for: colorSystem) instead of raw item.colorCode; (2) Lines 1087-1094: onUpdate callback now converts user-entered color code back to mardCode via findColor(byCode:preferSystem:) for non-MARD systems.

**Risk Analysis**: Low - changes are isolated to the scan result editing flow. Display logic and save logic both properly handle color system conversion now. Pre-existing HistoryManager build errors unrelated.

**Status**: ✅ Committed to Source of Truth

---

### [Bugfix] 2026-02-08T17:42:06.172283

**Summary**: Added @MainActor to canRevert() and revertDisabledReason() in HistoryManager.swift (lines 418, 469) to fix 'main actor-isolated property projects cannot be referenced from nonisolated context' build errors

**Risk Analysis**: Low - these methods are only called from UI context which is already on MainActor

**Status**: ✅ Committed to Source of Truth

---
