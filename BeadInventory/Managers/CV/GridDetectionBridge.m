//
//  GridDetectionBridge.m
//  BeadInventory
//
//  Objective-C 实现。opencv-spm 通过 opencv2.framework 暴露 Obj-C 包装 API，
//  所以这里直接调 [Core getVersionString]，无需 C++ 互操作。
//

#import "GridDetectionBridge.h"
#import <opencv2/opencv2.h>

@implementation GridDetectionBridge

+ (NSString *)opencvVersion {
    return [Core getVersionString];
}

@end
