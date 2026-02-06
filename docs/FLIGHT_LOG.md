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
