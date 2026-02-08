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
