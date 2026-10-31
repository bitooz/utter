#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift cannot catch an Objective-C exception, and AVAudioEngine raises them (no input device,
/// odd formats, device changes). Running such calls through here turns them into thrown errors.
@interface ObjCCatch : NSObject
+ (BOOL)run:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
