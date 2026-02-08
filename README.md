# BeadInventory 啃豆小仓

一款面向拼豆爱好者的 iOS 库存与项目管理应用，聚焦「库存管理 + AI 识别图纸 + 项目执行 + 色号转换 + 数据备份恢复」。

## 功能总览

### 1. 库存管理（Inventory）
- 多品牌库存管理，品牌可新增、编辑、删除、合并
- 每个品牌独立库存与低库存阈值
- 支持列表/网格两种视图，支持排序、分组、搜索
- 支持隐藏色号与批量恢复
- 支持自定义色号（`#` 前缀），可编辑颜色与名称
- 支持快速增库、库存编辑、库存重置、使用记录清除

### 2. AI 图纸识别（Scan）
- 支持拍照、相册导入、Share Extension 分享导入
- 支持两种识别模式：
  - 表格识别
  - 色号统计识别（图纸统计）
- 内置图像预处理（对比度增强、锐化、高光压制）以降低水印干扰
- 识别结果可手动增删改
- 识别后可直接：
  - 创建计划项目
  - 扣减库存（按品牌与色号体系匹配）

支持的 AI Provider（当前代码）：
- Kimi
- OpenAI
- Anthropic
- Qwen
- Gemini

### 3. 计划项目（Planned Projects）
- 从扫描结果一键创建计划
- 计划可执行为已完成项目（自动扣减库存）
- 支持项目复制、编辑、删除、归档
- 支持多选批量操作：库存确认、补豆建议、合并计划
- 支持父子项目结构、项目缩略图与成品图

### 4. 统计与历史
- 使用统计：总库存/已用/剩余、低库存筛选、使用排行
- 项目记录：计划/执行历史管理
- 操作历史：记录关键操作并支持撤回（Undo）
- 成品日历：按完成日期查看成品图

### 5. 更多工具
- 色号转换：支持多品牌色号互查
- 运输中：管理待到货购买记录，支持粘贴补豆 CSV
- 数据导出：导出 CSV / JSON
- 历史数据导入：从导出文件恢复品牌、库存、项目
- 自动备份：每周首次打开自动备份，最多保留 8 份，可视化恢复

## 色号体系说明

- 色号转换查询支持：`MARD / COCO / 漫漫 / 盼盼 / 咪小窝 / 卡卡`
- 当前品牌创建页支持选择的品牌色号体系：`MARD`、`卡卡`

## 技术栈

- SwiftUI
- SwiftData（含版本化 Schema）
- Async/Await
- Share Extension（图片分享到扫描页）

## 项目结构

```text
BeadInventory/
├── BeadInventory/                 # 主 App（SwiftUI + SwiftData）
│   ├── Managers/                  # 业务逻辑（库存/AI/历史/备份等）
│   ├── Models/                    # 领域模型 + SwiftData 模型
│   ├── Views/                     # 各功能页面
│   ├── Assets.xcassets/           # 图标与资源
│   ├── zh-Hans.lproj/             # 简体中文资源
│   └── en.lproj/                  # 英文资源
├── ShareExtension/                # 分享扩展（图片导入扫描）
├── BeadInventory.xcodeproj/       # Xcode 工程
├── ci_scripts/                    # Xcode Cloud 构建脚本
├── SHARE_EXTENSION_SETUP.md       # Share Extension 配置文档
└── README.md
```

## 环境要求

- iOS 17.0+
- Xcode 15.0+
- macOS（用于本地编译）

## 快速开始

```bash
git clone git@github.com:lwshanbd/BeadInventory.git
cd BeadInventory
open BeadInventory.xcodeproj
```

## 命令行构建

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 16' build
```

> 如果需要单独构建分享扩展，可使用 `ShareExtension` scheme。

## 测试

当前仓库尚未提交测试 Target；如后续补齐，可使用：

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## AI 配置说明

在 App 中进入：`更多 -> 设置 -> AI 图像识别`

配置项：
- AI 提供商
- API Key
- API 地址（可选，自定义代理/网关）
- 模型

各 Provider 官方入口：
- Kimi: https://platform.moonshot.cn/
- OpenAI: https://platform.openai.com/
- Anthropic: https://console.anthropic.com/
- Qwen: https://bailian.console.aliyun.com/
- Gemini: https://aistudio.google.com/

## Share Extension

项目已包含 `ShareExtension` target 代码，可将其他 App 中的图片分享到「啃豆小仓」扫描页。

完整配置见：`SHARE_EXTENSION_SETUP.md`

关键配置点：
- App Group（主 App 与 Share Extension 一致）
- URL Scheme（`beadinventory://scan`）
- 两个 target 的 entitlements 配置

## 数据导入 / 导出 / 备份

- 导入库存：支持 CSV（自动识别常见色号/数量列名）
- 导出数据：支持 CSV / JSON
- 导入历史数据：支持从导出文件恢复品牌、库存、项目
- 自动备份：每周自动备份一次，可在「恢复备份」中回滚

## 安全说明

- 不要在仓库中提交 API Key（OpenAI / Anthropic / Kimi / Qwen / Gemini）
- 建议仅在本地设置页配置密钥，或在 CI 中通过密钥管理注入

## 声明

支持原创，拒绝抄袭。请尊重每一份拼豆图纸创作者的劳动成果。

## 支持作者

如果这个应用对你有帮助，欢迎支持：

<img src="wxpay.jpg" width="200" alt="微信赞赏码">

## License

GPL-3.0 License
