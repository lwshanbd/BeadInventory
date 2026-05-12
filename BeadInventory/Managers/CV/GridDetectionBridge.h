//
//  GridDetectionBridge.h
//  BeadInventory
//
//  拼图模式 - OpenCV 桥接入口
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Obj-C 桥接入口。PR1 只暴露 ping 方法，验证 OpenCV 链接通路。
/// 真正的检测算法在 PR3 实现。
@interface GridDetectionBridge : NSObject

/// 返回 OpenCV 版本字符串，用于 smoke test。
+ (NSString *)opencvVersion;

@end

NS_ASSUME_NONNULL_END
