#import "MicCaptureShim.h"

NSString * const MCShimErrorDomain = @"io.gremble.tome.MicCaptureShim";

BOOL MCInstallTapOnNode(AVAudioNode *node,
                        NSUInteger bus,
                        UInt32 bufferSize,
                        AVAudioFormat *format,
                        AVAudioNodeTapBlock block,
                        NSError * _Nullable __autoreleasing * _Nullable outError) {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        if (outError) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: @"AVAudioNode installTapOnBus raised an exception";
            if (exception.name) {
                info[@"ExceptionName"] = exception.name;
            }
            *outError = [NSError errorWithDomain:MCShimErrorDomain code:1 userInfo:info];
        }
        return NO;
    }
}
