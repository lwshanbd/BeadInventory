# BeadInventory 啃豆小仓

一款专为拼豆爱好者设计的 iOS 库存管理应用，帮助你轻松管理各色豆子的库存、AI 识别图纸用量、规划项目、转换不同品牌色号。

## 功能特点

### 库存管理
- 查看所有颜色的库存状态
- 支持多品牌管理（MARD、vivid、漫漫、卡卡等）
- 自定义添加新品牌
- 实时追踪库存数量和使用记录
- 低库存预警提示
- 批量导入库存数据

### AI 图纸识别
- 拍照或从相册选择色号表格图片
- 支持四大 AI 服务商：
  - **Kimi**（月之暗面）- 内置免费额度
  - **OpenAI** - GPT-5 系列模型
  - **Anthropic** - Claude Sonnet 4.5 等模型
  - **Qwen**（通义千问）- qwen-vl 系列模型
- 自动提取色号和对应数量
- 图片预处理减少水印干扰
- 可手动编辑识别结果
- 支持扣减库存或添加到计划项目

### 计划项目
- 将识别结果保存为计划项目
- 项目合并与归档管理
- 查看项目所需材料清单
- 一键从库存扣减

### 历史记录
- 完整的操作历史追踪
- 支持撤销操作（Undo）
- 查看每次操作的详细信息

### 色号转换
- 输入任意品牌色号快速查询
- 自动显示对应的其他品牌色号
- 支持多品牌对照
- 一键复制色号

### 统计分析
- 整体库存使用情况概览
- 颜色使用量排行榜
- 项目历史记录
- 低库存颜色汇总

## 系统要求

- iOS 17.0+
- Xcode 15.0+

## 安装

1. 克隆仓库
```bash
git clone https://github.com/lwshanbd/BeadInventory.git
```

2. 打开项目
```bash
cd BeadInventory
open BeadInventory.xcodeproj
```

3. 在 Xcode 中选择目标设备，点击运行

## 配置 AI 识别

应用支持四种 AI 服务商：

### Kimi（推荐新手）
1. 前往 [Moonshot AI](https://platform.moonshot.cn/) 获取 API Key
2. 在应用「更多」→「设置」→「AI 图像识别」中选择 Kimi
3. 填入 API Key
4. Kimi 提供免费额度，适合新手试用

### OpenAI
1. 前往 [OpenAI Platform](https://platform.openai.com/) 获取 API Key
2. 在应用设置中选择 OpenAI
3. 填入 API Key
4. 可选：填写自定义 API 地址（用于代理）

### Anthropic (Claude)
1. 前往 [Anthropic Console](https://console.anthropic.com/) 获取 API Key
2. 在应用设置中选择 Anthropic
3. 填入 API Key
4. 推荐使用 Claude Sonnet 4.5 模型

### Qwen（通义千问）
1. 前往 [阿里云 DashScope](https://dashscope.console.aliyun.com/) 获取 API Key
2. 在应用设置中选择 Qwen
3. 填入 API Key
4. 推荐使用 qwen-vl-max 模型

## 项目结构

```
BeadInventory/
├── BeadInventoryApp.swift       # 应用入口
├── ContentView.swift            # 主界面 TabView
├── color.json                   # MARD 色号数据
├── convert.csv                  # 跨品牌色号转换表
├── Models/
│   └── BeadColor.swift          # 数据模型（结构体 + SwiftData）
├── Managers/
│   ├── InventoryManager.swift   # 库存状态管理
│   ├── AIService.swift          # AI 识别服务（多服务商）
│   ├── HistoryManager.swift     # 历史记录与撤销
│   ├── CSVImporter.swift        # CSV 导入工具
│   └── DataMigration.swift      # 数据迁移工具
└── Views/
    ├── InventoryView.swift      # 库存页面
    ├── ScanView.swift           # 扫描识别页面
    ├── PlannedProjectsView.swift # 计划项目页面
    ├── StatisticsView.swift     # 统计页面
    ├── MoreView.swift           # 更多功能入口
    ├── HistoryView.swift        # 历史记录页面
    ├── ColorConverterView.swift # 色号转换页面
    ├── SettingsView.swift       # 设置页面
    ├── BrandSettingsView.swift  # 品牌管理页面
    ├── AddInventoryView.swift   # 添加库存页面
    ├── ImportStockView.swift    # 导入库存页面
    └── AboutView.swift          # 关于页面
```

## 使用技巧

- 首次使用建议先在「品牌管理」中添加你使用的品牌
- 可通过「导入库存」批量导入初始库存数据
- 识别有水印图片时，应用会自动进行预处理
- 低库存颜色会以红色标识
- 所有操作都会记录在历史中，可随时撤销

## 技术栈

- **SwiftUI** - 声明式 UI 框架
- **SwiftData** - 数据持久化
- **Async/Await** - 现代异步编程

## 声明

**支持原创，尊重版权** - 拼豆图纸凝聚创作者心血，请尊重原作者劳动成果。

## License

MIT License
