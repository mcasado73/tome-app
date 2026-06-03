#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const MCShimErrorDomain;

/// Wraps -[AVAudioNode installTapOnBus:bufferSize:format:block:] inside an
/// Obj-C @try/@catch. AVFoundation raises NSException synchronously during
/// input-device transitions on macOS 26, which Swift cannot catch and which
/// terminates the process via abort(). On exception, returns NO and populates
/// outError with the exception name + reason so the caller can surface a
/// recoverable error instead of crashing.
BOOL MCInstallTapOnNode(AVAudioNode *node,
                        NSUInteger bus,
                        UInt32 bufferSize,
                        AVAudioFormat * _Nullable format,
                        AVAudioNodeTapBlock block,
                        NSError * _Nullable __autoreleasing * _Nullable outError);

NS_ASSUME_NONNULL_END
