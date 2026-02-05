# Flight Log - AI Change Records

> This file is automatically maintained by Claude Code's Flight Recording system.
> It serves as the single source of truth for AI-assisted code changes.

---


### [Bugfix] 2026-02-05T00:34:16.136412

**Summary**: 移除 deleteProject 中的 restoreStockFromProject 调用 (InventoryManager.swift:1133-1154)，删除项目不再恢复库存

**Risk Analysis**: Low - 简化了删除逻辑，修复了撤销操作导致库存重复增加的 bug

**Status**: ✅ Committed to Source of Truth

---
