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
