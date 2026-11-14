#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// A per-frame gain envelope on the output of a Float32 audio unit.
@interface QMPlaybackEnvelope : NSObject
- (nullable instancetype)initWithNode:(AVAudioUnit *)node NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, getter=isOpen) BOOL open;
/// Start the next entry from zero even if the previous renderer stopped mid-fade.
- (void)resetToSilence;
/// True once the render thread has produced a full silent buffer for the current close.
@property(nonatomic, readonly) BOOL hasRenderedSilence;
@end

NS_ASSUME_NONNULL_END
