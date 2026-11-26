#import "PCMOutput.h"
#import "InstrumentalStream.h"
#import <dlfcn.h>
#import <pthread.h>
#import <stdatomic.h>

typedef OSStatus (*SetUnitProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                                   AudioUnitElement, const void *, UInt32);

typedef struct {
    AudioUnit unit;
    AudioUnitElement bus;
    AURenderCallbackStruct original;
    _Atomic(const AudioStreamBasicDescription *) format;
} OutputContext;

static pthread_mutex_t setupLock = PTHREAD_MUTEX_INITIALIZER;
static OutputContext contexts[96];
static AudioStreamBasicDescription formats[384];
static size_t contextCount, formatCount;
static SetUnitProperty setUnitProperty;
static _Atomic(YTMUPCMProcessor) processPCM;

static void ResolveAudioToolbox(void) {
    void *library = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
                           RTLD_NOW | RTLD_LOCAL);
    if (library) setUnitProperty = (SetUnitProperty)dlsym(library, "AudioUnitSetProperty");
}

bool YTMUInstallPCMOutput(YTMUPCMProcessor processor) {
    atomic_store_explicit(&processPCM, processor, memory_order_release);
    return processor != NULL;
}

void YTMUProcessPlaybackPCM(const void *source, const AudioStreamBasicDescription *format,
                             AudioBufferList *buffers, UInt32 frames) {
    YTMUPCMProcessor processor = atomic_load_explicit(&processPCM, memory_order_acquire);
    if (processor) processor(source, format, buffers, frames);
}

static void UpdateFormat(OutputContext *context) {
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    if (AudioUnitGetProperty(context->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                             context->bus, &format, &size) != noErr || size != sizeof(format)) return;
    const AudioStreamBasicDescription *current = atomic_load_explicit(&context->format, memory_order_acquire);
    if (current && memcmp(current, &format, sizeof(format)) == 0) return;
    if (formatCount >= sizeof(formats) / sizeof(*formats)) {
        atomic_store_explicit(&context->format, NULL, memory_order_release);
        return;
    }
    formats[formatCount] = format;
    atomic_store_explicit(&context->format, &formats[formatCount++], memory_order_release);
}

static OSStatus OutputCallback(void *reference, AudioUnitRenderActionFlags *flags,
                               const AudioTimeStamp *timestamp, UInt32 bus,
                               UInt32 frames, AudioBufferList *data) {
    OutputContext *context = reference;
    OSStatus result = context->original.inputProc(context->original.inputProcRefCon,
                                                 flags, timestamp, bus, frames, data);
    const AudioStreamBasicDescription *format = atomic_load_explicit(&context->format, memory_order_acquire);
    if (result == noErr && data && format && frames) {
        YTMUProcessPlaybackPCM(context, format, data, frames);
        if (flags && YTMUInstrumentalIsEnabled()) *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
    }
    return result;
}

static bool IsPlaybackUnit(AudioUnit unit) {
    AudioComponentDescription description = {0};
    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    return component && AudioComponentGetDescription(component, &description) == noErr
        && description.componentType == kAudioUnitType_Output;
}

// The sideloading workflow binds this single import in the appʼs own executable.
// Calls inside AudioToolbox and other frameworks still use the system implementation.
__attribute__((visibility("default")))
OSStatus AudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
                              AudioUnitElement element, const void *data, UInt32 size) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, ResolveAudioToolbox);
    if (!setUnitProperty || setUnitProperty == AudioUnitSetProperty) return kAudio_ParamError;

    if (property == kAudioUnitProperty_SetRenderCallback && element == 0 &&
        (scope == kAudioUnitScope_Input || scope == kAudioUnitScope_Global) &&
        data && size == sizeof(AURenderCallbackStruct) && IsPlaybackUnit(unit)) {
        const AURenderCallbackStruct *original = data;
        if (original->inputProc) {
            pthread_mutex_lock(&setupLock);
            if (contextCount < sizeof(contexts) / sizeof(*contexts)) {
                // Published callback references stay valid even across callback replacement.
                OutputContext *context = &contexts[contextCount++];
                context->unit = unit;
                context->bus = element;
                context->original = *original;
                UpdateFormat(context);
                pthread_mutex_unlock(&setupLock);
                AURenderCallbackStruct callback = {OutputCallback, context};
                return setUnitProperty(unit, property, scope, element, &callback, sizeof(callback));
            }
            pthread_mutex_unlock(&setupLock);
        }
    }
    OSStatus result = setUnitProperty(unit, property, scope, element, data, size);
    if (result == noErr && property == kAudioUnitProperty_StreamFormat && scope == kAudioUnitScope_Input) {
        pthread_mutex_lock(&setupLock);
        for (size_t i = contextCount; i > 0; --i) {
            OutputContext *context = &contexts[i - 1];
            if (context->unit == unit && context->bus == element) {
                UpdateFormat(context);
                break;
            }
        }
        pthread_mutex_unlock(&setupLock);
    }
    return result;
}
