//
//  GridDetectionBridge.mm
//  BeadInventory
//
//  Objective-C++ 实现，include OpenCV 头并调用 cv::getVersionString 验证链接。
//

#import "GridDetectionBridge.h"
#import <opencv2/opencv.hpp>

@implementation GridDetectionBridge

+ (NSString *)opencvVersion {
    std::string ver = cv::getVersionString();
    return [NSString stringWithUTF8String:ver.c_str()];
}

@end
