//
//  GridDetectionBridge.h
//  BeadInventory
//
//  拼图模式 - OpenCV 桥接入口
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 网格检测结果。归一化角点坐标 (0~1)，相对源图片左上角。
@interface GridDetectionResultBridge : NSObject
@property (nonatomic, assign) CGPoint topLeft;
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
/// roi: 可选，传 NSValue(cgRect:) 把检测限制在该像素矩形内（用于用户用 2 角圈定区域后再检测）。
///      传 nil 则全图检测。
/// 失败/无法识别时返回 nil。
+ (nullable GridDetectionResultBridge *)detectGridWithHoughLines:(UIImage *)image
                                                              roi:(nullable NSValue *)roi;

/// 算法 C：findContours 检测无网格线图纸（兜底）。
/// confidence 固定较低（≤0.45），仅作预填。
+ (nullable GridDetectionResultBridge *)detectGridWithContours:(UIImage *)image
                                                            roi:(nullable NSValue *)roi;

@end

NS_ASSUME_NONNULL_END
