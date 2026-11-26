#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import "PlaybackDecoder.h"
#import "InstrumentalStream.h"
#import "PCMOutput.h"
#import "../Headers/YTPlayerViewController.h"

@interface HAMSBARAudioTrackRenderer : NSObject
@end

static _Thread_local BOOL inMusicRenderer;
static char decoderKey;

static void CopyEnqueue(id renderer, CMSampleBufferRef sample, IMP original) {
    BOOL wasMusicRenderer = inMusicRenderer;
    inMusicRenderer = NO;
    ((void (*)(id, SEL, CMSampleBufferRef))original)(renderer, @selector(enqueueSampleBuffer:), sample);
    inMusicRenderer = wasMusicRenderer;
}

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
    if (result == noErr) result = CMSampleBufferSetDataReady(copy);
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
    }
    if (copyData) CFRelease(copyData);
    if (result == noErr) return copy;
    if (copy) CFRelease(copy);
    return NULL;
}

static CMSampleBufferRef CopyProcessedSample(id renderer, CMSampleBufferRef sample) {
    if (!inMusicRenderer || !YTMUInstrumentalIsEnabled() || !sample || !CMSampleBufferDataIsReady(sample)) return NULL;
    const void *source = (__bridge const void *)renderer;
    CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sample);
    if (!description || CMFormatDescriptionGetMediaType(description) != kCMMediaType_Audio) return NULL;
    const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(description);
    if (!format) return NULL;
    CMSampleBufferRef result = NULL;
    if (format->mFormatID == kAudioFormatLinearPCM) {
        result = CopyPlaybackPCM(sample, source);
    } else {
        YTMUPlaybackDecoder *decoder = objc_getAssociatedObject(renderer, &decoderKey);
        if (!decoder) {
            decoder = [YTMUPlaybackDecoder new];
            objc_setAssociatedObject(renderer, &decoderKey, decoder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        result = [decoder copyPCMFromSample:sample source:source];
    }
    if (!result) YTMUInstrumentalReportUnsupported();
    return result;
}

static void InstallRendererHook(id renderer) {
    Class cls = object_getClass(renderer);
    if (!cls) return;
    static char installedKey;
    if (objc_getAssociatedObject(cls, &installedKey)) return;
    @synchronized (cls) {
        if (objc_getAssociatedObject(cls, &installedKey)) return;
        SEL selector = @selector(enqueueSampleBuffer:);
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) return;
        IMP original = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^(id target, CMSampleBufferRef sample) {
            CMSampleBufferRef copy = CopyProcessedSample(target, sample);
            CopyEnqueue(target, copy ?: sample, original);
            if (copy) CFRelease(copy);
        });
        class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
        objc_setAssociatedObject(cls, &installedKey, @YES, OBJC_ASSOCIATION_RETAIN);
    }
}

%hook HAMSBARAudioTrackRenderer

- (void)enqueueSampleBuffer:(id)sample {
    BOOL previous = inMusicRenderer;
    inMusicRenderer = YES;
    if (YTMUInstrumentalIsEnabled()) {
        Ivar rendererIvar = class_getInstanceVariable(object_getClass(self), "_renderer");
        if (rendererIvar) InstallRendererHook(object_getIvar(self, rendererIvar));
    }
    %orig;
    inMusicRenderer = previous;
}

- (void)flush {
    Ivar rendererIvar = class_getInstanceVariable(object_getClass(self), "_renderer");
    id renderer = rendererIvar ? object_getIvar(self, rendererIvar) : nil;
    if (renderer) objc_setAssociatedObject(renderer, &decoderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTMUInstrumentalReset();
    %orig;
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
