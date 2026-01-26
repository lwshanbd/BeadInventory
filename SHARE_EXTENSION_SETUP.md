# Share Extension 配置指南

本指南帮助你在 Xcode 中配置 Share Extension，实现从其他 App（如照片、文件）分享图片到「啃豆小仓」进行扫描。

## 功能说明

配置完成后：
1. 在照片 App 中选择图片 → 点击分享 → 选择「啃豆小仓」
2. 图片会自动发送到主 App 的扫描界面
3. 可以直接进行 AI 识别

## 配置步骤

### 第一步：添加 Share Extension Target

1. 在 Xcode 中打开项目
2. 点击菜单 **File → New → Target...**
3. 选择 **iOS → Share Extension**
4. 点击 **Next**
5. 配置：
   - **Product Name**: `ShareExtension`
   - **Language**: `Swift`
   - **Embed in Application**: 选择 `BeadInventory`
6. 点击 **Finish**
7. 如果弹出 "Activate scheme" 对话框，点击 **Cancel**（保持使用主 App scheme）

### 第二步：替换生成的文件

Xcode 会自动生成一些模板文件，需要替换为我们准备好的文件：

1. **删除** Xcode 在 `ShareExtension` 目录下自动生成的文件
2. **确保**使用项目中已有的以下文件：
   - `ShareExtension/ShareViewController.swift`
   - `ShareExtension/Info.plist`
   - `ShareExtension/ShareExtension.entitlements`

如果 Xcode 创建了新的 `ShareExtension` 目录，将我们准备的文件移动过去。

### 第三步：配置 App Groups

#### 主 App（BeadInventory）：

1. 在 Xcode 左侧选择项目
2. 选择 **BeadInventory** target
3. 点击 **Signing & Capabilities** 标签
4. 点击 **+ Capability** 按钮
5. 搜索并添加 **App Groups**
6. 点击 App Groups 下的 **+** 按钮
7. 添加：`group.com.beadinventory.shared`

#### Share Extension：

1. 选择 **ShareExtension** target
2. 点击 **Signing & Capabilities** 标签
3. 点击 **+ Capability** 按钮
4. 添加 **App Groups**
5. 勾选相同的 `group.com.beadinventory.shared`

### 第四步：配置主 App 的 URL Scheme

1. 选择 **BeadInventory** target
2. 点击 **Info** 标签
3. 展开 **URL Types**
4. 点击 **+** 添加新的 URL Type：
   - **Identifier**: `com.beadinventory`
   - **URL Schemes**: `beadinventory`
   - **Role**: `Editor`

或者直接在 Build Settings 中设置 Info.plist 文件路径指向 `BeadInventory/Info.plist`。

### 第五步：配置 Entitlements

确保两个 target 都正确配置了 entitlements 文件：

1. **BeadInventory target**:
   - Build Settings → Code Signing Entitlements: `BeadInventory/BeadInventory.entitlements`

2. **ShareExtension target**:
   - Build Settings → Code Signing Entitlements: `ShareExtension/ShareExtension.entitlements`

### 第六步：配置 Share Extension 的 Bundle Identifier

1. 选择 **ShareExtension** target
2. 在 **General** 标签下
3. 确保 **Bundle Identifier** 格式为：`你的主AppID.ShareExtension`
   - 例如：`com.yourname.BeadInventory.ShareExtension`

### 第七步：验证配置

1. 选择主 App scheme：**BeadInventory**
2. Build 项目（Cmd + B）
3. 确保没有编译错误

## 测试

1. 在真机或模拟器上运行 App
2. 打开照片 App
3. 选择一张图片
4. 点击分享按钮
5. 在分享列表中找到「啃豆小仓」
6. 点击后应该看到预览界面
7. 点击「发送到扫描」
8. 主 App 应该自动打开并显示图片在扫描界面

## 常见问题

### Q: 分享列表中看不到「啃豆小仓」？

1. 确保 Share Extension 已正确添加到项目
2. 检查 Info.plist 中的 `NSExtensionActivationSupportsImageWithMaxCount` 是否为 1
3. 重新安装 App 后再试

### Q: 图片传递失败？

1. 确保两个 target 都配置了相同的 App Group
2. 检查 App Group ID 是否一致：`group.com.beadinventory.shared`

### Q: URL Scheme 不工作？

1. 确保主 App 的 Info.plist 已正确配置
2. 检查 URL Scheme 是否为 `beadinventory`

## 文件结构

```
BeadInventory/
├── BeadInventory/
│   ├── BeadInventory.entitlements    # 主 App 的 entitlements
│   ├── Info.plist                     # 主 App 的 Info.plist（URL Scheme）
│   ├── Managers/
│   │   └── SharedImageManager.swift   # 共享图片管理器
│   └── ...
└── ShareExtension/
    ├── ShareViewController.swift      # Extension 视图控制器
    ├── Info.plist                     # Extension 配置
    └── ShareExtension.entitlements    # Extension 的 entitlements
```

## 自定义 App Group ID

如果你需要使用不同的 App Group ID，需要同时修改：

1. `BeadInventory/BeadInventory.entitlements`
2. `ShareExtension/ShareExtension.entitlements`
3. `BeadInventory/Managers/SharedImageManager.swift` 中的 `appGroupIdentifier`
4. `ShareExtension/ShareViewController.swift` 中的 `appGroupIdentifier`
