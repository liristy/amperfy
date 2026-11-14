#import "QMPlaybackEnvelope.h"
#import <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>

typedef struct {
    atomic_uint command;        // Low bit is the target, higher bits distinguish successive closes.
    atomic_uint silentCommand;
    atomic_uint resetGeneration;
    unsigned appliedReset;
    UInt32 position;            // Only the render thread changes the envelope position.
    UInt32 length;
} EnvelopeState;

static OSStatus applyEnvelope(void *context, AudioUnitRenderActionFlags *flags,
                              const AudioTimeStamp *time, UInt32 bus, UInt32 frames,
                              AudioBufferList *data) {
    if (!(*flags & kAudioUnitRenderAction_PostRender) || (*flags & kAudioUnitRenderAction_PostRenderError)
        || bus != 0 || frames == 0 || !data || !data->mNumberBuffers) return noErr;

    EnvelopeState *state = context;
    unsigned command = atomic_load(&state->command);
    unsigned reset = atomic_load(&state->resetGeneration);
    if (reset != state->appliedReset) {
        state->position = 0;
        state->appliedReset = reset;
    }
    bool open = command & 1;
    UInt32 position = state->position;
    if (open && position == state->length) return noErr;
    for (UInt32 b = 0; b < data->mNumberBuffers; ++b) {
        AudioBuffer buffer = data->mBuffers[b];
        if (!buffer.mData || !buffer.mNumberChannels ||
            frames > buffer.mDataByteSize / sizeof(float) / buffer.mNumberChannels) return noErr;
    }

    if (!open && position == 0) {
        for (UInt32 b = 0; b < data->mNumberBuffers; ++b) {
            AudioBuffer buffer = data->mBuffers[b];
            memset(buffer.mData, 0, frames * buffer.mNumberChannels * sizeof(float));
        }
        atomic_store(&state->silentCommand, command);
        return noErr;
    }

    for (UInt32 frame = 0; frame < frames; ++frame) {
        // Don't spend the fade-in on silent decoder preroll.
        bool audible = false;
        float t = (float)position / state->length;
        float gain = t * t * (3.0f - 2.0f * t);
        for (UInt32 b = 0; b < data->mNumberBuffers; ++b) {
            AudioBuffer buffer = data->mBuffers[b];
            float *samples = (float *)buffer.mData + frame * buffer.mNumberChannels;
            for (UInt32 channel = 0; channel < buffer.mNumberChannels; ++channel) {
                audible |= samples[channel] != 0;
                samples[channel] *= gain;
            }
        }
        if (open && position < state->length && (position || audible)) ++position;
        if (!open && position) --position;
        if (open && position == state->length) break;
    }
    state->position = position;
    return noErr;
}

@implementation QMPlaybackEnvelope {
    AVAudioUnit *_node;
    EnvelopeState _state;
}

- (instancetype)initWithNode:(AVAudioUnit *)node {
    self = [super init];
    if (self) {
        AVAudioFormat *format = [node outputFormatForBus:0];
        if (format.commonFormat != AVAudioPCMFormatFloat32 || format.sampleRate <= 0) return nil;
        _state.length = MAX(1, (UInt32)(format.sampleRate * 0.024));
        atomic_init(&_state.command, 0);
        atomic_init(&_state.silentCommand, 0);
        atomic_init(&_state.resetGeneration, 0);
        if (AudioUnitAddRenderNotify(node.audioUnit, applyEnvelope, &_state) != noErr) return nil;
        _node = node;
    }
    return self;
}

- (BOOL)isOpen { return atomic_load(&_state.command) & 1; }
- (void)setOpen:(BOOL)open {
    // The transport (main actor) is the sole command writer.
    if (self.isOpen != open) atomic_fetch_add(&_state.command, 1);
}
- (BOOL)hasRenderedSilence {
    unsigned command = atomic_load(&_state.command);
    return !(command & 1) && atomic_load(&_state.silentCommand) == command;
}
- (void)resetToSilence {
    self.open = NO;
    atomic_fetch_add(&_state.resetGeneration, 1);
}
- (void)dealloc {
    if (_node) AudioUnitRemoveRenderNotify(_node.audioUnit, applyEnvelope, &_state);
}
@end
