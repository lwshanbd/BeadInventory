# 拼图模式 PR1：基础设施 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为拼图模式（高亮 & 辅助线）功能搭好所有基础设施：引入 OpenCV、配置 Obj-C++ 桥接、建测试 target、定义数据模型与持久化字段、在项目详情页加占位入口。**本 PR 不包含任何识别 / 渲染 / 标定逻辑**，只保证后续 PR 能在不动工程配置的前提下专注写算法和 UI。

**Architecture:** 三件事并行推进：(1) Xcode 工程层引入 OpenCV xcframework + bridging header + 空 tests target；(2) Swift 模型层加 `BeadPatternGrid` Codable struct，挂在 `ProjectRecord`（JSON 字段），SwiftData 侧加 `Data?` 字段；(3) UI 层在 `ProjectDetailView` 加 "拼图模式" 按钮，跳到占位 `PatternCalibrationView`。

**Tech Stack:** Swift 5.9+, SwiftUI, SwiftData, Objective-C++, OpenCV 4.10 via SwiftPM (`yeatse/opencv-spm`)

**Parallelization:** Task 4（BeadPatternGrid 模型）与 Task 1~3（工程配置）逻辑上无依赖，可并行。Task 5、6、7 严格按序。

**前置说明：** Xcode 工程配置（SwiftPM 依赖、bridging header 路径、Build Setting、新 target）必须通过 Xcode GUI 完成，文本编辑 `project.pbxproj` 风险大且容易出错。每个工程配置步骤都给出 Xcode 操作指引 + `xcodebuild` 验证命令。

---

## File Map

| 文件 | 操作 | 职责 |
|------|------|------|
| `BeadInventory.xcodeproj/project.pbxproj` | 修改（Xcode GUI） | 加 SwiftPM `opencv-spm` 依赖、bridging header 设置、新建 `BeadInventoryTests` target |
| `BeadInventory/Managers/CV/GridDetectionBridge.h` | 新建 | Obj-C 公开接口（PR1 只暴露 ping 方法验证桥接通路） |
| `BeadInventory/Managers/CV/GridDetectionBridge.mm` | 新建 | Obj-C++ 实现，include OpenCV 头并调用 `cv::getVersionString` 验证链接 |
| `BeadInventory/BeadInventory-Bridging-Header.h` | 新建 | Swift 引入 Obj-C bridge |
| `BeadInventory/Models/BeadPatternGrid.swift` | 新建 | `BeadPatternGrid` + `GridCorners` Codable struct |
| `BeadInventory/Models/BeadColor.swift` | 修改 | `ProjectRecord` 加 `patternGrid` 字段 + CodingKey + 解码兼容 |
| `BeadInventory/Models/SwiftDataModels.swift` | 修改 | `SDProjectRecord` 加 `patternGridData: Data?` + 互转 |
| `BeadInventory/Views/PatternHighlight/PatternCalibrationView.swift` | 新建 | 占位全屏视图（写 "标定页（PR2 实现）"）+ 关闭按钮 |
| `BeadInventory/Views/ProjectDetailView.swift` | 修改 | 加 "拼图模式" 按钮 + 跳转 sheet |
| `BeadInventoryTests/BeadPatternGridTests.swift` | 新建 | 模型 Codable 单元测试 + OpenCV 链接 smoke test |
| `BeadInventory/Localizable.xcstrings` | 修改 | "拼图模式" / "标定页（PR2 实现）" 文案 |

---

## Build Verification Commands

每一处工程改动都需要这两条之一验证（**先 simulator build，必要时再 test**）：

```bash
# Build only
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run tests target (Task 3 之后)
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

如果用户当前没有 iPhone 16 simulator，使用 `xcrun simctl list devices available` 查一下，把名字替换。

---

## Task 1: 引入 OpenCV SwiftPM 依赖

**Files:**
- Modify (via Xcode GUI): `BeadInventory.xcodeproj`

**目标：** 把 `yeatse/opencv-spm` 加进项目，能 build 通过。**不引用任何 OpenCV 头文件**（那是 Task 2 的事），只验证依赖能解析、能链接。

- [ ] **Step 1: 加 SwiftPM 包**

在 Xcode 打开 `BeadInventory.xcodeproj`：

1. 选中项目根节点 `BeadInventory` → 顶部选 `Package Dependencies` 标签
2. 点左下角 `+`
3. 在搜索框粘贴：`https://github.com/yeatse/opencv-spm`
4. `Dependency Rule` 选 `Up to Next Major Version`，起始版本填 `4.10.0`
5. 点 `Add Package`，等待 SPM 解析（首次需 3~10 分钟下载 xcframework，约 200MB）
6. 弹出 target 选择窗口：仅勾选 `BeadInventory`（main target），点 `Add Package`

- [ ] **Step 2: 验证依赖已加进 General → Frameworks**

在 Xcode 选 `BeadInventory` target → `General` → `Frameworks, Libraries, and Embedded Content` 区。确认能看到 `opencv2`，状态为 `Do Not Embed`（xcframework 自包含，不需 embed）。

- [ ] **Step 3: 验证 build 通过**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -30
```

期望：最后看到 `** BUILD SUCCEEDED **`。如失败，看 log，常见问题：
- SPM 没解析完 → 等
- xcframework 没注册 → 在 Build Phases → Link Binary 手动加 `opencv2.xcframework`

- [ ] **Step 4: Commit**

```bash
git add BeadInventory.xcodeproj
git commit -m "build: 引入 OpenCV 4.10 (yeatse/opencv-spm)"
```

---

## Task 2: 配置 Obj-C++ Bridge 桥接通路

**Files:**
- Create: `BeadInventory/Managers/CV/GridDetectionBridge.h`
- Create: `BeadInventory/Managers/CV/GridDetectionBridge.mm`
- Create: `BeadInventory/BeadInventory-Bridging-Header.h`
- Modify (via Xcode GUI): `BeadInventory.xcodeproj` Build Settings

**目标：** 建一个最小可调的 Obj-C++ bridge，Swift 能调用一个返回 OpenCV 版本字符串的方法。验证整条桥接链路通。

- [ ] **Step 1: 在 Finder 或 shell 创建 CV 目录**

```bash
mkdir -p BeadInventory/Managers/CV
```

- [ ] **Step 2: 创建 GridDetectionBridge.h**

```objc
// BeadInventory/Managers/CV/GridDetectionBridge.h
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Obj-C 桥接入口。PR1 只暴露 ping 方法，验证 OpenCV 链接通路。
/// 真正的检测算法在 PR3 实现。
@interface GridDetectionBridge : NSObject

/// 返回 OpenCV 版本字符串，用于 smoke test。
+ (NSString *)opencvVersion;

@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 3: 创建 GridDetectionBridge.mm**

```objc
// BeadInventory/Managers/CV/GridDetectionBridge.mm
#import "GridDetectionBridge.h"
#import <opencv2/opencv.hpp>

@implementation GridDetectionBridge

+ (NSString *)opencvVersion {
    std::string ver = cv::getVersionString();
    return [NSString stringWithUTF8String:ver.c_str()];
}

@end
```

- [ ] **Step 4: 创建 bridging header**

```objc
// BeadInventory/BeadInventory-Bridging-Header.h
#import "Managers/CV/GridDetectionBridge.h"
```

- [ ] **Step 5: 在 Xcode 把三个文件加进 target**

1. 在 Xcode Project Navigator 中右键 `BeadInventory` 文件夹 → `Add Files to "BeadInventory"...`
2. 选中 `BeadInventory/Managers/CV/` 目录（递归勾选 .h 和 .mm）和 `BeadInventory/BeadInventory-Bridging-Header.h`
3. 确认勾选 `BeadInventory` target
4. 点 `Add`

- [ ] **Step 6: 配置 Build Settings**

选 `BeadInventory` target → `Build Settings`：

1. 搜索 `Objective-C Bridging Header`，把 `Swift Compiler - General > Objective-C Bridging Header` 设为：
   ```
   BeadInventory/BeadInventory-Bridging-Header.h
   ```
2. 搜索 `C++ Language Dialect`，把 `Apple Clang - Language - C++ > C++ Language Dialect` 设为 `GNU++17` 或更高（OpenCV 4.x 要求）
3. 搜索 `C++ and Objective-C Interoperability`，把 `Swift Compiler - Language > C++ and Objective-C Interoperability` 设为 `C++ / Objective-C++`（如果 Swift 5.9+）

- [ ] **Step 7: 验证桥接通路（Swift 侧调用一次）**

临时在 `BeadInventory/BeadInventoryApp.swift` 顶层加一行（仅用于本步验证，下一步删除）：

```swift
// 临时验证桥接
private let _opencvVersionCheck: Void = {
    print("OpenCV linked: \(GridDetectionBridge.opencvVersion())")
}()
```

build + run simulator，期待控制台输出类似：`OpenCV linked: 4.10.0`。验证完即把这段删除。

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10
```

- [ ] **Step 8: 删掉临时验证代码**

从 `BeadInventoryApp.swift` 删除上面那段 `_opencvVersionCheck`。

- [ ] **Step 9: Commit**

```bash
git add BeadInventory/Managers/CV/ BeadInventory/BeadInventory-Bridging-Header.h BeadInventory.xcodeproj
git commit -m "build: 配置 Objective-C++ 桥接与 OpenCV 链接通路"
```

---

## Task 3: 建空 BeadInventoryTests target

**Files:**
- Modify (via Xcode GUI): `BeadInventory.xcodeproj`
- Create: `BeadInventoryTests/BeadInventoryTests.swift`（占位 smoke test）

**目标：** 现在建好 tests target 的壳，让后续每个 task 都能直接写测试。本 task 只放一个永真断言确认 target 跑得起来。

- [ ] **Step 1: 在 Xcode 新建 target**

1. `File` → `New` → `Target...`
2. 选 iOS 平台下的 `Unit Testing Bundle`，点 `Next`
3. Product Name 填 `BeadInventoryTests`
4. Team / Org / Bundle 沿用默认
5. Language: `Swift`，Testing System: `XCTest`
6. Target to be Tested: `BeadInventory`
7. 点 `Finish`

Xcode 会自动生成 `BeadInventoryTests/BeadInventoryTests.swift` 和 `BeadInventoryTests/Info.plist`（或集成在 build settings 里，取决于 Xcode 版本）。

- [ ] **Step 2: 写最小 smoke test**

替换 Xcode 自动生成的 `BeadInventoryTests/BeadInventoryTests.swift` 为：

```swift
import XCTest
@testable import BeadInventory

final class BeadInventoryTests: XCTestCase {
    func testTargetWiredUp() {
        XCTAssertTrue(true, "tests target 已建好，可以加用例")
    }
}
```

- [ ] **Step 3: 跑测试验证 target 通**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 16' test 2>&1 | tail -20
```

期望：看到 `Test Suite 'BeadInventoryTests' passed`，以及 `** TEST SUCCEEDED **`。

- [ ] **Step 4: Commit**

```bash
git add BeadInventoryTests/ BeadInventory.xcodeproj
git commit -m "test: 新建 BeadInventoryTests target（空壳）"
```

---

## Task 4: BeadPatternGrid 模型 + Codable 测试

**Files:**
- Create: `BeadInventory/Models/BeadPatternGrid.swift`
- Create: `BeadInventoryTests/BeadPatternGridTests.swift`

**目标：** 定义网格数据结构，写完整 Codable 单元测试覆盖 encode → decode round trip 和缺字段兼容性。

- [ ] **Step 1: 创建 BeadPatternGrid.swift**

```swift
//
//  BeadPatternGrid.swift
//  BeadInventory
//
//  拼图模式 - 网格数据模型
//

import Foundation
import CoreGraphics

/// 网格 4 个角点，归一化坐标 (0~1)，相对源图片左上角。
/// 支持四边形（梯形）以容忍轻微透视，不强制矩形。
struct GridCorners: Codable, Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomLeft: CGPoint
    var bottomRight: CGPoint
}

/// 拼图模式中一张图纸的完整网格描述。
/// 与 ProjectRecord 一对一，存在 ProjectRecord.patternGrid 字段。
struct BeadPatternGrid: Codable, Equatable {
    /// 4 个归一化角点
    var corners: GridCorners

    /// 行数（横向格子数 = cols；纵向格子数 = rows）
    var rows: Int
    var cols: Int

    /// [row][col] 二维色号矩阵，nil 表示空白格或未匹配
    var cellColorCodes: [[String?]]

    /// 最近一次标定/采样时间
    var lastCalibratedAt: Date

    /// 标定时的图像尺寸（像素）。用于：换图后检测一致性 / 报告 corners 是否仍有效
    var sourceImageSize: CGSize

    /// 关联项目的色号体系（MARD / 卡卡等），与 ProjectRecord.colorSystem 一致
    var colorSystem: ColorSystem
}
```

- [ ] **Step 2: 创建 BeadPatternGridTests.swift**

```swift
import XCTest
@testable import BeadInventory

final class BeadPatternGridTests: XCTestCase {

    private func makeSampleGrid() -> BeadPatternGrid {
        BeadPatternGrid(
            corners: GridCorners(
                topLeft: CGPoint(x: 0.1, y: 0.1),
                topRight: CGPoint(x: 0.9, y: 0.1),
                bottomLeft: CGPoint(x: 0.1, y: 0.9),
                bottomRight: CGPoint(x: 0.9, y: 0.9)
            ),
            rows: 3,
            cols: 3,
            cellColorCodes: [
                ["M24", "M01", nil],
                [nil, "M24", "M01"],
                ["M01", nil, "M24"]
            ],
            lastCalibratedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceImageSize: CGSize(width: 1024, height: 1024),
            colorSystem: .mard
        )
    }

    func testCodableRoundTrip() throws {
        let original = makeSampleGrid()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BeadPatternGrid.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testCellColorCodesPreservesNils() throws {
        let original = makeSampleGrid()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BeadPatternGrid.self, from: encoded)
        // 中间 nil 必须保留，不能被压缩
        XCTAssertNil(decoded.cellColorCodes[0][2])
        XCTAssertEqual(decoded.cellColorCodes[1][1], "M24")
    }

    func testCornersAreNormalizedAndPreserved() throws {
        let original = makeSampleGrid()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BeadPatternGrid.self, from: encoded)
        XCTAssertEqual(decoded.corners.topLeft, CGPoint(x: 0.1, y: 0.1))
        XCTAssertEqual(decoded.corners.bottomRight, CGPoint(x: 0.9, y: 0.9))
    }
}
```

- [ ] **Step 3: 在 Xcode 把两个新文件加进对应 target**

1. 右键 `BeadInventory/Models/` → `Add Files...` → 选 `BeadPatternGrid.swift`，target 勾 `BeadInventory`
2. 右键 `BeadInventoryTests/` → `Add Files...` → 选 `BeadPatternGridTests.swift`，target 勾 `BeadInventoryTests`

- [ ] **Step 4: 跑测试**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test -only-testing:BeadInventoryTests/BeadPatternGridTests 2>&1 | tail -20
```

期望：3 个测试全过。

- [ ] **Step 5: Commit**

```bash
git add BeadInventory/Models/BeadPatternGrid.swift BeadInventoryTests/BeadPatternGridTests.swift BeadInventory.xcodeproj
git commit -m "feat(pattern-highlight): 新增 BeadPatternGrid Codable 模型"
```

---

## Task 5: ProjectRecord 持久化 patternGrid 字段

**Files:**
- Modify: `BeadInventory/Models/BeadColor.swift`
- Modify: `BeadInventoryTests/BeadPatternGridTests.swift`（追加测试）

**目标：** 把 `patternGrid: BeadPatternGrid?` 嵌入 `ProjectRecord` struct，并在自定义 decoder 中向后兼容旧数据（不存在 patternGrid 字段时返回 nil）。

- [ ] **Step 1: 在 ProjectRecord 加字段**

修改 `BeadInventory/Models/BeadColor.swift` 第 107~138 行的 `ProjectRecord` struct：

在 `var colorSystem: ColorSystem` 行（约第 121 行）之后加：

```swift
var patternGrid: BeadPatternGrid?  // 拼图模式网格数据（nil = 未标定）
```

在 `init(..., colorSystem: ColorSystem = .mard)` 参数列表末尾加 `patternGrid: BeadPatternGrid? = nil`，并在函数体内 `self.colorSystem = colorSystem` 之后加：

```swift
self.patternGrid = patternGrid
```

完整改后的 init 签名（参考）：

```swift
init(id: UUID = UUID(),
     name: String,
     date: Date = Date(),
     beadUsage: [BeadUsage] = [],
     brandId: UUID? = nil,
     isArchived: Bool = false,
     parentId: UUID? = nil,
     isPlanned: Bool = false,
     executedDate: Date? = nil,
     thumbnail: Data? = nil,
     finishedImage: Data? = nil,
     completedDate: Date? = nil,
     colorSystem: ColorSystem = .mard,
     patternGrid: BeadPatternGrid? = nil)
```

- [ ] **Step 2: 更新自定义 decoder 向后兼容**

在 `init(from decoder:)` 末尾（`colorSystem = try ...` 之后，第 161 行后）加：

```swift
// 向后兼容：旧数据没有 patternGrid 字段
patternGrid = try container.decodeIfPresent(BeadPatternGrid.self, forKey: .patternGrid)
```

注意：`CodingKeys` 是编译器自动合成的（`ProjectRecord` 未显式定义），所以新字段会自动加入 `CodingKeys`，无需手动改。

- [ ] **Step 3: 在 BeadPatternGridTests.swift 追加 ProjectRecord 兼容测试**

在 `BeadPatternGridTests` class 末尾加：

```swift
// MARK: - ProjectRecord 集成测试

func testProjectRecordEncodesPatternGrid() throws {
    let grid = makeSampleGrid()
    let project = ProjectRecord(
        name: "测试项目",
        beadUsage: [],
        colorSystem: .mard,
        patternGrid: grid
    )

    let data = try JSONEncoder().encode(project)
    let decoded = try JSONDecoder().decode(ProjectRecord.self, from: data)

    XCTAssertEqual(decoded.patternGrid, grid)
}

func testProjectRecordDecodesOldDataWithoutPatternGrid() throws {
    // 模拟旧数据：不含 patternGrid 字段的 JSON
    let json = """
    {
        "id": "\(UUID().uuidString)",
        "name": "旧项目",
        "date": 700000000,
        "beadUsage": [],
        "totalBeads": 0,
        "isArchived": false,
        "isPlanned": false,
        "colorSystem": "mard"
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(ProjectRecord.self, from: json)
    XCTAssertNil(decoded.patternGrid)
}
```

- [ ] **Step 4: 跑测试**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test -only-testing:BeadInventoryTests/BeadPatternGridTests 2>&1 | tail -20
```

期望：5 个测试全过。

- [ ] **Step 5: Commit**

```bash
git add BeadInventory/Models/BeadColor.swift BeadInventoryTests/BeadPatternGridTests.swift
git commit -m "feat(pattern-highlight): ProjectRecord 持久化 patternGrid 字段"
```

---

## Task 6: SDProjectRecord 持久化 patternGridData

**Files:**
- Modify: `BeadInventory/Models/SwiftDataModels.swift`
- Modify: `BeadInventoryTests/BeadPatternGridTests.swift`（追加测试）

**目标：** 在 SwiftData 模型 `SDProjectRecord` 加 `patternGridData: Data?` 字段（JSON 编码后的 `BeadPatternGrid`），并完成与 `ProjectRecord` 的双向转换。

**为什么不直接放 `BeadPatternGrid?`：** SwiftData 对嵌套 Codable struct 的支持历史上不稳定（spec 第 2 节决策）。Data + 手动编解码可控、可测。

- [ ] **Step 1: 加字段**

在 `BeadInventory/Models/SwiftDataModels.swift` 第 88 行 `var colorSystemRaw: String?` 之后加：

```swift
var patternGridData: Data?    // JSON 编码后的 BeadPatternGrid
```

- [ ] **Step 2: 更新 designated init**

修改当前 `SDProjectRecord` 的 init（约第 98~113 行）。在参数列表中、`colorSystemRaw: String? = nil` 之后、`beadUsages: [SDBeadUsage] = []` 之前插入：

```swift
patternGridData: Data? = nil,
```

并在函数体内 `self.colorSystemRaw = colorSystemRaw` 之后、`self.beadUsages = beadUsages` 之前插入：

```swift
self.patternGridData = patternGridData
```

- [ ] **Step 3: 更新 ProjectRecord → SD 转换**

修改 `convenience init(from record: ProjectRecord)`（约第 115~118 行）：

```swift
convenience init(from record: ProjectRecord) {
    let usages = record.beadUsage.map { SDBeadUsage(from: $0) }
    let gridData = record.patternGrid.flatMap { try? JSONEncoder().encode($0) }
    self.init(
        id: record.id,
        name: record.name,
        date: record.date,
        totalBeads: record.totalBeads,
        brandId: record.brandId,
        isArchived: record.isArchived,
        parentId: record.parentId,
        isPlanned: record.isPlanned,
        executedDate: record.executedDate,
        thumbnail: record.thumbnail,
        finishedImage: record.finishedImage,
        completedDate: record.completedDate,
        colorSystemRaw: record.colorSystem.rawValue,
        patternGridData: gridData,
        beadUsages: usages
    )
}
```

注意：`beadUsages` 必须保持在最后一个参数（因为现有 init 是这样排的）。新加的 `patternGridData` 放在 `colorSystemRaw` 后、`beadUsages` 前。同步修改 `init` 参数列表的 `beadUsages` 前一个位置（Step 2 已经在那）。

- [ ] **Step 4: 更新 SD → ProjectRecord 转换**

修改 `func toStruct() -> ProjectRecord`（约第 120~123 行）：

```swift
func toStruct() -> ProjectRecord {
    let usages = (beadUsages ?? []).map { $0.toStruct() }
    let grid = patternGridData.flatMap { try? JSONDecoder().decode(BeadPatternGrid.self, from: $0) }
    return ProjectRecord(
        id: id,
        name: name,
        date: date,
        beadUsage: usages,
        brandId: brandId,
        isArchived: isArchived,
        parentId: parentId,
        isPlanned: isPlannedValue,
        executedDate: executedDate,
        thumbnail: thumbnail,
        finishedImage: finishedImage,
        completedDate: completedDate,
        colorSystem: ColorSystem(rawValue: colorSystemRaw ?? "") ?? .mard,
        patternGrid: grid
    )
}
```

- [ ] **Step 5: 追加单元测试**

在 `BeadPatternGridTests.swift` 末尾加：

```swift
// MARK: - SwiftData 转换测试

func testSDProjectRecordRoundTrip() throws {
    let grid = makeSampleGrid()
    let project = ProjectRecord(
        name: "SD 测试",
        beadUsage: [],
        colorSystem: .mard,
        patternGrid: grid
    )

    let sd = SDProjectRecord(from: project)
    XCTAssertNotNil(sd.patternGridData, "patternGridData 应被编码")

    let restored = sd.toStruct()
    XCTAssertEqual(restored.patternGrid, grid, "round-trip 应保持网格不变")
}

func testSDProjectRecordWithNilPatternGrid() {
    let project = ProjectRecord(name: "无网格项目")
    let sd = SDProjectRecord(from: project)
    XCTAssertNil(sd.patternGridData)
    XCTAssertNil(sd.toStruct().patternGrid)
}
```

- [ ] **Step 6: 跑测试**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test -only-testing:BeadInventoryTests/BeadPatternGridTests 2>&1 | tail -20
```

期望：7 个测试全过。

- [ ] **Step 7: Commit**

```bash
git add BeadInventory/Models/SwiftDataModels.swift BeadInventoryTests/BeadPatternGridTests.swift
git commit -m "feat(pattern-highlight): SDProjectRecord 加 patternGridData 字段"
```

---

## Task 7: PatternCalibrationView 占位 + ProjectDetailView 入口按钮

**Files:**
- Create: `BeadInventory/Views/PatternHighlight/PatternCalibrationView.swift`
- Modify: `BeadInventory/Views/ProjectDetailView.swift`
- Modify: `BeadInventory/Localizable.xcstrings`

**目标：** 用户能在项目详情页看到 "拼图模式" 按钮，点击后跳到一个标着 "PR2 实现中" 的占位全屏 sheet。这是 PR1 的 user-visible 交付物。

- [ ] **Step 1: 创建 PatternHighlight 目录与占位 View**

```bash
mkdir -p BeadInventory/Views/PatternHighlight
```

新建 `BeadInventory/Views/PatternHighlight/PatternCalibrationView.swift`：

```swift
//
//  PatternCalibrationView.swift
//  BeadInventory
//
//  拼图模式 - 网格标定页（PR1 占位，PR2 实现完整 UI）
//

import SwiftUI

struct PatternCalibrationView: View {
    let project: ProjectRecord

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "square.grid.3x3.square")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)

                Text("拼图模式")
                    .font(.title)
                    .bold()

                Text("项目：\(project.name)")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text("网格标定 UI 将在 PR2 实现")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                if project.thumbnail == nil {
                    Text("⚠️ 此项目无图片，无法标定")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Spacer()
            }
            .padding(.top, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("标定网格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    PatternCalibrationView(project: ProjectRecord(name: "示例项目"))
}
```

- [ ] **Step 2: 在 Xcode 把新文件加进 BeadInventory target**

右键 `BeadInventory/Views/` → `Add Files...` → 选 `PatternHighlight` 目录（递归勾选），target 勾 `BeadInventory`。

- [ ] **Step 3: 在 ProjectDetailView 加状态变量与跳转**

修改 `BeadInventory/Views/ProjectDetailView.swift`：

在 `@State private var showingFinishedImageEditor = false`（第 19 行）下方加：

```swift
@State private var showingPatternCalibration = false
```

- [ ] **Step 4: 加 toolbar 按钮**

在 `var body: some View` 内，`.navigationBarTitleDisplayMode(.inline)`（第 170 行）之后、`.sheet(isPresented: $showingThumbnailEditor)` 之前，加：

```swift
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        Button {
            showingPatternCalibration = true
        } label: {
            Label("拼图模式", systemImage: "square.grid.3x3.square")
        }
        .disabled((currentProject ?? project).thumbnail == nil)
    }
}
.sheet(isPresented: $showingPatternCalibration) {
    PatternCalibrationView(project: currentProject ?? project)
}
```

- [ ] **Step 5: 在 Localizable.xcstrings 加文案条目**

Xcode 打开 `BeadInventory/Localizable.xcstrings`，添加 key：

| Key | 中文 (zh-Hans) | 英文 (en) |
|---|---|---|
| `拼图模式` | 拼图模式 | Pattern Mode |
| `标定网格` | 标定网格 | Calibrate Grid |
| `网格标定 UI 将在 PR2 实现` | 网格标定 UI 将在 PR2 实现 | Grid calibration UI ships in PR2 |
| `项目：%@` | 项目：%@ | Project: %@ |
| `⚠️ 此项目无图片，无法标定` | ⚠️ 此项目无图片，无法标定 | ⚠️ This project has no image |

如果项目当前使用 `String(localized:)` 之外的方式（如 NSLocalizedString），按现有惯例处理。本 task 的 SwiftUI 文本字面量会被 Xcode 自动登记到 xcstrings。

- [ ] **Step 6: 跑构建 + 测试**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10

xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 16' test 2>&1 | tail -10
```

期望：build succeeded + 所有 7 个测试通过。

- [ ] **Step 7: 手动验证 UI**

在模拟器或真机运行 App：
1. 进入任意有缩略图的项目详情
2. 右上角看到 `square.grid.3x3.square` 图标按钮
3. 点击 → 弹出占位 sheet，显示 "拼图模式" / 项目名 / "网格标定 UI 将在 PR2 实现"
4. 点 "关闭" → sheet 收起
5. 进入一个无缩略图的项目（或新建一个）→ 按钮置灰不可点

记录验证截图（可选）或在 PR 描述里描述结果。

- [ ] **Step 8: Commit**

```bash
git add BeadInventory/Views/PatternHighlight/ \
        BeadInventory/Views/ProjectDetailView.swift \
        BeadInventory/Localizable.xcstrings \
        BeadInventory.xcodeproj
git commit -m "feat(pattern-highlight): 项目详情页加'拼图模式'入口（占位 UI）"
```

---

## PR1 收尾验证

完成全部 7 个 task 后：

- [ ] **整体构建**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 16' clean build 2>&1 | tail -10
```

期望：`** BUILD SUCCEEDED **`

- [ ] **跑全部测试**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 16' test 2>&1 | tail -20
```

期望：`** TEST SUCCEEDED **`，至少 8 个测试通过（1 smoke + 3 Codable + 2 ProjectRecord + 2 SDProjectRecord）。

- [ ] **App 体积变化记录**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -configuration Release archive -archivePath /tmp/BeadInventory.xcarchive 2>&1 | tail -5

du -sh /tmp/BeadInventory.xcarchive/Products/Applications/BeadInventory.app
```

把数字记入 PR 描述（与 main 分支同条件对比，确认 OpenCV 加入后增量在 50~70MB 范围）。

- [ ] **PR1 验收清单**

- [x] OpenCV 4.10 通过 SwiftPM 集成成功
- [x] Obj-C++ bridge 通路验证：Swift 能调 `GridDetectionBridge.opencvVersion()` 拿到非空字符串
- [x] BeadInventoryTests target 建好并跑通
- [x] `BeadPatternGrid` + `GridCorners` Codable round-trip 测试通过
- [x] `ProjectRecord.patternGrid` 字段加好，旧 JSON 数据可向后兼容
- [x] `SDProjectRecord.patternGridData` 字段加好，双向转换测试通过
- [x] `ProjectDetailView` 显示 "拼图模式" 按钮，无图项目按钮禁用
- [x] 点击按钮弹出占位 `PatternCalibrationView`
- [x] App 体积增量在预期范围（50~70MB）

---

## 下一步

PR1 合并后，开始 PR2 的 plan（标题：**拼图模式 PR2：手动标定 + 高亮主视图**），核心内容：
- `PatternCalibrationView` 完整 UI（拖角、stepper、预览）
- `GridCellSampler` 像素采样 + ΔE 色匹配
- `PatternHighlightView` 主视图（图片 + Canvas 叠层 + 调色板）
- 缩放/平移手势

PR2 的设计在 spec 第 4.2~4.3 节已经定型，落地 plan 待 PR1 完成后写。
