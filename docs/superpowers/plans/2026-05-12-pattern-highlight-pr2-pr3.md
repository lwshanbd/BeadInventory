# 拼图模式 PR2 + PR3：核心功能 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 PR1 搭好的地基变成用户可用的功能：进入拼图模式 → 标定网格 → 选色号看到对应格子高亮 → 切换 5/10 格辅助线 → 自动检测网格 → 网格与图例交叉校验。本 plan 合并了原 PR2 (手动标定 + 高亮) 和 PR3 (自动检测 + 校验)。

**Architecture:**
- **Service 层（纯 Swift / 借 OpenCV）**: `GridDetectionService` (OpenCV-backed) + `GridCellSampler` (像素采样 + 色匹配) + `GridValidator` (差异比对)
- **View 层（SwiftUI）**: `PatternCalibrationView` (标定) + `PatternHighlightView` (主视图) + `PatternHighlightOverlay` (Canvas 叠层) + `ColorPaletteBar` (调色板) + `ZoomablePatternCanvas` (缩放容器)
- **Bridge 扩展**: `GridDetectionBridge.h/.m` 增加 `detectGridWithHoughLines:` 和 `detectGridWithContours:` 两个 Obj-C class method，内部调 OpenCV Imgproc

**Tech Stack:** Swift 5.9+, SwiftUI Canvas + MagnificationGesture, OpenCV via Obj-C bridge, Accelerate.framework (for algorithm B)

**Parallelization:** Task 1 (Sampler) 与 Task 2 (Bridge 扩展) 互不依赖，可并行。其余任务有依赖链。

**Prerequisites already done in PR1:**
- OpenCV (`yeatse/opencv-spm`) 已经链入 BeadInventory target
- Obj-C bridge `GridDetectionBridge` 已经能从 Swift 调用
- `BeadPatternGrid` + `GridCorners` 模型 + ProjectRecord/SDProjectRecord 持久化
- BeadInventoryTests target 可用，8 个测试通过
- 入口按钮已在 ProjectDetailView (计划项目) 出现，sheet 跳到 `PatternCalibrationView` 占位

---

## File Map

| 文件 | 操作 | 职责 |
|------|------|------|
| `Managers/GridCellSampler.swift` | 新建 | 给定 grid + UIImage → [row][col] String? 色号矩阵 |
| `Managers/GridDetectionService.swift` | 新建 | Swift 入口，按算法置信度选最优结果 |
| `Managers/GridValidator.swift` | 新建 | 比较 cellColorCodes vs beadUsage → diff |
| `Models/GridGeometry.swift` | 新建 | bilinear 透视映射工具函数（4 角 + 行列 → 每格 4 顶点） |
| `Managers/CV/GridDetectionBridge.h/.m` | 修改 | 新增 detectGridWithHoughLines/detectGridWithContours |
| `Views/PatternHighlight/PatternCalibrationView.swift` | 修改 | 占位换为真实标定 UI |
| `Views/PatternHighlight/PatternHighlightView.swift` | 新建 | 主视图 |
| `Views/PatternHighlight/PatternHighlightOverlay.swift` | 新建 | Canvas 叠层（高亮 + 辅助线） |
| `Views/PatternHighlight/ColorPaletteBar.swift` | 新建 | 底部调色板 |
| `Views/PatternHighlight/ZoomablePatternCanvas.swift` | 新建 | 缩放/平移容器 |
| `Views/PatternHighlight/ValidationDiffSheet.swift` | 新建 | 差异展示 + 修正按钮 |
| `Managers/InventoryManager.swift` | 修改 | 新增 `updateProjectPatternGrid(id:grid:)` 方法 |
| `BeadInventoryTests/GridGeometryTests.swift` | 新建 | bilinear 单元测试 |
| `BeadInventoryTests/GridValidatorTests.swift` | 新建 | 差异计算单元测试 |

---

## Build & Test Verification

```bash
# build
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -10

# all tests
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | \
  grep -E "Test Suite|TEST" | tail -10
```

After each task, both should succeed. Tests build on PR1's 8 passing tests.

---

## Task 1: GridGeometry — 透视映射工具

**Files:**
- Create: `BeadInventory/Models/GridGeometry.swift`
- Create: `BeadInventoryTests/GridGeometryTests.swift`

**Why first:** Every other component (sampler, overlay, palette positioning, calibration preview) needs this. Pure math, fully testable, no OpenCV.

- [ ] **Step 1: 创建 GridGeometry.swift**

```swift
//
//  GridGeometry.swift
//  BeadInventory
//
//  拼图模式 - 网格几何工具：4 角四边形 + 行列数 → 每格 4 顶点（bilinear）
//

import Foundation
import CoreGraphics

enum GridGeometry {
    /// 给定 4 角和 (rows, cols) 行列数，计算单元格 (row, col) 的 4 个顶点。
    /// 4 个角点构成任意四边形（允许梯形/轻微透视），不要求矩形。
    /// 返回顺序：topLeft, topRight, bottomRight, bottomLeft（CCW from TL）。
    static func cellQuad(row: Int, col: Int,
                         rows: Int, cols: Int,
                         corners: GridCorners,
                         in displayRect: CGRect) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let u0 = CGFloat(col) / CGFloat(cols)
        let u1 = CGFloat(col + 1) / CGFloat(cols)
        let v0 = CGFloat(row) / CGFloat(rows)
        let v1 = CGFloat(row + 1) / CGFloat(rows)

        let tl = bilinear(u: u0, v: v0, corners: corners, in: displayRect)
        let tr = bilinear(u: u1, v: v0, corners: corners, in: displayRect)
        let br = bilinear(u: u1, v: v1, corners: corners, in: displayRect)
        let bl = bilinear(u: u0, v: v1, corners: corners, in: displayRect)

        return (tl, tr, br, bl)
    }

    /// 给定归一化 (u, v) 和 4 角四边形，返回在 displayRect 内的实际坐标。
    /// (u, v) ∈ [0, 1]，(0, 0) = topLeft, (1, 1) = bottomRight
    static func bilinear(u: CGFloat, v: CGFloat,
                         corners: GridCorners,
                         in displayRect: CGRect) -> CGPoint {
        // corners 是归一化坐标，先转为 displayRect 内的绝对坐标
        let tl = denormalize(corners.topLeft, in: displayRect)
        let tr = denormalize(corners.topRight, in: displayRect)
        let bl = denormalize(corners.bottomLeft, in: displayRect)
        let br = denormalize(corners.bottomRight, in: displayRect)

        let top = lerp(tl, tr, u)
        let bottom = lerp(bl, br, u)
        return lerp(top, bottom, v)
    }

    /// 将归一化坐标 (0~1) 转为 displayRect 内绝对坐标。
    static func denormalize(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width,
                y: rect.minY + p.y * rect.height)
    }

    /// 将 displayRect 内绝对坐标转为归一化坐标 (0~1)。
    static func normalize(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: (p.x - rect.minX) / max(rect.width, 1),
                y: (p.y - rect.minY) / max(rect.height, 1))
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t,
                y: a.y + (b.y - a.y) * t)
    }
}
```

- [ ] **Step 2: pbxproj 接入** (按 PR1 Task 4 同样的 4-处编辑方式，IDs 用 `385001012FB3A70D00F5DDE2` 文件 ref / `385001022FB3A70D00F5DDE2` build file ref)

- [ ] **Step 3: 创建 GridGeometryTests.swift**

```swift
import XCTest
@testable import BeadInventory

final class GridGeometryTests: XCTestCase {
    private let displayRect = CGRect(x: 0, y: 0, width: 100, height: 100)

    private func rectCorners() -> GridCorners {
        GridCorners(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 1, y: 0),
            bottomLeft: CGPoint(x: 0, y: 1),
            bottomRight: CGPoint(x: 1, y: 1)
        )
    }

    func testBilinearAtCorners() {
        let c = rectCorners()
        XCTAssertEqual(GridGeometry.bilinear(u: 0, v: 0, corners: c, in: displayRect),
                       CGPoint(x: 0, y: 0))
        XCTAssertEqual(GridGeometry.bilinear(u: 1, v: 0, corners: c, in: displayRect),
                       CGPoint(x: 100, y: 0))
        XCTAssertEqual(GridGeometry.bilinear(u: 1, v: 1, corners: c, in: displayRect),
                       CGPoint(x: 100, y: 100))
        XCTAssertEqual(GridGeometry.bilinear(u: 0.5, v: 0.5, corners: c, in: displayRect),
                       CGPoint(x: 50, y: 50))
    }

    func testCellQuadUniformGrid() {
        let c = rectCorners()
        // 10x10 grid，cell (0,0) 应是 [0,0]-[10,10]
        let (tl, tr, br, bl) = GridGeometry.cellQuad(row: 0, col: 0, rows: 10, cols: 10,
                                                     corners: c, in: displayRect)
        XCTAssertEqual(tl, CGPoint(x: 0, y: 0))
        XCTAssertEqual(tr, CGPoint(x: 10, y: 0))
        XCTAssertEqual(br, CGPoint(x: 10, y: 10))
        XCTAssertEqual(bl, CGPoint(x: 0, y: 10))
    }

    func testCellQuadCenterCell() {
        let c = rectCorners()
        // 10x10 grid，cell (5, 5) 应是 [50,50]-[60,60]
        let (tl, _, br, _) = GridGeometry.cellQuad(row: 5, col: 5, rows: 10, cols: 10,
                                                   corners: c, in: displayRect)
        XCTAssertEqual(tl, CGPoint(x: 50, y: 50))
        XCTAssertEqual(br, CGPoint(x: 60, y: 60))
    }

    func testNormalizeAndDenormalizeRoundTrip() {
        let p = CGPoint(x: 25, y: 75)
        let normalized = GridGeometry.normalize(p, in: displayRect)
        XCTAssertEqual(normalized.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(normalized.y, 0.75, accuracy: 0.001)
        let denorm = GridGeometry.denormalize(normalized, in: displayRect)
        XCTAssertEqual(denorm.x, p.x, accuracy: 0.001)
        XCTAssertEqual(denorm.y, p.y, accuracy: 0.001)
    }

    func testBilinearTrapezoid() {
        // 顶部窄、底部宽的梯形
        let c = GridCorners(
            topLeft: CGPoint(x: 0.25, y: 0),
            topRight: CGPoint(x: 0.75, y: 0),
            bottomLeft: CGPoint(x: 0, y: 1),
            bottomRight: CGPoint(x: 1, y: 1)
        )
        // 中心点应在 (50, 50) 左右
        let center = GridGeometry.bilinear(u: 0.5, v: 0.5, corners: c, in: displayRect)
        XCTAssertEqual(center.x, 50, accuracy: 0.001)
        XCTAssertEqual(center.y, 50, accuracy: 0.001)
    }
}
```

- [ ] **Step 4: 跑测试**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:BeadInventoryTests/GridGeometryTests 2>&1 | tail -15
```

期望 5 测试通过。

- [ ] **Step 5: Commit**

```
feat(pattern-highlight): GridGeometry 透视映射工具 + 5 测试
```

---

## Task 2: GridDetectionBridge 扩展 — OpenCV 算法封装

**Files:**
- Modify: `BeadInventory/Managers/CV/GridDetectionBridge.h`
- Modify: `BeadInventory/Managers/CV/GridDetectionBridge.m`

**Why now:** Service 层 (Task 4) 需要这个。Obj-C 层先做好，Swift 调用方就稳定。

OpenCV 算法在 Obj-C API 下的形态：`Imgproc.HoughLinesP(image:lines:rho:theta:threshold:minLineLength:maxLineGap:)`，类方法，返回值通过输出 Mat 参数获取。

- [ ] **Step 1: 修改 .h 添加新接口**

替换 `GridDetectionBridge.h` 整个 `@interface` 块为：

```objc
//
//  GridDetectionBridge.h
//  BeadInventory
//
//  拼图模式 - OpenCV 桥接入口
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 网格检测结果。失败时所有 corner 字段为 0、confidence 为 0。
@interface GridDetectionResultBridge : NSObject
@property (nonatomic, assign) CGPoint topLeft;       // 归一化坐标 0~1
@property (nonatomic, assign) CGPoint topRight;
@property (nonatomic, assign) CGPoint bottomLeft;
@property (nonatomic, assign) CGPoint bottomRight;
@property (nonatomic, assign) NSInteger rows;
@property (nonatomic, assign) NSInteger cols;
@property (nonatomic, assign) double confidence;     // 0~1
@end

/// 拼图网格检测 - OpenCV 包装层。Swift 通过 bridging header 调用。
@interface GridDetectionBridge : NSObject

/// 返回 OpenCV 版本字符串（smoke test 用）。
+ (NSString *)opencvVersion;

/// 算法 A：HoughLinesP 检测带网格线图纸。
/// 失败/置信度低时返回 nil。
+ (nullable GridDetectionResultBridge *)detectGridWithHoughLines:(UIImage *)image;

/// 算法 C：findContours 检测无网格线图纸（兜底）。
/// confidence 固定较低（≤0.45），仅作预填。
+ (nullable GridDetectionResultBridge *)detectGridWithContours:(UIImage *)image;

@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 2: 修改 .m 实现**

替换 `GridDetectionBridge.m` 整个文件为：

```objc
//
//  GridDetectionBridge.m
//  BeadInventory
//
//  OpenCV 算法的 Obj-C 包装。Swift 侧用 GridDetectionService 调用。
//

#import "GridDetectionBridge.h"
#import <opencv2/opencv2.h>

@implementation GridDetectionResultBridge
@end

@implementation GridDetectionBridge

+ (NSString *)opencvVersion {
    return [Core getVersionString];
}

+ (nullable GridDetectionResultBridge *)detectGridWithHoughLines:(UIImage *)image {
    if (image == nil) return nil;

    // 1. 转 Mat
    Mat *src = [[Mat alloc] initWithUIImage:image];
    if (src.empty) return nil;

    // 2. 缩放到长边 1024
    CGFloat scale = 1024.0 / MAX(image.size.width, image.size.height);
    Mat *resized = [Mat new];
    Size2i *targetSize = [[Size2i alloc] initWithWidth:(int)(image.size.width * scale)
                                                height:(int)(image.size.height * scale)];
    [Imgproc resize:src dst:resized dsize:targetSize fx:0 fy:0 interpolation:InterpolationFlagsInterArea];

    // 3. 灰度
    Mat *gray = [Mat new];
    [Imgproc cvtColor:resized dst:gray code:ColorConversionCodeBGR2GRAY];

    // 4. 高斯模糊（去噪）
    Mat *blurred = [Mat new];
    Size2i *ksize = [[Size2i alloc] initWithWidth:3 height:3];
    [Imgproc GaussianBlur:gray dst:blurred ksize:ksize sigmaX:0];

    // 5. Canny 边缘
    Mat *edges = [Mat new];
    [Imgproc Canny:blurred edges:edges threshold1:50 threshold2:150];

    // 6. HoughLinesP
    Mat *lines = [Mat new];
    double minLineLength = MIN(resized.cols, resized.rows) * 0.3;
    [Imgproc HoughLinesP:edges lines:lines
                     rho:1
                   theta:M_PI / 180
               threshold:80
           minLineLength:minLineLength
              maxLineGap:10];

    if (lines.rows == 0) return nil;

    // 7. 分离水平 / 垂直线 + 聚类找间距
    NSMutableArray<NSNumber *> *hCenters = [NSMutableArray array];  // 水平线的 y 中心
    NSMutableArray<NSNumber *> *vCenters = [NSMutableArray array];  // 垂直线的 x 中心

    for (int i = 0; i < lines.rows; i++) {
        NSArray<NSNumber *> *vals = [lines get:i col:0];
        if (vals.count < 4) continue;
        int x1 = vals[0].intValue;
        int y1 = vals[1].intValue;
        int x2 = vals[2].intValue;
        int y2 = vals[3].intValue;
        int dx = abs(x2 - x1);
        int dy = abs(y2 - y1);

        if (dy < 5 && dx > minLineLength * 0.5) {
            // 水平
            [hCenters addObject:@((y1 + y2) / 2.0)];
        } else if (dx < 5 && dy > minLineLength * 0.5) {
            // 垂直
            [vCenters addObject:@((x1 + x2) / 2.0)];
        }
    }

    // 8. 1D 聚类：把相近的中心合并
    NSArray<NSNumber *> *hClustered = [self clusterCenters:hCenters epsilon:5];
    NSArray<NSNumber *> *vClustered = [self clusterCenters:vCenters epsilon:5];

    if (hClustered.count < 3 || vClustered.count < 3) return nil;  // 至少 2 行/列才有意义

    // 9. 计算 corners (resized 像素 → 归一化 0~1，相对原图)
    CGFloat firstX = vClustered.firstObject.doubleValue / resized.cols;
    CGFloat lastX = vClustered.lastObject.doubleValue / resized.cols;
    CGFloat firstY = hClustered.firstObject.doubleValue / resized.rows;
    CGFloat lastY = hClustered.lastObject.doubleValue / resized.rows;

    GridDetectionResultBridge *result = [GridDetectionResultBridge new];
    result.topLeft = CGPointMake(firstX, firstY);
    result.topRight = CGPointMake(lastX, firstY);
    result.bottomLeft = CGPointMake(firstX, lastY);
    result.bottomRight = CGPointMake(lastX, lastY);
    result.rows = hClustered.count - 1;
    result.cols = vClustered.count - 1;
    // 置信度：检出线数 / 期望线数（用聚类后行列数估算）
    double expectedLines = (result.rows + 1) + (result.cols + 1);
    double actualLines = hClustered.count + vClustered.count;
    result.confidence = MIN(actualLines / expectedLines, 1.0) * 0.95;  // 上限 0.95

    return result;
}

+ (nullable GridDetectionResultBridge *)detectGridWithContours:(UIImage *)image {
    if (image == nil) return nil;

    Mat *src = [[Mat alloc] initWithUIImage:image];
    if (src.empty) return nil;

    CGFloat scale = 1024.0 / MAX(image.size.width, image.size.height);
    Mat *resized = [Mat new];
    Size2i *targetSize = [[Size2i alloc] initWithWidth:(int)(image.size.width * scale)
                                                height:(int)(image.size.height * scale)];
    [Imgproc resize:src dst:resized dsize:targetSize fx:0 fy:0 interpolation:InterpolationFlagsInterArea];

    Mat *gray = [Mat new];
    [Imgproc cvtColor:resized dst:gray code:ColorConversionCodeBGR2GRAY];

    Mat *edges = [Mat new];
    [Imgproc Canny:gray edges:edges threshold1:50 threshold2:150];

    NSMutableArray<NSMutableArray<Point2i *> *> *contours = [NSMutableArray array];
    Mat *hierarchy = [Mat new];
    [Imgproc findContours:edges
                 contours:contours
                hierarchy:hierarchy
                     mode:RetrievalModesRetrList
                   method:ContourApproximationModesChainApproxSimple];

    if (contours.count == 0) return nil;

    // 取所有 contour 的整体 bbox
    double minX = INFINITY, minY = INFINITY, maxX = 0, maxY = 0;
    double imageArea = resized.cols * resized.rows;
    NSInteger validContours = 0;
    NSMutableArray<NSNumber *> *cellSizes = [NSMutableArray array];

    for (NSArray<Point2i *> *contour in contours) {
        if (contour.count < 4) continue;
        double cMinX = INFINITY, cMinY = INFINITY, cMaxX = 0, cMaxY = 0;
        for (Point2i *p in contour) {
            cMinX = MIN(cMinX, p.x); cMinY = MIN(cMinY, p.y);
            cMaxX = MAX(cMaxX, p.x); cMaxY = MAX(cMaxY, p.y);
        }
        double area = (cMaxX - cMinX) * (cMaxY - cMinY);
        if (area < imageArea / 5000 || area > imageArea / 100) continue;

        minX = MIN(minX, cMinX); minY = MIN(minY, cMinY);
        maxX = MAX(maxX, cMaxX); maxY = MAX(maxY, cMaxY);
        validContours++;
        [cellSizes addObject:@(sqrt(area))];
    }

    if (validContours < 4 || maxX <= minX || maxY <= minY) return nil;

    // 估算 cell size 取中位数
    NSArray<NSNumber *> *sorted = [cellSizes sortedArrayUsingSelector:@selector(compare:)];
    double cellSize = sorted[sorted.count / 2].doubleValue;
    if (cellSize <= 0) return nil;

    NSInteger cols = MAX(1, round((maxX - minX) / cellSize));
    NSInteger rows = MAX(1, round((maxY - minY) / cellSize));

    GridDetectionResultBridge *result = [GridDetectionResultBridge new];
    result.topLeft = CGPointMake(minX / resized.cols, minY / resized.rows);
    result.topRight = CGPointMake(maxX / resized.cols, minY / resized.rows);
    result.bottomLeft = CGPointMake(minX / resized.cols, maxY / resized.rows);
    result.bottomRight = CGPointMake(maxX / resized.cols, maxY / resized.rows);
    result.rows = rows;
    result.cols = cols;
    result.confidence = 0.45;  // 固定低置信度，提示用户检查

    return result;
}

/// 简单 1D 聚类：sort + 把相邻 < epsilon 的合并取均值
+ (NSArray<NSNumber *> *)clusterCenters:(NSArray<NSNumber *> *)centers epsilon:(double)epsilon {
    if (centers.count == 0) return @[];
    NSArray<NSNumber *> *sorted = [centers sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSNumber *> *result = [NSMutableArray array];

    double clusterSum = sorted[0].doubleValue;
    int clusterCount = 1;
    for (NSUInteger i = 1; i < sorted.count; i++) {
        double v = sorted[i].doubleValue;
        if (v - (clusterSum / clusterCount) < epsilon) {
            clusterSum += v;
            clusterCount++;
        } else {
            [result addObject:@(clusterSum / clusterCount)];
            clusterSum = v;
            clusterCount = 1;
        }
    }
    [result addObject:@(clusterSum / clusterCount)];
    return result;
}

@end
```

- [ ] **Step 3: Build 验证**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -E "error:|BUILD" | tail -5
```

期望 BUILD SUCCEEDED。如果有 enum 常量找不到（`ColorConversionCodeBGR2GRAY`, `InterpolationFlagsInterArea`, `RetrievalModesRetrList`, `ContourApproximationModesChainApproxSimple`），grep opencv2 headers 找正确名字：

```bash
grep -rn "BGR2GRAY\|RETR_LIST" /Users/baodi/Library/Developer/Xcode/DerivedData/BeadInventory-*/SourcePackages/artifacts/opencv-spm/opencv2/opencv2.xcframework/ios-arm64_x86_64-simulator/opencv2.framework/Headers/ 2>/dev/null | head -5
```

如果常量名不对，修改 .m 文件用正确的，再 build。

- [ ] **Step 4: Commit**

```
feat(pattern-highlight): Bridge 扩展 OpenCV Hough/Contours 网格检测（PR2 Task 2）
```

---

## Task 3: GridDetectionService — Swift 入口

**Files:**
- Create: `BeadInventory/Managers/GridDetectionService.swift`

- [ ] **Step 1: 创建 GridDetectionService.swift**

```swift
//
//  GridDetectionService.swift
//  BeadInventory
//
//  拼图模式 - 网格自动检测入口。
//  顺序尝试两种算法（PR3 算法 B 留接口待后续补），返回最高置信度结果。
//

import Foundation
import UIKit

struct GridDetectionResult {
    let corners: GridCorners
    let rows: Int
    let cols: Int
    let confidence: Double      // 0~1，< 0.5 视为"请手动确认"
}

final class GridDetectionService {
    static let shared = GridDetectionService()
    private init() {}

    /// 异步检测网格。失败或置信度极低（< 0.2）时返回 nil。
    func detect(image: UIImage) async -> GridDetectionResult? {
        await withCheckedContinuation { cont in
            Task.detached(priority: .userInitiated) {
                let result = self.detectSync(image: image)
                cont.resume(returning: result)
            }
        }
    }

    private func detectSync(image: UIImage) -> GridDetectionResult? {
        // 算法 A：HoughLines（带网格线的图纸首选）
        if let r = GridDetectionBridge.detectGrid(withHoughLines: image),
           r.confidence >= 0.5 {
            return r.toSwiftResult()
        }

        // 算法 C：findContours 兜底
        if let r = GridDetectionBridge.detectGrid(withContours: image),
           r.confidence >= 0.2 {
            return r.toSwiftResult()
        }

        return nil
    }
}

private extension GridDetectionResultBridge {
    func toSwiftResult() -> GridDetectionResult {
        GridDetectionResult(
            corners: GridCorners(
                topLeft: topLeft,
                topRight: topRight,
                bottomLeft: bottomLeft,
                bottomRight: bottomRight
            ),
            rows: rows,
            cols: cols,
            confidence: confidence
        )
    }
}
```

- [ ] **Step 2: pbxproj 接入** (IDs `385001032FB3...` / `385001042FB3...`)

- [ ] **Step 3: Build**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -E "error:|BUILD" | tail -3
```

- [ ] **Step 4: Commit**

```
feat(pattern-highlight): GridDetectionService Swift 入口（PR2 Task 3）
```

---

## Task 4: GridCellSampler — 像素采样 + 色匹配

**Files:**
- Create: `BeadInventory/Managers/GridCellSampler.swift`

- [ ] **Step 1: 创建 GridCellSampler.swift**

```swift
//
//  GridCellSampler.swift
//  BeadInventory
//
//  拼图模式 - 给定 grid + UIImage，采样每格中心区域 → 匹配最近 BeadColor。
//

import UIKit
import CoreGraphics

final class GridCellSampler {
    static let shared = GridCellSampler()
    private init() {}

    /// 配置：色匹配 ΔE 阈值。> 阈值视为未匹配（返回 nil）。
    private let deltaEThreshold: Double = 18.0

    /// 配置：每格采样多少像素（每边 N，总 N×N）。
    private let samplesPerCellSide: Int = 5

    /// 采样所有格子。返回 [row][col] 色号矩阵（nil = 未匹配）。
    func sample(image: UIImage,
                grid: BeadPatternGrid,
                availableColors: [BeadColor]) -> [[String?]] {
        guard let cgImage = image.cgImage else {
            return Array(repeating: Array(repeating: nil, count: grid.cols), count: grid.rows)
        }

        let width = cgImage.width
        let height = cgImage.height
        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)

        // 缓存 BeadColor 的 Lab 值（提前算）
        let labCache: [(code: String, lab: (l: Double, a: Double, b: Double))] = availableColors.compactMap { color in
            guard let hex = color.colorHex(for: grid.colorSystem),
                  let rgb = rgbFromHex(hex) else { return nil }
            return (color.code(for: grid.colorSystem), rgbToLab(rgb))
        }

        // 取像素数据
        guard let provider = cgImage.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return Array(repeating: Array(repeating: nil, count: grid.cols), count: grid.rows)
        }
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        var result: [[String?]] = Array(repeating: Array(repeating: nil, count: grid.cols), count: grid.rows)

        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                let (tl, tr, br, bl) = GridGeometry.cellQuad(
                    row: row, col: col, rows: grid.rows, cols: grid.cols,
                    corners: grid.corners, in: imageRect
                )

                // 取中心 60% 区域：在 (u, v) 局部坐标 [0.2, 0.8] 范围内均匀采样
                var rSum = 0.0, gSum = 0.0, bSum = 0.0
                var samples = 0
                let n = samplesPerCellSide
                for i in 0..<n {
                    for j in 0..<n {
                        let u = 0.2 + 0.6 * (CGFloat(i) + 0.5) / CGFloat(n)
                        let v = 0.2 + 0.6 * (CGFloat(j) + 0.5) / CGFloat(n)
                        let p = interpolateQuad(tl: tl, tr: tr, br: br, bl: bl, u: u, v: v)
                        let px = Int(p.x.rounded())
                        let py = Int(p.y.rounded())
                        guard px >= 0, px < width, py >= 0, py < height else { continue }
                        let offset = py * bytesPerRow + px * bytesPerPixel
                        rSum += Double(bytes[offset])
                        gSum += Double(bytes[offset + 1])
                        bSum += Double(bytes[offset + 2])
                        samples += 1
                    }
                }
                guard samples > 0 else { continue }
                let avgRGB = (r: rSum / Double(samples), g: gSum / Double(samples), b: bSum / Double(samples))
                let avgLab = rgbToLab(avgRGB)

                // 找最小 ΔE
                var bestCode: String? = nil
                var bestDeltaE = Double.infinity
                for (code, lab) in labCache {
                    let de = deltaE(a: avgLab, b: lab)
                    if de < bestDeltaE {
                        bestDeltaE = de
                        bestCode = code
                    }
                }
                if bestDeltaE <= deltaEThreshold {
                    result[row][col] = bestCode
                }
            }
        }
        return result
    }

    // MARK: - 私有工具

    private func interpolateQuad(tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint,
                                  u: CGFloat, v: CGFloat) -> CGPoint {
        let top = CGPoint(x: tl.x + (tr.x - tl.x) * u, y: tl.y + (tr.y - tl.y) * u)
        let bot = CGPoint(x: bl.x + (br.x - bl.x) * u, y: bl.y + (br.y - bl.y) * u)
        return CGPoint(x: top.x + (bot.x - top.x) * v, y: top.y + (bot.y - top.y) * v)
    }

    private func rgbFromHex(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
    }

    /// sRGB → CIE Lab (D65)。输入 0~255。
    private func rgbToLab(_ rgb: (r: Double, g: Double, b: Double)) -> (l: Double, a: Double, b: Double) {
        func srgb(_ c: Double) -> Double {
            let cc = c / 255.0
            return cc <= 0.04045 ? cc / 12.92 : pow((cc + 0.055) / 1.055, 2.4)
        }
        let r = srgb(rgb.r), g = srgb(rgb.g), b = srgb(rgb.b)
        // sRGB → XYZ (D65)
        let x = r * 0.4124564 + g * 0.3575761 + b * 0.1804375
        let y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
        let z = r * 0.0193339 + g * 0.1191920 + b * 0.9503041
        // XYZ → Lab (D65 reference)
        let xn = 0.95047, yn = 1.0, zn = 1.08883
        func f(_ t: Double) -> Double {
            t > 216.0 / 24389.0 ? pow(t, 1.0/3.0) : (24389.0/27.0 * t + 16.0) / 116.0
        }
        let fx = f(x / xn), fy = f(y / yn), fz = f(z / zn)
        return (l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    private func deltaE(a: (l: Double, a: Double, b: Double),
                        b: (l: Double, a: Double, b: Double)) -> Double {
        let dl = a.l - b.l, da = a.a - b.a, db = a.b - b.b
        return sqrt(dl * dl + da * da + db * db)
    }
}
```

**注意**：`BeadColor.colorHex(for:)` 和 `BeadColor.code(for:)` 是否存在需要确认。如果方法名不一样，读 [BeadColor.swift](BeadInventory/Models/BeadColor.swift) 看实际属性。Likely 是 `mardHex`、`mardCode` 等按 colorSystem 分支。

- [ ] **Step 2: 验证 BeadColor 接口**

```bash
grep -n "func\|var" BeadInventory/Models/BeadColor.swift | head -40
```

按实际接口调整 `labCache` 的属性访问。

- [ ] **Step 3: pbxproj 接入** (IDs `385001052FB3...` / `385001062FB3...`)

- [ ] **Step 4: Build**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -E "error:|BUILD" | tail -3
```

- [ ] **Step 5: Commit**

```
feat(pattern-highlight): GridCellSampler 像素采样 + Lab ΔE 色匹配（PR2 Task 4）
```

---

## Task 5: PatternCalibrationView — 真实标定 UI

**Files:**
- Modify: `BeadInventory/Views/PatternHighlight/PatternCalibrationView.swift`
- Modify: `BeadInventory/Managers/InventoryManager.swift` (add `updateProjectPatternGrid`)

**目标：** 替换占位为完整标定 UI。打开时显示项目图片 + 4 角拖把手 + 行/列 stepper + "自动检测" + "完成" 按钮。

- [ ] **Step 1: InventoryManager 加方法**

在 `InventoryManager.swift` 现有 `updatePlannedProjectName` 附近（约 [line 2897](BeadInventory/Managers/InventoryManager.swift:2897)），增加：

```swift
func updateProjectPatternGrid(_ projectId: UUID, grid: BeadPatternGrid?) {
    guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
    HistoryManager.shared.addRecord(
        operation: "更新拼图模式网格",
        snapshot: projects
    )
    projects[idx].patternGrid = grid

    // 同步到 SwiftData
    Task { @MainActor in
        // 找到对应的 SDProjectRecord 更新 patternGridData
        // 复用现有 save 路径，避免重复代码
        await saveProjectsToSwiftData()
    }
}
```

如果项目里已经有类似 saveProjectsToSwiftData 的方法，复用；否则照搬最接近的 update 方法的持久化模式。读现有 update 方法看现成做法。

- [ ] **Step 2: 重写 PatternCalibrationView**

整体替换为：

```swift
//
//  PatternCalibrationView.swift
//  BeadInventory
//
//  拼图模式 - 网格标定页（手动 + 自动检测预填）
//

import SwiftUI

struct PatternCalibrationView: View {
    let project: ProjectRecord

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var inventoryManager: InventoryManager

    @State private var corners: GridCorners = .initialQuad
    @State private var rows: Int = 29
    @State private var cols: Int = 29
    @State private var detectionRunning = false
    @State private var detectionConfidence: Double? = nil
    @State private var saving = false

    private var image: UIImage? {
        project.thumbnail.flatMap { UIImage(data: $0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let img = image {
                    GeometryReader { geo in
                        let displayRect = aspectFitRect(imageSize: img.size, in: geo.size)
                        ZStack(alignment: .topLeading) {
                            Color.black.opacity(0.05)
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geo.size.width, height: geo.size.height)

                            // 网格预览
                            CalibrationGridOverlay(corners: corners, rows: rows, cols: cols,
                                                   displayRect: displayRect)

                            // 4 个角拖把手
                            ForEach(CornerLabel.allCases, id: \.self) { label in
                                CornerHandle(label: label, corners: $corners, displayRect: displayRect)
                            }
                        }
                    }
                    .clipped()
                } else {
                    Text("项目无图片")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 提示条
                if let conf = detectionConfidence {
                    HStack {
                        Image(systemName: conf >= 0.7 ? "checkmark.circle.fill" :
                              conf >= 0.5 ? "info.circle.fill" : "exclamationmark.triangle.fill")
                        Text(conf >= 0.7 ? "网格识别成功" :
                             conf >= 0.5 ? "请确认网格对齐" :
                             "未能可靠识别，请手动调整")
                            .font(.footnote)
                        Spacer()
                    }
                    .padding(8)
                    .background(conf >= 0.7 ? Color.green.opacity(0.15) :
                                conf >= 0.5 ? Color.blue.opacity(0.15) :
                                Color.orange.opacity(0.15))
                }

                // 工具栏
                VStack(spacing: 12) {
                    HStack {
                        Stepper("行 \(rows)", value: $rows, in: 2...200)
                        Stepper("列 \(cols)", value: $cols, in: 2...200)
                    }
                    HStack(spacing: 12) {
                        Button {
                            runAutoDetect()
                        } label: {
                            Label(detectionRunning ? "检测中..." : "自动检测",
                                  systemImage: "wand.and.rays")
                        }
                        .disabled(detectionRunning || image == nil)

                        Spacer()

                        Button {
                            saveAndDismiss()
                        } label: {
                            Label("完成", systemImage: "checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving || image == nil)
                    }
                }
                .padding()
                .background(.regularMaterial)
            }
            .navigationTitle("标定网格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                // 进入即跑一次自动检测
                if let existing = project.patternGrid {
                    corners = existing.corners
                    rows = existing.rows
                    cols = existing.cols
                } else {
                    runAutoDetect()
                }
            }
        }
    }

    private func runAutoDetect() {
        guard let img = image else { return }
        detectionRunning = true
        Task {
            let result = await GridDetectionService.shared.detect(image: img)
            await MainActor.run {
                detectionRunning = false
                if let r = result {
                    corners = r.corners
                    rows = r.rows
                    cols = r.cols
                    detectionConfidence = r.confidence
                } else {
                    detectionConfidence = 0
                }
            }
        }
    }

    private func saveAndDismiss() {
        guard let img = image else { return }
        saving = true
        Task.detached(priority: .userInitiated) {
            let sampler = GridCellSampler.shared
            let availableColors = await inventoryManager.colorsForCurrentSystem(project.colorSystem)
            let cells = sampler.sample(
                image: img,
                grid: BeadPatternGrid(
                    corners: corners, rows: rows, cols: cols,
                    cellColorCodes: Array(repeating: Array(repeating: nil, count: cols), count: rows),
                    lastCalibratedAt: Date(),
                    sourceImageSize: img.size,
                    colorSystem: project.colorSystem
                ),
                availableColors: availableColors
            )
            let grid = BeadPatternGrid(
                corners: corners, rows: rows, cols: cols,
                cellColorCodes: cells,
                lastCalibratedAt: Date(),
                sourceImageSize: img.size,
                colorSystem: project.colorSystem
            )
            await MainActor.run {
                inventoryManager.updateProjectPatternGrid(project.id, grid: grid)
                saving = false
                dismiss()
            }
        }
    }

    private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2,
                      y: (container.height - h) / 2,
                      width: w, height: h)
    }
}

extension GridCorners {
    /// 默认四角占图片 10%~90%
    static let initialQuad = GridCorners(
        topLeft: CGPoint(x: 0.1, y: 0.1),
        topRight: CGPoint(x: 0.9, y: 0.1),
        bottomLeft: CGPoint(x: 0.1, y: 0.9),
        bottomRight: CGPoint(x: 0.9, y: 0.9)
    )
}

enum CornerLabel: CaseIterable {
    case tl, tr, bl, br
}

private struct CornerHandle: View {
    let label: CornerLabel
    @Binding var corners: GridCorners
    let displayRect: CGRect

    var body: some View {
        let p = currentPoint
        Circle()
            .fill(Color.red.opacity(0.8))
            .frame(width: 24, height: 24)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .position(x: p.x, y: p.y)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let clamped = CGPoint(
                            x: max(displayRect.minX, min(displayRect.maxX, value.location.x)),
                            y: max(displayRect.minY, min(displayRect.maxY, value.location.y))
                        )
                        update(to: GridGeometry.normalize(clamped, in: displayRect))
                    }
            )
    }

    private var currentPoint: CGPoint {
        let norm: CGPoint = {
            switch label {
            case .tl: return corners.topLeft
            case .tr: return corners.topRight
            case .bl: return corners.bottomLeft
            case .br: return corners.bottomRight
            }
        }()
        return GridGeometry.denormalize(norm, in: displayRect)
    }

    private func update(to norm: CGPoint) {
        switch label {
        case .tl: corners.topLeft = norm
        case .tr: corners.topRight = norm
        case .bl: corners.bottomLeft = norm
        case .br: corners.bottomRight = norm
        }
    }
}

private struct CalibrationGridOverlay: View {
    let corners: GridCorners
    let rows: Int
    let cols: Int
    let displayRect: CGRect

    var body: some View {
        Canvas { context, _ in
            // 画 cols+1 条竖线
            for c in 0...cols {
                let u = CGFloat(c) / CGFloat(cols)
                let p1 = GridGeometry.bilinear(u: u, v: 0, corners: corners, in: displayRect)
                let p2 = GridGeometry.bilinear(u: u, v: 1, corners: corners, in: displayRect)
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                context.stroke(path, with: .color(.cyan.opacity(0.6)), lineWidth: 0.5)
            }
            // 画 rows+1 条横线
            for r in 0...rows {
                let v = CGFloat(r) / CGFloat(rows)
                let p1 = GridGeometry.bilinear(u: 0, v: v, corners: corners, in: displayRect)
                let p2 = GridGeometry.bilinear(u: 1, v: v, corners: corners, in: displayRect)
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                context.stroke(path, with: .color(.cyan.opacity(0.6)), lineWidth: 0.5)
            }
        }
    }
}
```

注意：`inventoryManager.colorsForCurrentSystem(_:)` 这个方法可能不存在。读 `InventoryManager.swift` 找现有的"按 colorSystem 取所有可用 BeadColor"的方法。如果不存在，加一个 minimal helper：返回 `inventoryManager.brands` 的 union of 所有 stocks 的 colors。

- [ ] **Step 3: Build**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -E "error:|BUILD" | tail -5
```

- [ ] **Step 4: Commit**

```
feat(pattern-highlight): PatternCalibrationView 完整标定 UI（PR2 Task 5）
```

---

## Task 6: PatternHighlightView + 子组件 — 主视图

**Files:**
- Create: `BeadInventory/Views/PatternHighlight/PatternHighlightView.swift`
- Create: `BeadInventory/Views/PatternHighlight/PatternHighlightOverlay.swift`
- Create: `BeadInventory/Views/PatternHighlight/ColorPaletteBar.swift`
- Create: `BeadInventory/Views/PatternHighlight/ZoomablePatternCanvas.swift`
- Modify: `BeadInventory/Views/PatternHighlight/PatternCalibrationView.swift` (跳转到 Highlight)
- Modify: `BeadInventory/Views/ProjectDetailView.swift` (按 patternGrid 存在与否决定跳哪个 sheet)

- [ ] **Step 1: 创建 PatternHighlightOverlay.swift**

```swift
//
//  PatternHighlightOverlay.swift
//  BeadInventory
//
//  Canvas 叠层：高亮 + 辅助线
//

import SwiftUI

enum GuideMode: String, CaseIterable {
    case off, five, ten
    var label: String {
        switch self {
        case .off: return "关"
        case .five: return "每 5 格"
        case .ten: return "每 10 格"
        }
    }
    var interval: Int? {
        switch self { case .off: return nil; case .five: return 5; case .ten: return 10 }
    }
}

struct PatternHighlightOverlay: View {
    let grid: BeadPatternGrid
    let highlightedCodes: Set<String>
    let guideMode: GuideMode
    let displayRect: CGRect

    var body: some View {
        Canvas { context, _ in
            // 1. 灰罩（如果有高亮选中）
            if !highlightedCodes.isEmpty {
                // 整图盖一层 40% 黑色，然后给高亮格子开洞
                context.fill(Path(displayRect), with: .color(.black.opacity(0.4)))
                for row in 0..<grid.rows {
                    for col in 0..<grid.cols {
                        guard let code = grid.cellColorCodes[row][col],
                              highlightedCodes.contains(code) else { continue }
                        let (tl, tr, br, bl) = GridGeometry.cellQuad(
                            row: row, col: col, rows: grid.rows, cols: grid.cols,
                            corners: grid.corners, in: displayRect
                        )
                        var path = Path()
                        path.move(to: tl); path.addLine(to: tr)
                        path.addLine(to: br); path.addLine(to: bl)
                        path.closeSubpath()
                        // 用 blendMode .destinationOut 不行（Canvas 没有），改用画亮黄色边
                        context.blendMode = .normal
                        context.stroke(path, with: .color(.yellow), lineWidth: 2)
                    }
                }
            }

            // 2. 辅助线
            if let interval = guideMode.interval {
                for c in stride(from: interval, to: grid.cols, by: interval) {
                    let u = CGFloat(c) / CGFloat(grid.cols)
                    let p1 = GridGeometry.bilinear(u: u, v: 0, corners: grid.corners, in: displayRect)
                    let p2 = GridGeometry.bilinear(u: u, v: 1, corners: grid.corners, in: displayRect)
                    var path = Path()
                    path.move(to: p1); path.addLine(to: p2)
                    context.stroke(path, with: .color(.blue.opacity(0.7)), lineWidth: 1.5)
                }
                for r in stride(from: interval, to: grid.rows, by: interval) {
                    let v = CGFloat(r) / CGFloat(grid.rows)
                    let p1 = GridGeometry.bilinear(u: 0, v: v, corners: grid.corners, in: displayRect)
                    let p2 = GridGeometry.bilinear(u: 1, v: v, corners: grid.corners, in: displayRect)
                    var path = Path()
                    path.move(to: p1); path.addLine(to: p2)
                    context.stroke(path, with: .color(.blue.opacity(0.7)), lineWidth: 1.5)
                }
            }
        }
    }
}
```

- [ ] **Step 2: 创建 ColorPaletteBar.swift**

```swift
//
//  ColorPaletteBar.swift
//  BeadInventory
//
//  底部调色板 - 显示项目用到的色号，按用量降序，支持多选高亮
//

import SwiftUI

struct ColorPaletteBar: View {
    let beadUsage: [BeadUsage]
    let colorSystem: ColorSystem
    @Binding var highlightedCodes: Set<String>
    let availableColors: [BeadColor]

    private var sortedUsage: [BeadUsage] {
        beadUsage.sorted { $0.quantity > $1.quantity }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sortedUsage, id: \.id) { usage in
                    paletteChip(usage: usage)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
    }

    private func paletteChip(usage: BeadUsage) -> some View {
        let isSelected = highlightedCodes.contains(usage.colorCode)
        let hex = availableColors.first { $0.code(for: colorSystem) == usage.colorCode }?
            .colorHex(for: colorSystem) ?? "#CCCCCC"
        return Button {
            if isSelected { highlightedCodes.remove(usage.colorCode) }
            else { highlightedCodes.insert(usage.colorCode) }
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 32, height: 32)
                    .overlay(Circle().stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.4),
                                             lineWidth: isSelected ? 3 : 1))
                Text(usage.colorCode)
                    .font(.caption2)
                Text("\(usage.quantity)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

private extension Color {
    init(hex: String) {
        var s = hex.uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0xCCCCCC
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
```

- [ ] **Step 3: 创建 ZoomablePatternCanvas.swift**

```swift
//
//  ZoomablePatternCanvas.swift
//  BeadInventory
//
//  支持缩放/平移的图片 + 叠层容器
//

import SwiftUI

struct ZoomablePatternCanvas<Overlay: View>: View {
    let image: UIImage
    @ViewBuilder var overlay: (CGRect) -> Overlay

    @State private var scale: CGFloat = 1.0
    @GestureState private var pinchDelta: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @GestureState private var dragDelta: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let displayRect = aspectFitRect(imageSize: image.size, in: geo.size)
            ZStack {
                Color.black
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                    overlay(CGRect(origin: .zero, size: displayRect.size))
                        .frame(width: displayRect.width, height: displayRect.height)
                }
                .frame(width: displayRect.width, height: displayRect.height)
                .scaleEffect(scale * pinchDelta)
                .offset(x: offset.width + dragDelta.width, y: offset.height + dragDelta.height)
                .gesture(
                    MagnificationGesture()
                        .updating($pinchDelta) { v, s, _ in s = v }
                        .onEnded { v in
                            scale = max(0.5, min(6, scale * v))
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .updating($dragDelta) { v, s, _ in
                            if scale > 1.05 { s = v.translation }
                        }
                        .onEnded { v in
                            if scale > 1.05 {
                                offset.width += v.translation.width
                                offset.height += v.translation.height
                            }
                        }
                )
            }
            .clipped()
        }
    }

    private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2,
                      y: (container.height - h) / 2,
                      width: w, height: h)
    }
}
```

- [ ] **Step 4: 创建 PatternHighlightView.swift**

```swift
//
//  PatternHighlightView.swift
//  BeadInventory
//
//  拼图模式主视图 - 图 + 高亮叠层 + 调色板 + 辅助线
//

import SwiftUI

struct PatternHighlightView: View {
    let project: ProjectRecord

    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) private var dismiss

    @State private var highlightedCodes: Set<String> = []
    @State private var guideMode: GuideMode = .off
    @State private var showingRecalibrate = false

    private var image: UIImage? {
        project.thumbnail.flatMap { UIImage(data: $0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let img = image, let grid = project.patternGrid {
                    ZoomablePatternCanvas(image: img) { rect in
                        PatternHighlightOverlay(
                            grid: grid,
                            highlightedCodes: highlightedCodes,
                            guideMode: guideMode,
                            displayRect: rect
                        )
                    }
                } else {
                    Text("无图或未标定")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ColorPaletteBar(
                    beadUsage: project.beadUsage,
                    colorSystem: project.colorSystem,
                    highlightedCodes: $highlightedCodes,
                    availableColors: inventoryManager.allBeadColors
                )
            }
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("辅助线") {
                            ForEach(GuideMode.allCases, id: \.self) { m in
                                Button {
                                    guideMode = m
                                } label: {
                                    Label(m.label, systemImage: guideMode == m ? "checkmark" : "")
                                }
                            }
                        }
                        Button {
                            highlightedCodes.removeAll()
                        } label: {
                            Label("清除高亮", systemImage: "eye.slash")
                        }
                        Button {
                            showingRecalibrate = true
                        } label: {
                            Label("重新标定", systemImage: "square.grid.3x3.square")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingRecalibrate) {
                PatternCalibrationView(project: project)
                    .environmentObject(inventoryManager)
            }
        }
    }
}
```

注意：`inventoryManager.allBeadColors` 这个属性需要存在。读 `InventoryManager.swift` 看现有方法是否暴露所有 BeadColor；如果没有，加一个 computed property。

- [ ] **Step 5: 把 ProjectDetailView 改为按 patternGrid 状态决定 sheet 跳哪个**

修改 `ProjectDetailView.swift` 的 `.sheet(isPresented: $showingPatternCalibration)` 块：

```swift
.sheet(isPresented: $showingPatternCalibration) {
    let p = currentProject ?? project
    if p.patternGrid != nil {
        PatternHighlightView(project: p)
            .environmentObject(inventoryManager)
    } else {
        PatternCalibrationView(project: p)
            .environmentObject(inventoryManager)
    }
}
```

- [ ] **Step 6: pbxproj 接入 4 个新文件** (IDs `385001072FB3...` 到 `385001102FB3...`)

- [ ] **Step 7: Build + 手动 UI 验证**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -E "error:|BUILD" | tail -5
```

跑模拟器，操作流程：
1. 进任意计划项目（要有缩略图）
2. 点右上"拼图模式" → 标定页 → 自动检测可能成功也可能不成功 → 拖角调行列 → 点"完成"
3. 进入高亮页，看到调色板
4. 点一个色号 → 应看到对应格子周边亮黄边、其它格子盖灰罩
5. 菜单 → 辅助线 5 格 → 蓝色辅助线出现

- [ ] **Step 8: Commit**

```
feat(pattern-highlight): 主视图 + Overlay + 调色板 + 缩放（PR2 Task 6）
```

---

## Task 7: GridValidator + 校验 UI

**Files:**
- Create: `BeadInventory/Managers/GridValidator.swift`
- Create: `BeadInventoryTests/GridValidatorTests.swift`
- Create: `BeadInventory/Views/PatternHighlight/ValidationDiffSheet.swift`
- Modify: `BeadInventory/Views/PatternHighlight/PatternHighlightView.swift` (顶部 banner)

- [ ] **Step 1: 创建 GridValidator.swift**

```swift
//
//  GridValidator.swift
//  BeadInventory
//
//  对比 BeadPatternGrid.cellColorCodes 与 ProjectRecord.beadUsage，输出差异。
//

import Foundation

struct GridValidationDiff: Equatable, Identifiable {
    var id: String { code }
    let code: String
    let gridCount: Int      // 网格识别出的数量
    let legendCount: Int    // beadUsage 里登记的数量

    var delta: Int { gridCount - legendCount }
    var isMatch: Bool { delta == 0 }
}

enum GridValidator {
    /// 返回所有 code 的对比，按 |delta| 降序。code 来自二者并集。
    static func compare(grid: BeadPatternGrid, beadUsage: [BeadUsage]) -> [GridValidationDiff] {
        var gridCounts: [String: Int] = [:]
        for row in grid.cellColorCodes {
            for cell in row {
                guard let c = cell else { continue }
                gridCounts[c, default: 0] += 1
            }
        }
        let legendCounts: [String: Int] = Dictionary(uniqueKeysWithValues:
            beadUsage.map { ($0.colorCode, $0.quantity) })

        let allCodes = Set(gridCounts.keys).union(legendCounts.keys)
        let diffs = allCodes.map { code in
            GridValidationDiff(
                code: code,
                gridCount: gridCounts[code] ?? 0,
                legendCount: legendCounts[code] ?? 0
            )
        }
        return diffs.sorted { abs($0.delta) > abs($1.delta) }
    }

    /// 取只有差异的项。
    static func mismatches(grid: BeadPatternGrid, beadUsage: [BeadUsage]) -> [GridValidationDiff] {
        compare(grid: grid, beadUsage: beadUsage).filter { !$0.isMatch }
    }
}
```

- [ ] **Step 2: 创建 GridValidatorTests.swift**

```swift
import XCTest
@testable import BeadInventory

final class GridValidatorTests: XCTestCase {
    private func grid(cells: [[String?]]) -> BeadPatternGrid {
        BeadPatternGrid(
            corners: GridCorners(topLeft: .zero, topRight: CGPoint(x: 1, y: 0),
                                 bottomLeft: CGPoint(x: 0, y: 1), bottomRight: CGPoint(x: 1, y: 1)),
            rows: cells.count,
            cols: cells.first?.count ?? 0,
            cellColorCodes: cells,
            lastCalibratedAt: Date(),
            sourceImageSize: CGSize(width: 100, height: 100),
            colorSystem: .mard
        )
    }

    private func usage(_ pairs: [(String, Int)]) -> [BeadUsage] {
        pairs.map { BeadUsage(colorCode: $0.0, quantity: $0.1) }
    }

    func testAllMatch() {
        let g = grid(cells: [["A", "A", "B"], ["A", "B", nil]])
        let u = usage([("A", 3), ("B", 2)])
        XCTAssertEqual(GridValidator.mismatches(grid: g, beadUsage: u), [])
    }

    func testMissingCodeInLegend() {
        let g = grid(cells: [["A", "C"]])
        let u = usage([("A", 1)])
        let diff = GridValidator.mismatches(grid: g, beadUsage: u)
        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff.first?.code, "C")
        XCTAssertEqual(diff.first?.gridCount, 1)
        XCTAssertEqual(diff.first?.legendCount, 0)
    }

    func testCountMismatch() {
        let g = grid(cells: [["A", "A", "A"]])
        let u = usage([("A", 5)])
        let diff = GridValidator.mismatches(grid: g, beadUsage: u)
        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff.first?.gridCount, 3)
        XCTAssertEqual(diff.first?.legendCount, 5)
    }

    func testNilCellsExcluded() {
        let g = grid(cells: [[nil, nil, "A"]])
        let u = usage([("A", 1)])
        XCTAssertEqual(GridValidator.mismatches(grid: g, beadUsage: u), [])
    }
}
```

- [ ] **Step 3: 创建 ValidationDiffSheet.swift**

```swift
//
//  ValidationDiffSheet.swift
//  BeadInventory
//
//  网格 vs 图例差异展示 + 一键修正
//

import SwiftUI

struct ValidationDiffSheet: View {
    let diffs: [GridValidationDiff]
    let onAdoptGridForCode: (String, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(diffs) { d in
                    HStack {
                        Text(d.code).font(.headline)
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("网格 \(d.gridCount)").font(.caption)
                            Text("图例 \(d.legendCount)").font(.caption)
                        }
                        Button("以网格为准") {
                            onAdoptGridForCode(d.code, d.gridCount)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("识别差异 (\(diffs.count))")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
```

- [ ] **Step 4: 在 PatternHighlightView 顶部加 banner**

在 `VStack` 之前加 `@State private var showingDiffSheet = false`，然后在 `ZoomablePatternCanvas` 上方插入：

```swift
if let grid = project.patternGrid {
    let mismatches = GridValidator.mismatches(grid: grid, beadUsage: project.beadUsage)
    if !mismatches.isEmpty {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("网格识别与图例有 \(mismatches.count) 处差异")
                .font(.footnote)
            Spacer()
            Button("详情") { showingDiffSheet = true }
                .font(.footnote)
        }
        .padding(8)
        .background(Color.orange.opacity(0.15))
    }
}
```

并加 sheet：

```swift
.sheet(isPresented: $showingDiffSheet) {
    if let grid = project.patternGrid {
        ValidationDiffSheet(
            diffs: GridValidator.mismatches(grid: grid, beadUsage: project.beadUsage),
            onAdoptGridForCode: { code, gridCount in
                inventoryManager.updatePlannedProjectUsage(project.id, colorCode: code, newQuantity: gridCount)
            }
        )
    }
}
```

- [ ] **Step 5: pbxproj 接入** (IDs `385001112FB3...` / `385001122FB3...`，Validator + Sheet 各 1 + tests 文件自动从 sync group)

- [ ] **Step 6: Build + Test**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | grep -E "Test Suite|TEST" | tail -10
```

期望 8 + 5 + 4 = 17 测试通过。

- [ ] **Step 7: 手动 UI 验证**

在模拟器跑完整流程：
1. 计划项目 → 拼图模式 → 标定 → 完成
2. 进入高亮页，应能看到顶部黄色 banner（除非网格识别 100% 准）
3. 点 banner → 详情 sheet 列出所有差异
4. 点"以网格为准" → diff 应减少
5. 退回主页面再进入，差异已应用

- [ ] **Step 8: Commit**

```
feat(pattern-highlight): GridValidator 网格 vs 图例校验 + diff sheet（PR2 Task 7）
```

---

## 整体收尾

完成全部 7 个 task 后：

- [ ] 跑全部测试，期望 17 测试通过（PR1 的 8 + Task 1 的 5 + Task 7 的 4）
- [ ] 手动跑完整用户旅程，确认每一步都顺畅
- [ ] App 体积变化记录（可选）
- [ ] Push 后建议人工 review 整个 branch（diff 巨大）

## 验收

- [ ] 计划项目有图片时显示"拼图模式"按钮
- [ ] 第一次打开自动标定，结果显示在图上
- [ ] 可手动调 4 角和行列
- [ ] 完成后跳到高亮页
- [ ] 调色板按用量降序排
- [ ] 点色号高亮该色所有格子（其它格盖灰）
- [ ] 多选可叠加
- [ ] 辅助线 5/10/关三档切换
- [ ] 双指缩放、平移流畅
- [ ] 网格 vs 图例差异提示，可一键修正
- [ ] 标定结果持久化（退出再进保留）
- [ ] 重新标定入口可用
