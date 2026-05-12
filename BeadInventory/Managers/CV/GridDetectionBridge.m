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

#pragma mark - Algorithm A: HoughLinesP

+ (nullable GridDetectionResultBridge *)detectGridWithHoughLines:(UIImage *)image
                                                              roi:(nullable NSValue *)roiValue {
    if (image == nil) return nil;

    Mat *src = [[Mat alloc] initWithUIImage:image];
    if ([src empty]) return nil;

    int origCols = [src cols];
    int origRows = [src rows];

    // 如果指定了 ROI，先裁剪
    Mat *working = src;
    int roiOffsetX = 0;
    int roiOffsetY = 0;
    if (roiValue != nil) {
        CGRect roi = [roiValue CGRectValue];
        // 限制 ROI 在图内
        int rx = MAX(0, (int)roi.origin.x);
        int ry = MAX(0, (int)roi.origin.y);
        int rw = MIN(origCols - rx, (int)roi.size.width);
        int rh = MIN(origRows - ry, (int)roi.size.height);
        if (rw <= 10 || rh <= 10) return nil;

        Rect2i *rect = [[Rect2i alloc] initWithX:rx y:ry width:rw height:rh];
        working = [src submatRoi:rect];
        roiOffsetX = rx;
        roiOffsetY = ry;
    }

    // 缩放到长边 1024
    int wCols = [working cols];
    int wRows = [working rows];
    CGFloat scale = 1024.0 / MAX(wCols, wRows);
    int newW = (int)(wCols * scale);
    int newH = (int)(wRows * scale);
    Mat *resized = [Mat new];
    Size2i *targetSize = [[Size2i alloc] initWithWidth:newW height:newH];
    [Imgproc resize:working dst:resized dsize:targetSize fx:0 fy:0 interpolation:INTER_AREA];

    // 灰度
    Mat *gray = [Mat new];
    [Imgproc cvtColor:resized dst:gray code:COLOR_BGR2GRAY];

    // 高斯模糊去噪
    Mat *blurred = [Mat new];
    Size2i *ksize = [[Size2i alloc] initWithWidth:3 height:3];
    [Imgproc GaussianBlur:gray dst:blurred ksize:ksize sigmaX:0];

    // Canny 边缘（更敏感的阈值，识别浅色细网格线）
    Mat *edges = [Mat new];
    [Imgproc Canny:blurred edges:edges threshold1:30 threshold2:90];

    // HoughLinesP
    Mat *lines = [Mat new];
    double minLineLength = MIN([resized cols], [resized rows]) * 0.4;
    [Imgproc HoughLinesP:edges lines:lines
                     rho:1.0
                   theta:M_PI / 180.0
               threshold:60
           minLineLength:minLineLength
              maxLineGap:15];

    if ([lines rows] == 0) return nil;

    // 分离水平 / 垂直线
    NSMutableArray<NSNumber *> *hCenters = [NSMutableArray array];
    NSMutableArray<NSNumber *> *vCenters = [NSMutableArray array];

    for (int i = 0; i < [lines rows]; i++) {
        NSArray<NSNumber *> *vals = [lines get:i col:0];
        if (vals.count < 4) continue;
        int x1 = vals[0].intValue;
        int y1 = vals[1].intValue;
        int x2 = vals[2].intValue;
        int y2 = vals[3].intValue;
        int dx = abs(x2 - x1);
        int dy = abs(y2 - y1);

        if (dy < 8 && dx > minLineLength * 0.6) {
            [hCenters addObject:@((y1 + y2) / 2.0)];
        } else if (dx < 8 && dy > minLineLength * 0.6) {
            [vCenters addObject:@((x1 + x2) / 2.0)];
        }
    }

    // 聚类容差跟图大小成比例
    double epsilon = MAX(4.0, [resized rows] * 0.005);
    NSArray<NSNumber *> *hClustered = [self clusterCenters:hCenters epsilon:epsilon];
    NSArray<NSNumber *> *vClustered = [self clusterCenters:vCenters epsilon:epsilon];

    if (hClustered.count < 3 || vClustered.count < 3) return nil;

    double resizedW = (double)[resized cols];
    double resizedH = (double)[resized rows];

    // 将聚类中心从 resized 坐标系反映射到原图归一化坐标
    double firstX = vClustered.firstObject.doubleValue;
    double lastX = vClustered.lastObject.doubleValue;
    double firstY = hClustered.firstObject.doubleValue;
    double lastY = hClustered.lastObject.doubleValue;

    // resized → working：除以 scale
    // working → 原图：加上 ROI 偏移
    // 原图 → 归一化：除以原图尺寸
    double firstX_orig = (firstX / scale + roiOffsetX) / origCols;
    double lastX_orig = (lastX / scale + roiOffsetX) / origCols;
    double firstY_orig = (firstY / scale + roiOffsetY) / origRows;
    double lastY_orig = (lastY / scale + roiOffsetY) / origRows;

    GridDetectionResultBridge *result = [GridDetectionResultBridge new];
    result.topLeft = CGPointMake(firstX_orig, firstY_orig);
    result.topRight = CGPointMake(lastX_orig, firstY_orig);
    result.bottomLeft = CGPointMake(firstX_orig, lastY_orig);
    result.bottomRight = CGPointMake(lastX_orig, lastY_orig);
    result.rows = (NSInteger)hClustered.count - 1;
    result.cols = (NSInteger)vClustered.count - 1;

    // 置信度：检出线密度
    double expectedLines = (result.rows + 1) + (result.cols + 1);
    double actualLines = hClustered.count + vClustered.count;
    double densityScore = MIN(actualLines / expectedLines, 1.0);

    // 间距方差越小（更规整）置信度越高
    double hVar = [self relativeVariance:hClustered];
    double vVar = [self relativeVariance:vClustered];
    double regularityScore = 1.0 - MIN(1.0, MAX(hVar, vVar) * 5.0);

    result.confidence = densityScore * 0.5 + regularityScore * 0.5;
    if (result.confidence > 0.95) result.confidence = 0.95;
    if (resizedW > 0) { /* keep compiler happy unused warning */ }
    if (resizedH > 0) { }

    return result;
}

#pragma mark - Algorithm C: findContours fallback

+ (nullable GridDetectionResultBridge *)detectGridWithContours:(UIImage *)image
                                                            roi:(nullable NSValue *)roiValue {
    if (image == nil) return nil;

    Mat *src = [[Mat alloc] initWithUIImage:image];
    if ([src empty]) return nil;

    int origCols = [src cols];
    int origRows = [src rows];

    Mat *working = src;
    int roiOffsetX = 0;
    int roiOffsetY = 0;
    if (roiValue != nil) {
        CGRect roi = [roiValue CGRectValue];
        int rx = MAX(0, (int)roi.origin.x);
        int ry = MAX(0, (int)roi.origin.y);
        int rw = MIN(origCols - rx, (int)roi.size.width);
        int rh = MIN(origRows - ry, (int)roi.size.height);
        if (rw <= 10 || rh <= 10) return nil;

        Rect2i *rect = [[Rect2i alloc] initWithX:rx y:ry width:rw height:rh];
        working = [src submatRoi:rect];
        roiOffsetX = rx;
        roiOffsetY = ry;
    }

    int wCols = [working cols];
    int wRows = [working rows];
    CGFloat scale = 1024.0 / MAX(wCols, wRows);
    int newW = (int)(wCols * scale);
    int newH = (int)(wRows * scale);
    Mat *resized = [Mat new];
    Size2i *targetSize = [[Size2i alloc] initWithWidth:newW height:newH];
    [Imgproc resize:working dst:resized dsize:targetSize fx:0 fy:0 interpolation:INTER_AREA];

    Mat *gray = [Mat new];
    [Imgproc cvtColor:resized dst:gray code:COLOR_BGR2GRAY];

    Mat *edges = [Mat new];
    [Imgproc Canny:gray edges:edges threshold1:30 threshold2:90];

    NSMutableArray<NSMutableArray<Point2i *> *> *contours = [NSMutableArray array];
    Mat *hierarchy = [Mat new];
    [Imgproc findContours:edges contours:contours hierarchy:hierarchy
                     mode:RETR_LIST method:CHAIN_APPROX_SIMPLE];

    if (contours.count == 0) return nil;

    double imageArea = (double)[resized cols] * (double)[resized rows];
    double minX = INFINITY, minY = INFINITY, maxX = 0, maxY = 0;
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
        if (area < imageArea / 5000.0 || area > imageArea / 100.0) continue;

        minX = MIN(minX, cMinX); minY = MIN(minY, cMinY);
        maxX = MAX(maxX, cMaxX); maxY = MAX(maxY, cMaxY);
        validContours++;
        [cellSizes addObject:@(sqrt(area))];
    }

    if (validContours < 4 || maxX <= minX || maxY <= minY) return nil;

    NSArray<NSNumber *> *sorted = [cellSizes sortedArrayUsingSelector:@selector(compare:)];
    double cellSize = sorted[sorted.count / 2].doubleValue;
    if (cellSize <= 0) return nil;

    NSInteger cols = MAX(1, (NSInteger)round((maxX - minX) / cellSize));
    NSInteger rows = MAX(1, (NSInteger)round((maxY - minY) / cellSize));

    double minX_orig = (minX / scale + roiOffsetX) / origCols;
    double maxX_orig = (maxX / scale + roiOffsetX) / origCols;
    double minY_orig = (minY / scale + roiOffsetY) / origRows;
    double maxY_orig = (maxY / scale + roiOffsetY) / origRows;

    GridDetectionResultBridge *result = [GridDetectionResultBridge new];
    result.topLeft = CGPointMake(minX_orig, minY_orig);
    result.topRight = CGPointMake(maxX_orig, minY_orig);
    result.bottomLeft = CGPointMake(minX_orig, maxY_orig);
    result.bottomRight = CGPointMake(maxX_orig, maxY_orig);
    result.rows = rows;
    result.cols = cols;
    result.confidence = 0.45;

    return result;
}

#pragma mark - Helpers

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

/// 相邻间距的相对方差（除以均值），衡量规整程度。返回 0~∞，越小越规整。
+ (double)relativeVariance:(NSArray<NSNumber *> *)centers {
    if (centers.count < 3) return 1.0;
    NSMutableArray<NSNumber *> *diffs = [NSMutableArray array];
    for (NSUInteger i = 1; i < centers.count; i++) {
        [diffs addObject:@(centers[i].doubleValue - centers[i-1].doubleValue)];
    }
    double sum = 0;
    for (NSNumber *d in diffs) sum += d.doubleValue;
    double mean = sum / diffs.count;
    if (mean <= 0) return 1.0;
    double var = 0;
    for (NSNumber *d in diffs) var += pow(d.doubleValue - mean, 2);
    var /= diffs.count;
    return sqrt(var) / mean;
}

@end
