#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (NSException * _Nullable)catchException:(void (NS_NOESCAPE ^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}

@end
