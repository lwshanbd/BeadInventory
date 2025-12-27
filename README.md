# BeadInventory

一款专为拼豆爱好者设计的 iOS 库存管理应用，帮助你轻松管理各色豆子的库存、识别图纸用量、转换不同品牌色号。

## 功能特点

### 库存管理
- 查看所有颜色的库存状态
- 支持按品牌色号（MARD、vivid、漫漫、卡卡）显示和搜索
- 实时追踪库存数量和使用记录
- 低库存预警提示

### AI 图纸识别
- 拍照或从相册选择色号表格图片
- 支持 OpenAI GPT-4o 和 Anthropic Claude 进行智能识别
- 自动提取 MARD 色号和对应数量
- 图片预处理减少水印干扰
- 可手动编辑识别结果
- 确认后自动从库存扣减

### 色号转换
- 输入任意品牌色号快速查询
- 自动显示对应的其他品牌色号
- 支持 MARD、vivid、漫漫、卡卡四大品牌
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

应用支持两种 AI 服务商：

### OpenAI
1. 前往 [OpenAI Platform](https://platform.openai.com/) 获取 API Key
2. 在应用「设置」→「AI 图像识别」中选择 OpenAI
3. 填入 API Key
4. 可选：填写自定义 API 地址（用于代理）

### Anthropic (Claude)
1. 前往 [Anthropic Console](https://console.anthropic.com/) 获取 API Key
2. 在应用「设置」→「AI 图像识别」中选择 Anthropic
3. 填入 API Key
4. 推荐使用 Claude Sonnet 4.5 模型

## 项目结构

```
BeadInventory/
├── BeadInventoryApp.swift      # 应用入口
├── ContentView.swift           # 主界面 TabView
├── Models/
│   └── BeadColor.swift         # 数据模型
├── Managers/
│   ├── InventoryManager.swift  # 库存管理
│   ├── AIService.swift         # AI 识别服务
│   └── OCRManager.swift        # OCR 管理（备用）
└── Views/
    ├── InventoryView.swift     # 库存页面
    ├── ScanView.swift          # 扫描识别页面
    ├── ColorConverterView.swift # 色号转换页面
    ├── StatisticsView.swift    # 统计页面
    ├── SettingsView.swift      # 设置页面
    └── AppIconView.swift       # 图标设计
```

## 使用技巧

- 建议初始库存设为 1000 颗/色
- 识别有水印图片时，应用会自动进行预处理
- 定期导出数据做备份
- 低库存颜色会以红色标识

## License

MIT License
