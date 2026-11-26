#import <CoreMedia/CoreMedia.h>
#import "InstrumentalStream.h"
#import "PCMOutput.h"
#import "../Headers/YTPlayerViewController.h"

@interface HAMSBARAudioTrackRenderer : NSObject
@end

// HAM's sample buffer renderer can own its audio output inside AVFoundation.
// Copy linear PCM before processing so upstream shared buffers stay intact.
static CMSampleBufferRef CopyPlaybackPCM(CMSampleBufferRef sample, const void *source) {
    if (!sample || !YTMUInstrumentalIsEnabled() || !CMSampleBufferDataIsReady(sample)) return NULL;
    CMFormatDescriptionRef desc = CMSampleBufferGetFormatDescription(sample);
    if (!desc || CMFormatDescriptionGetMediaType(desc) != kCMMediaType_Audio) return NULL;
    const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(desc);
    CMItemCount frames = CMSampleBufferGetNumSamples(sample);
    if (!format || format->mFormatID != kAudioFormatLinearPCM ||
        format->mChannelsPerFrame != 2 || frames < 1 || frames > 8192) return NULL;

    struct { AudioBufferList list; AudioBuffer extra; } storage = {0};
    CMBlockBufferRef retained = NULL;
    if (CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, NULL, &storage.list,
            sizeof(storage), NULL, NULL, kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            &retained) != noErr) return NULL;

    // SetDataBufferFromAudioBufferList copies the samples into an independent block.
    CMSampleBufferRef copy = NULL;
    CMSampleTimingInfo time = {0};
    OSStatus result = CMSampleBufferGetSampleTimingInfo(sample, 0, &time);
    if (result == noErr) result = CMSampleBufferCreate(kCFAllocatorDefault, NULL, false,
        NULL, NULL, desc, frames, 1, &time, 0, NULL, &copy);
    if (result == noErr) result = CMSampleBufferSetDataBufferFromAudioBufferList(copy,
        kCFAllocatorDefault, kCFAllocatorDefault, kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        &storage.list);
    if (retained) CFRelease(retained);

    CMBlockBufferRef copyData = NULL;
    if (result == noErr) result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(copy,
        NULL, &storage.list, sizeof(storage), NULL, NULL, 0, &copyData);
    if (result == noErr) {
        YTMUProcessPlaybackPCM(source, format, &storage.list, (UInt32)frames);
        for (NSNumber *mode in @[@(kCMAttachmentMode_ShouldPropagate), @(kCMAttachmentMode_ShouldNotPropagate)]) {
            CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sample, mode.unsignedIntValue);
            if (attachments) {
                CMSetAttachments(copy, attachments, mode.unsignedIntValue);
                CFRelease(attachments);
            }
        }
        result = CMSampleBufferSetDataReady(copy);
    }
    if (copyData) CFRelease(copyData);
    if (result == noErr) return copy;
    if (copy) CFRelease(copy);
    return NULL;
}

%hook HAMSBARAudioTrackRenderer

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sample {
    CMSampleBufferRef copy = CopyPlaybackPCM(sample, (__bridge const void *)self);
    %orig(copy ?: sample);
    if (copy) CFRelease(copy);
}

- (void)flush {
    %orig;
    YTMUInstrumentalReset();
}

%end

%hook YTPlayerViewController

- (void)playbackController:(id)controller didActivateVideo:(id)video withPlaybackData:(id)data {
    YTMUInstrumentalReset();
    %orig;
}

- (void)seekToTime:(CGFloat)time {
    YTMUInstrumentalReset();
    %orig;
}

%end
