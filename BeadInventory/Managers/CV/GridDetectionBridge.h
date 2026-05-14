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
/// confidence 固定为 0.45，仅作预填提示用户务必检查。
+ (nullable GridDetectionResultBridge *)detectGridWithContours:(UIImage *)image
                                                            roi:(nullable NSValue *)roi;

/// 算法 D（约束拟合）：用户已经提供行/列数，反推 4 角。
/// 思路：把 rows/cols 当作硬约束，在 Canny 边缘投影上搜索最佳
/// (offset, period) 使得 rows+1 / cols+1 条等距线落在投影高峰上。
/// 比 Hough 鲁棒得多，因为边缘标号、水印的散乱边都不在等距网格上。
+ (nullable GridDetectionResultBridge *)fitGridWithRows:(NSInteger)rows
                                                    cols:(NSInteger)cols
                                                   image:(UIImage *)image
                                                     roi:(nullable NSValue *)roi;

@end

NS_ASSUME_NONNULL_END
