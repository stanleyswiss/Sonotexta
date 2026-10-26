#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionCatcher : NSObject

+ (NSException * _Nullable)catchException:(void (NS_NOESCAPE ^)(void))block;

@end

NS_ASSUME_NONNULL_END
