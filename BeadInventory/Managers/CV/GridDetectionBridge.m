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

+ (nullable GridDetectionResultBridge *)detectGridWithHoughLines:(UIImage *)image {
    if (image == nil) return nil;

    Mat *src = [[Mat alloc] initWithUIImage:image];
    if ([src empty]) return nil;

    // 缩放到长边 1024
    CGFloat scale = 1024.0 / MAX(image.size.width, image.size.height);
    int newW = (int)(image.size.width * scale);
    int newH = (int)(image.size.height * scale);
    Mat *resized = [Mat new];
    Size2i *targetSize = [[Size2i alloc] initWithWidth:newW height:newH];
    [Imgproc resize:src dst:resized dsize:targetSize fx:0 fy:0 interpolation:INTER_AREA];

    // 灰度
    Mat *gray = [Mat new];
    [Imgproc cvtColor:resized dst:gray code:COLOR_BGR2GRAY];

    // 高斯模糊去噪
    Mat *blurred = [Mat new];
    Size2i *ksize = [[Size2i alloc] initWithWidth:3 height:3];
    [Imgproc GaussianBlur:gray dst:blurred ksize:ksize sigmaX:0];

    // Canny 边缘
    Mat *edges = [Mat new];
    [Imgproc Canny:blurred edges:edges threshold1:50 threshold2:150];

    // HoughLinesP
    Mat *lines = [Mat new];
    double minLineLength = MIN([resized cols], [resized rows]) * 0.3;
    [Imgproc HoughLinesP:edges lines:lines
                     rho:1.0
                   theta:M_PI / 180.0
               threshold:80
           minLineLength:minLineLength
              maxLineGap:10];

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

        if (dy < 5 && dx > minLineLength * 0.5) {
            [hCenters addObject:@((y1 + y2) / 2.0)];
        } else if (dx < 5 && dy > minLineLength * 0.5) {
            [vCenters addObject:@((x1 + x2) / 2.0)];
        }
    }

    NSArray<NSNumber *> *hClustered = [self clusterCenters:hCenters epsilon:5];
    NSArray<NSNumber *> *vClustered = [self clusterCenters:vCenters epsilon:5];

    if (hClustered.count < 3 || vClustered.count < 3) return nil;

    double imgW = (double)[resized cols];
    double imgH = (double)[resized rows];

    double firstX = vClustered.firstObject.doubleValue / imgW;
    double lastX = vClustered.lastObject.doubleValue / imgW;
    double firstY = hClustered.firstObject.doubleValue / imgH;
    double lastY = hClustered.lastObject.doubleValue / imgH;

    GridDetectionResultBridge *result = [GridDetectionResultBridge new];
    result.topLeft = CGPointMake(firstX, firstY);
    result.topRight = CGPointMake(lastX, firstY);
    result.bottomLeft = CGPointMake(firstX, lastY);
    result.bottomRight = CGPointMake(lastX, lastY);
    result.rows = (NSInteger)hClustered.count - 1;
    result.cols = (NSInteger)vClustered.count - 1;
    double expectedLines = (result.rows + 1) + (result.cols + 1);
    double actualLines = hClustered.count + vClustered.count;
    result.confidence = MIN(actualLines / expectedLines, 1.0) * 0.95;

    return result;
}

#pragma mark - Algorithm C: findContours fallback

+ (nullable GridDetectionResultBridge *)detectGridWithContours:(UIImage *)image {
    if (image == nil) return nil;

    Mat *src = [[Mat alloc] initWithUIImage:image];
    if ([src empty]) return nil;

    CGFloat scale = 1024.0 / MAX(image.size.width, image.size.height);
    int newW = (int)(image.size.width * scale);
    int newH = (int)(image.size.height * scale);
    Mat *resized = [Mat new];
    Size2i *targetSize = [[Size2i alloc] initWithWidth:newW height:newH];
    [Imgproc resize:src dst:resized dsize:targetSize fx:0 fy:0 interpolation:INTER_AREA];

    Mat *gray = [Mat new];
    [Imgproc cvtColor:resized dst:gray code:COLOR_BGR2GRAY];

    Mat *edges = [Mat new];
    [Imgproc Canny:gray edges:edges threshold1:50 threshold2:150];

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

    double imgW = (double)[resized cols];
    double imgH = (double)[resized rows];

    GridDetectionResultBridge *result = [GridDetectionResultBridge new];
    result.topLeft = CGPointMake(minX / imgW, minY / imgH);
    result.topRight = CGPointMake(maxX / imgW, minY / imgH);
    result.bottomLeft = CGPointMake(minX / imgW, maxY / imgH);
    result.bottomRight = CGPointMake(maxX / imgW, maxY / imgH);
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

@end
