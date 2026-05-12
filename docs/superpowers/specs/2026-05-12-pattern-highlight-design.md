# 拼图模式：高亮与辅助线 — 设计文档

- **日期**: 2026-05-12
- **作者**: lwshanbd + Claude
- **状态**: Draft（待用户 review）
- **代号**: Pattern Highlight Mode（下文简称"拼图模式"）

---

## 1. 背景与目标

BeadInventory 目前支持 AI 识别图例后扣库存、建计划项目。但用户在**实际拼豆过程中**（坐在拼豆板前、看着图纸、一颗一颗拼）缺乏辅助。本设计新增"拼图模式"，让用户在拼某一个色号时，APP 把图纸上**所有该色号的格子高亮显示**，并叠加 5/10 格辅助线，帮助在拼豆板上对位。

### 核心特性

1. **网格识别**：把上传的拼豆图纸解析为 `rows × cols` 的色号矩阵
2. **色号高亮**：选中调色板中的某个色号，图纸上所有匹配格子高亮
3. **辅助线**：每 5 / 10 格叠加一条粗线，与实体拼豆板对齐
4. **交叉校验**：把网格识别出来的色号统计与 AI 图例识别出来的 `beadUsage` 比对，发现差异并允许修正

### 非目标（v1 不做）

- AR / 实时摄像头对位
- 自动检测纸张倾斜并矫正（用户拍照建议先裁切）
- 跨图纸拼接
- 多人协作

---

## 2. 决策汇总（已与用户对齐）

| 决策项 | 选择 | 理由 |
|---|---|---|
| 入口位置 | `ProjectDetailView` 新增"拼图模式"按钮，计划项目和已执行项目都显示 | 入口不重要，跟着项目走最自然 |
| 实现范围 | 一次性把 4 个能力都做完整 | 用户希望"既然要实现就完整实现" |
| Hybrid 内部节奏 | 代码层面分阶段：先手动标定 → 后叠加自动检测 → 最后校验 | 风险隔离，每层可独立调试 |
| 持久化方式 | `BeadPatternGrid` 用 Codable + JSON，放进 `ProjectRecord`；SwiftData 侧只多 `Data?` 字段，不引入新 entity | SwiftData 历史不稳定，避免新增实体 |
| 渲染方式 | SwiftUI `Canvas` 绘制叠层 | 单图 50×50 = 2500 格，View 数量太大 |
| 4 角形状 | 支持四边形（轻微透视），非强制矩形 | 用户拍照常有倾斜 |
| 色匹配 | 复用 `ColorSimilarityService`，转 Lab 空间用 ΔE | 已有基础设施 |

---

## 3. 用户流程

```
[ProjectDetailView]
   └─ 用户点 "拼图模式"
       │
       ├─ 项目已有 patternGrid 缓存？
       │     ├─ 是 → 直接进 PatternHighlightView
       │     └─ 否 → 进 PatternCalibrationView
       │
       ▼
[PatternCalibrationView] 全屏标定
   ├─ 后台异步：GridDetectionService.detect(image)
   ├─ 若 confidence ≥ 0.5 → 预填 4 角 + 行列
   ├─ 否 → 4 角默认放在图片 10%/90%，行列 stepper 初始值 29×29
   ├─ 用户拖角点、调 stepper、可点"重新自动检测"
   ├─ 实时显示叠加的网格预览（透视后均分）
   ├─ 点 "完成"
   │    ├─ GridCellSampler.sample(image, grid) → cellColorCodes
   │    ├─ GridValidator.compare(cellColorCodes, project.beadUsage) → diff
   │    ├─ 保存到 project.patternGrid
   │    └─ 跳转 PatternHighlightView，顶部展示 diff 提示条（若有）
   │
   ▼
[PatternHighlightView] 主拼豆视图
   ├─ 顶部：返回、项目名、辅助线下拉、设置
   ├─ 中间：图片 + Canvas 叠层（高亮 + 辅助线），支持缩放/平移
   ├─ 底部：横向滚动调色板（按用量降序），可多选
   └─ 长按调色板项 → "标记此色全部已拼"（v2）
```

---

## 4. 模块设计

### 4.1 数据模型

新文件 `BeadInventory/Models/BeadPatternGrid.swift`：

```swift
struct BeadPatternGrid: Codable, Equatable {
    var corners: GridCorners
    var rows: Int
    var cols: Int
    var cellColorCodes: [[String?]]    // [row][col] MARD 码，nil = 未匹配/空白
    var lastCalibratedAt: Date
    var sourceImageSize: CGSize        // 标定时的图片尺寸，用于一致性校验
    var colorSystem: ColorSystem       // 与所属项目保持一致
}

struct GridCorners: Codable, Equatable {
    var topLeft: CGPoint        // 全部为归一化坐标 (0~1)，相对图片左上角
    var topRight: CGPoint
    var bottomLeft: CGPoint
    var bottomRight: CGPoint
}
```

修改现有 `ProjectRecord`（[BeadColor.swift:107](BeadInventory/Models/BeadColor.swift:107)）：

```swift
var patternGrid: BeadPatternGrid?   // 新增，nil = 未标定
```

`init(from decoder:)` 中加：
```swift
patternGrid = try container.decodeIfPresent(BeadPatternGrid.self, forKey: .patternGrid)
```

修改 `SDProjectRecord`（[SwiftDataModels.swift:75](BeadInventory/Models/SwiftDataModels.swift:75)）：

```swift
var patternGridData: Data?   // JSON 编码后的 BeadPatternGrid
```

在 `toStruct()` / `init(from:)` 中做 JSON encode/decode 转换。

### 4.2 服务层（Managers）

#### `GridDetectionService.swift` — 自动检测

```swift
struct GridDetectionResult {
    let corners: GridCorners
    let rows: Int
    let cols: Int
    let confidence: Double      // 0~1
}

final class GridDetectionService {
    static let shared = GridDetectionService()
    func detect(image: UIImage) async -> GridDetectionResult?
}
```

内部按置信度阈值 0.5 决定输出 nil。

#### `GridCellSampler.swift` — 像素采样 + 色号匹配

```swift
final class GridCellSampler {
    static let shared = GridCellSampler()
    func sample(image: UIImage,
                grid: BeadPatternGrid,
                availableColors: [BeadColor]) -> [[String?]]
}
```

每格取中心 60% 区域，取**中位数 RGB**（抗噪），转 Lab，调用 `ColorSimilarityService` 找最近的 `BeadColor`。ΔE 阈值（默认 12）以内才匹配，否则返回 nil。

#### `GridValidator.swift` — 交叉校验

```swift
struct GridValidationDiff {
    let code: String
    let gridCount: Int
    let legendCount: Int        // beadUsage 里的数量
}

final class GridValidator {
    static func compare(cellColorCodes: [[String?]],
                        beadUsage: [BeadUsage]) -> [GridValidationDiff]
}
```

输出 `gridCount != legendCount` 的所有色号。空白格（nil）不计入。

### 4.3 视图层（Views）

新目录：`BeadInventory/Views/PatternHighlight/`

#### `PatternCalibrationView.swift`

- 全屏 `ZStack`：底层显示图片（保持原始比例）
- 上层用 `Canvas` 绘制：4 个红色角点圆 + 横纵网格线
- 4 个角点用 `DragGesture` 拖动，dragGesture 用 `.coordinateSpace(.named("calibration"))` 把坐标转换为归一化值
- 底部工具栏：
  - 行数 stepper（带 "-1 / +1" 大按钮，因为最常调整）
  - 列数 stepper
  - "自动检测" 按钮（再次跑 detect）
  - "完成" 主按钮
- 标题栏："标定 拼图模式 网格"

#### `PatternHighlightView.swift`

```
┌─ NavigationStack ─────────────────────┐
│ NavBar: [< 项目] [辅助线 ▾] [⚙]       │
├───────────────────────────────────────┤
│  ZoomablePatternCanvas (大头)         │
│    ├─ 底层 Image（原图）              │
│    ├─ 叠层 Canvas（描边/灰罩/辅助线） │
│    └─ MagnificationGesture + Drag     │
├───────────────────────────────────────┤
│  ValidationBanner（可选，可关）        │
├───────────────────────────────────────┤
│  ColorPaletteBar（横向滚）             │
│    └─ ForEach(beadUsage 降序)         │
└───────────────────────────────────────┘
```

- 高亮策略：选中色号 → 该色格子描 2pt 黄边、其它格子盖 40% 黑色半透明罩
- 多选支持：调色板每个色号是 toggle，可叠多个
- 辅助线菜单：关 / 每 5 格 / 每 10 格
- 辅助线绘制：在透视变换后的网格坐标里，每 5 或 10 列/行画一条 1.5pt 蓝色实线
- 缩放：`MagnificationGesture`，scale 限制 0.5~6
- 平移：仅在 scale > 1 时启用 `DragGesture`，否则吃掉手势避免冲突

#### `PatternHighlightOverlay.swift`（子组件）

纯函数式 Canvas，接收：
- `grid: BeadPatternGrid`
- `highlightedCodes: Set<String>`
- `guideMode: GuideMode` (.off / .five / .ten)
- `imageDisplayRect: CGRect`

在该 rect 内根据透视后的 4 角等分计算每个 cell 的四边形 path 并绘制。

### 4.4 入口接入

`ProjectDetailView.swift` 顶部 actions 区新增：

```swift
Button {
    showPatternHighlight = true
} label: {
    Label("拼图模式", systemImage: "square.grid.3x3.square")
}
.disabled(project.thumbnail == nil)  // 无图无法拼
```

跳转目标按 `project.patternGrid` 是否为 nil 分发。

---

## 5. 网格识别算法详细设计

这是整个功能的技术核心。`GridDetectionService.detect` 内部按顺序尝试三种算法，取置信度最高者。

### 5.1 算法 A：投影直方图法（首选，带网格线图纸）

**适用**：图纸上有清晰的网格线（拼豆图纸 70%+ 都是这种）。

```
输入：UIImage
1. resize 到长边 1024，转 CGImage
2. 转灰度（CIColorMonochrome 或自己实现）
3. 自适应阈值二值化（取 OTSU 阈值），保留深色像素 = 1
4. 计算 colSum[x] = 第 x 列的暗像素数
5. 检测 colSum 上的尖峰（峰高 > 全图均值 * 1.5）
6. 峰间距统计：取众数 T_x ≈ 一格像素宽
7. 用 T_x 做 NMS，得到所有竖线 X 坐标 vlines
8. Y 轴同理 → hlines
9. corners = (vlines.first, hlines.first), (vlines.last, hlines.first), ...
10. cols = vlines.count - 1, rows = hlines.count - 1
11. confidence = min(峰间距方差倒数, 峰强度规则化) → 0~1
```

伪代码：

```swift
let gray = image.toGrayscale1024()
let bin = gray.binarizeOTSU()
let colSum = (0..<bin.width).map { x in bin.darkCount(at: .col(x)) }
let peaks = colSum.findPeaks(minHeight: colSum.mean * 1.5)
let period = peaks.diffs().mode()      // 最常见的相邻差
let vlines = peaks.suppressed(minDist: period * 0.7)
// ...
```

期望准确度：带网格线图纸 > 90%；无网格线图纸 < 30%（会触发算法 B）。

### 5.2 算法 B：色块周期法（无网格线图纸）

**适用**：纯色块直接相邻、看不到分割线。

```
1. resize 到 512，转 RGB
2. OTSU 分割背景（白色）→ 找到内容 bbox
3. 在 bbox 中心采样一条横线，记下每像素的 RGB
4. 对横线 RGB 序列做"颜色变化点检测"：相邻像素 ΔE > 8 标为切换点
5. 切换点间距统计 → 众数 T_x
6. 同样处理纵向中心线 → T_y
7. cols = round(bbox.width / T_x), rows = round(bbox.height / T_y)
8. corners = bbox 4 角
9. confidence = 切换点间距方差的倒数（方差越小越像周期性结构）
```

误差通常 ±1 行/列，靠用户 stepper 微调。

### 5.3 算法 C：Vision 兜底

**适用**：前两种都置信度 < 0.4 时。

```
1. VNDetectContoursRequest 取所有 contour
2. 过滤面积在合理范围（图面积 / 1000 ~ / 100）的小四边形
3. 对中心点做 X、Y 一维聚类
4. 聚类数 ≈ rows / cols；聚类中心点距 ≈ cell size
5. 4 角取所有 contour 的整体 bbox
6. confidence 固定 0.45（始终低于阈值，仅用作"自动预填"提示用户务必检查）
```

### 5.4 透视处理

4 个角可能形成梯形而不是矩形。内部均分时不用简单线性插值，而用**双线性映射**：

```swift
func cellQuad(row: Int, col: Int, corners: GridCorners, rows: Int, cols: Int)
    -> (CGPoint, CGPoint, CGPoint, CGPoint)
{
    func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { ... }
    func bilinear(u: CGFloat, v: CGFloat) -> CGPoint {
        let top = lerp(corners.topLeft, corners.topRight, u)
        let bot = lerp(corners.bottomLeft, corners.bottomRight, u)
        return lerp(top, bot, v)
    }
    let u0 = CGFloat(col)/CGFloat(cols), u1 = CGFloat(col+1)/CGFloat(cols)
    let v0 = CGFloat(row)/CGFloat(rows), v1 = CGFloat(row+1)/CGFloat(rows)
    return (bilinear(u: u0, v: v0), bilinear(u: u1, v: v0),
            bilinear(u: u1, v: v1), bilinear(u: u0, v: v1))
}
```

这个函数被采样、渲染、辅助线计算共用。

### 5.5 失败处理原则

- `confidence < 0.5` → UI 显示橙色提示条："未能可靠识别网格，请手动调整 4 个角和行列数"
- `confidence < 0.7` → UI 显示蓝色提示条："请确认网格对齐"
- `confidence ≥ 0.7` → 不提示

**绝不静默地把低置信度结果当成正确结果**。

---

## 6. 色匹配细节

`GridCellSampler.sample` 内部：

1. 用 5.4 的 bilinear 算出每个 cell 的四边形（4 个角点）
2. 取四边形中心 + 边长 60% 的内部区域
3. 在该区域内均匀采 9×9 = 81 个像素的 RGB
4. 取每通道**中位数**（抗椒盐 + 抗网格线像素污染）
5. 转 sRGB → Lab
6. 与 `availableColors` 中所有色的 Lab 算 ΔE
7. 最小 ΔE < 12 → 匹配；否则 nil

`availableColors` 来自项目的 `colorSystem`（MARD / 卡卡等）。

---

## 7. 校验提示 UI

`PatternHighlightView` 顶部 banner（可关闭）：

```
⚠️ 网格识别与图例有 3 处差异 [详情] [关闭]
```

展开 sheet：

```
M24 白色   网格 87 格   图例 90 格   [以网格为准] [以图例为准]
M01 黑色   网格 124 格  图例 124 格  ✓
H06 蓝色   网格 5 格    图例 8 格    [以网格为准] [以图例为准]
```

"以网格为准" → 更新 `project.beadUsage[code].quantity`，调 `InventoryManager.updatePlannedProjectUsage`（[InventoryManager.swift:2922](BeadInventory/Managers/InventoryManager.swift:2922)）。

---

## 8. 性能考量

- 一张 50×50 图纸 = 2500 格。Canvas 单次绘制 2500 个四边形在 iPhone 12 以上 60fps 无压力，已实测同量级 SwiftUI Canvas。
- 缩放时叠层重绘：Canvas 内部用 `drawingGroup()` 或 `Path.contains` 不必要时跳过，但首版不优化
- 自动检测在 `Task.detached(priority: .userInitiated)` 中跑，标定页打开时立刻启动，不阻塞 UI
- 采样 2500 格 × 81 像素 = 20 万次，CPU 单线程估算 < 200ms，不需要 GCD 分片

---

## 9. 落地节奏（建议 PR 切分）

虽然功能一次性交付，但开发与 review 按四个 PR 推进，每个独立可跑：

1. **PR1 基础设施**：模型 + 持久化字段 + 入口按钮（点击进空白 calibration 页）
2. **PR2 手动标定 + 高亮**：完成 `PatternCalibrationView`（无自动检测）+ `PatternHighlightView` + `GridCellSampler`
3. **PR3 自动检测**：算法 A + B + C + 置信度 banner
4. **PR4 校验**：`GridValidator` + diff sheet + 应用按钮

每个 PR 完成后用户都能用到一部分能力。

---

## 10. 测试策略

- **GridDetectionService**：放 5 张代表性图纸（带线 / 无线 / 倾斜 / 长矩形 / 圆角）到 fixtures，跑自动检测，断言 confidence 与 rows/cols
- **GridCellSampler**：手工标定一张已知答案图，断言 100% 单元匹配
- **GridValidator**：构造已知差异，断言 diff 列表正确
- **UI**：手动测试，因为目前项目无 UI 测试基础设施

iOS 项目目前没有单元测试 target，本设计**包含新建一个 `BeadInventoryTests` target** 用来跑前 3 项。如果用户希望先不引入测试基础设施，PR1 可以省略。

---

## 11. 风险与未决

| 风险 | 缓解 |
|---|---|
| 自动检测失败率高 | 已设计置信度 + 手动兜底；UI 永远不假装识别准了 |
| 用户图纸截图带白边/水印 | 标定时用户能拖角避开白边 |
| 色匹配 ΔE 阈值 12 是否合适 | 可在设置里加调试开关；首版用 12 |
| `Canvas` 在老设备性能 | 优先用 `drawingGroup()`；如不够再降级到只画高亮格 |
| `BeadPatternGrid` JSON 体积（2500 格 × 5 字符 ≈ 15KB） | 可接受，不压缩 |

---

## 12. 验收标准

- [ ] 用户能从 ProjectDetail 进入拼图模式
- [ ] 首次进入显示标定页，自动检测带网格线的图纸成功率 > 80%（用 fixtures 验证）
- [ ] 标定页可拖 4 角、调行列，叠加预览实时更新
- [ ] 完成标定后进入高亮页，调色板按用量降序排
- [ ] 点击调色板色号，对应格子描边高亮，其它格子盖灰罩
- [ ] 多选高亮可叠加
- [ ] 辅助线菜单 关 / 5 / 10 可切换并立即生效
- [ ] 缩放、平移流畅
- [ ] 网格 vs 图例差异展示，可一键修正
- [ ] 标定结果持久化到 ProjectRecord，下次进入不重复标定
- [ ] 删除/重置网格的入口

---

## 附录 A：受影响文件清单（预估）

**新增**：
- `BeadInventory/Models/BeadPatternGrid.swift`
- `BeadInventory/Managers/GridDetectionService.swift`
- `BeadInventory/Managers/GridCellSampler.swift`
- `BeadInventory/Managers/GridValidator.swift`
- `BeadInventory/Views/PatternHighlight/PatternCalibrationView.swift`
- `BeadInventory/Views/PatternHighlight/PatternHighlightView.swift`
- `BeadInventory/Views/PatternHighlight/PatternHighlightOverlay.swift`
- `BeadInventory/Views/PatternHighlight/ColorPaletteBar.swift`
- `BeadInventory/Views/PatternHighlight/ZoomablePatternCanvas.swift`

**修改**：
- `BeadInventory/Models/BeadColor.swift`（`ProjectRecord` 加字段 + 编解码）
- `BeadInventory/Models/SwiftDataModels.swift`（`SDProjectRecord` 加 `Data?` 字段 + 转换）
- `BeadInventory/Views/ProjectDetailView.swift`（入口按钮）
- `BeadInventory/Localizable.xcstrings`（新文案）
