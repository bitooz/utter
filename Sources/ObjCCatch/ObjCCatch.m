#import "ObjCCatch.h"

@implementation ObjCCatch
+ (BOOL)run:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (error) {
            *error = [NSError errorWithDomain:@"ObjCException" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""]}];
        }
        return NO;
    }
}
@end
