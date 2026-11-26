#include "InstrumentalStream.h"
#include "PCMOutput.h"
#include <AudioToolbox/AudioToolbox.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stddef.h>

#define RING_SIZE (1u << 19)
#define RING_MASK (RING_SIZE - 1)
#define DELAY_SECONDS 8

typedef struct {
    YTMUStereoFrame frame;
    uint64_t position;
    uint32_t generation;
} WetFrame;

static YTMUStereoFrame inputRing[RING_SIZE], dryDelay[RING_SIZE];
static WetFrame outputRing[RING_SIZE];
static _Atomic uint64_t inputWrite, inputRead, inputStart, outputWrite, outputRead;
static _Atomic uint32_t request, active, inputReady, rate, status;
static atomic_bool enabled;
// Multiple AudioUnits can call concurrently. Only the first supported active
// source is admitted. Both ring producers and consumers have a single owner.
static atomic_flag rendering = ATOMIC_FLAG_INIT;
static const void *source;
static uint64_t sourceTime, position;
static _Atomic uint64_t switchAfterTicks;
static float wetGain;
static uint32_t renderGeneration, renderRate;

static void render(const void *identity, const AudioStreamBasicDescription *format,
                   AudioBufferList *buffers, UInt32 count) {
    if (!atomic_load_explicit(&enabled, memory_order_acquire) || !count) return;
    if (atomic_flag_test_and_set_explicit(&rendering, memory_order_acquire)) return;

    const uint64_t now = mach_absolute_time();
    if (source != identity && source && now - sourceTime < atomic_load_explicit(&switchAfterTicks, memory_order_relaxed)) goto done;
    const uint32_t generation = atomic_load_explicit(&request, memory_order_acquire);
    const bool planar = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const bool isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool validEncoding = isFloat ? format->mBitsPerChannel == 32 :
        (format->mBitsPerChannel == 16 && (format->mFormatFlags & kAudioFormatFlagIsSignedInteger));
    const unsigned width = isFloat ? sizeof(float) : sizeof(int16_t);
    if (format->mFormatID != kAudioFormatLinearPCM ||
        (format->mSampleRate != 44100 && format->mSampleRate != 48000) ||
        format->mChannelsPerFrame != 2 || !validEncoding ||
        !(format->mFormatFlags & kAudioFormatFlagIsPacked) ||
        (format->mFormatFlags & kAudioFormatFlagIsBigEndian) ||
        format->mBytesPerFrame != width * (planar ? 1 : 2) ||
        count > 8192 || buffers->mNumberBuffers != (planar ? 2u : 1u)) {
        if (renderGeneration == generation) atomic_fetch_add(&request, 1);
        atomic_store(&status, 4);
        goto done;
    }
    for (unsigned b = 0; b < buffers->mNumberBuffers; ++b) {
        if (!buffers->mBuffers[b].mData ||
            buffers->mBuffers[b].mDataByteSize < count * format->mBytesPerFrame ||
            buffers->mBuffers[b].mNumberChannels != (planar ? 1u : 2u)) goto done;
    }

    if (renderGeneration == generation && (source != identity || renderRate != format->mSampleRate)) {
        // The worker drops the old window when the output route/format changes.
        atomic_fetch_add(&request, 1);
        source = NULL;
        goto done;
    }
    uint64_t write = atomic_load_explicit(&inputWrite, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&outputRead, memory_order_relaxed);
    if (renderGeneration != generation) {
        renderGeneration = generation;
        renderRate = (uint32_t)format->mSampleRate;
        position = 0;
        wetGain = 0;
        read = atomic_load_explicit(&outputWrite, memory_order_acquire);
        atomic_store_explicit(&outputRead, read, memory_order_release);
        atomic_store_explicit(&inputStart, write, memory_order_relaxed);
        atomic_store_explicit(&rate, renderRate, memory_order_relaxed);
        atomic_store_explicit(&active, generation, memory_order_release);
    }
    source = identity;
    sourceTime = now;
    if (atomic_load_explicit(&inputReady, memory_order_acquire) != generation) goto done;

    const uint64_t consumed = atomic_load_explicit(&inputRead, memory_order_acquire);
    if (write + count - consumed > RING_SIZE) {
        // The worker fell behind by a full ring. Restart in passthrough on the next callback.
        atomic_fetch_add(&request, 1);
        atomic_store(&status, 3);
        goto done;
    }
    const uint64_t outputEnd = atomic_load_explicit(&outputWrite, memory_order_acquire);
    const uint64_t delay = (uint64_t)renderRate * DELAY_SECONDS;
    uint32_t result = position < delay ? 1 : 2;
    const unsigned stride = planar ? 1 : 2;
    void *left = buffers->mBuffers[0].mData;
    void *right = planar ? buffers->mBuffers[1].mData : left;
    for (UInt32 i = 0; i < count; ++i, ++position, ++write) {
        const unsigned l = i * stride, r = l + (planar ? 0 : 1);
        YTMUStereoFrame frame;
        if (isFloat) frame = (YTMUStereoFrame){ ((float *)left)[l], ((float *)right)[r] };
        else frame = (YTMUStereoFrame){ ((int16_t *)left)[l] / 32768.0f, ((int16_t *)right)[r] / 32768.0f };
        if (!isfinite(frame.left)) frame.left = 0;
        if (!isfinite(frame.right)) frame.right = 0;
        YTMUStereoFrame output = {0, 0};
        inputRing[write & RING_MASK] = frame;
        dryDelay[position & RING_MASK] = frame;
        if (position >= delay) {
            const uint64_t due = position - delay;
            output = dryDelay[due & RING_MASK];
            while (read < outputEnd) {
                const WetFrame *wet = &outputRing[read & RING_MASK];
                if (wet->generation != generation || wet->position < due) {
                    ++read;
                    continue;
                }
                if (wet->position == due) {
                    wetGain = fminf(1, wetGain + 1.0f / 256);
                    output.left += (wet->frame.left - output.left) * wetGain;
                    output.right += (wet->frame.right - output.right) * wetGain;
                    ++read;
                    goto writeOutput;
                }
                break;
            }
            wetGain = 0;
            result = 3;
        }
writeOutput:
        if (isFloat) {
            ((float *)left)[l] = fmaxf(-1, fminf(1, output.left));
            ((float *)right)[r] = fmaxf(-1, fminf(1, output.right));
        } else {
            ((int16_t *)left)[l] = (int16_t)(output.left >= 1 ? 32767 : output.left <= -1 ? -32768 : output.left * 32768);
            ((int16_t *)right)[r] = (int16_t)(output.right >= 1 ? 32767 : output.right <= -1 ? -32768 : output.right * 32768);
        }
    }
    atomic_store_explicit(&inputWrite, write, memory_order_release);
    atomic_store_explicit(&outputRead, read, memory_order_release);
    atomic_store_explicit(&status, result, memory_order_relaxed);
done:
    atomic_flag_clear_explicit(&rendering, memory_order_release);
}

bool YTMUInstrumentalEnable(void) {
    if (!YTMUInstallPCMOutput(render)) return false;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    atomic_store(&switchAfterTicks, UINT64_C(350000000) * timebase.denom / timebase.numer);
    atomic_fetch_add(&request, 1);
    atomic_store(&status, 1);
    atomic_store_explicit(&enabled, true, memory_order_release);
    return true;
}

void YTMUInstrumentalDisable(void) {
    atomic_store_explicit(&enabled, false, memory_order_release);
    atomic_store(&status, 0);
}

void YTMUInstrumentalReset(void) {
    if (!atomic_load(&enabled)) return;
    atomic_fetch_add(&request, 1);
    atomic_store(&status, 1);
}

YTMUInstrumentalStream YTMUInstrumentalCurrentStream(void) {
    uint32_t generation = atomic_load_explicit(&active, memory_order_acquire);
    if (!atomic_load(&enabled) || generation != atomic_load(&request)) return (YTMUInstrumentalStream){0, 0};
    return (YTMUInstrumentalStream){generation, atomic_load(&rate)};
}

uint32_t YTMUInstrumentalRead(uint32_t generation, YTMUStereoFrame *output, uint32_t count) {
    // The Swift worker is serial. Only it resets the input consumer's cursor.
    if (YTMUInstrumentalCurrentStream().generation != generation) return 0;
    if (atomic_load_explicit(&inputReady, memory_order_relaxed) != generation) {
        atomic_store_explicit(&inputRead, atomic_load(&inputStart), memory_order_relaxed);
        atomic_store_explicit(&inputReady, generation, memory_order_release);
    }
    uint64_t read = atomic_load_explicit(&inputRead, memory_order_relaxed);
    const uint64_t end = atomic_load_explicit(&inputWrite, memory_order_acquire);
    if (end - read < count) count = (uint32_t)(end - read);
    for (uint32_t i = 0; i < count; ++i) output[i] = inputRing[(read + i) & RING_MASK];
    atomic_store_explicit(&inputRead, read + count, memory_order_release);
    return count;
}

uint32_t YTMUInstrumentalWrite(uint32_t generation, const YTMUStereoFrame *input,
                                uint32_t count, uint64_t firstPosition) {
    if (YTMUInstrumentalCurrentStream().generation != generation) return 0;
    uint64_t write = atomic_load_explicit(&outputWrite, memory_order_relaxed);
    const uint64_t maxWrite = atomic_load_explicit(&outputRead, memory_order_acquire) + RING_SIZE;
    if (maxWrite - write < count) count = (uint32_t)(maxWrite - write);
    for (uint32_t i = 0; i < count; ++i) {
        outputRing[(write + i) & RING_MASK] = (WetFrame){input[i], firstPosition + i, generation};
    }
    atomic_store_explicit(&outputWrite, write + count, memory_order_release);
    return count;
}

uint32_t YTMUInstrumentalStatus(void) {
    return atomic_load_explicit(&status, memory_order_relaxed);
}

bool YTMUInstrumentalIsEnabled(void) {
    return atomic_load_explicit(&enabled, memory_order_acquire);
}

void YTMUInstrumentalReportUnsupported(void) {
    if (YTMUInstrumentalIsEnabled() && !YTMUInstrumentalCurrentStream().generation) {
        atomic_store_explicit(&status, 4, memory_order_relaxed);
    }
}
