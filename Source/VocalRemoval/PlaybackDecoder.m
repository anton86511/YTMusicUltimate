#import "PlaybackDecoder.h"
#import "PCMOutput.h"
#import "InstrumentalStream.h"
#import <AudioToolbox/AudioToolbox.h>
#import "libavcodec/avcodec.h"
#import "libavutil/channel_layout.h"
#import "libavutil/mem.h"
#include <math.h>
#include <string.h>
#import "libswresample/swresample.h"

enum { MaxPCMFrames = 57600, MaxPackets = 128, MaxPacketBytes = 256 * 1024 };

static enum AVCodecID CodecForFormat(AudioFormatID format) {
    switch (format) {
        case kAudioFormatOpus: return AV_CODEC_ID_OPUS;
        case kAudioFormatMPEG4AAC:
        case kAudioFormatMPEG4AAC_HE:
        case kAudioFormatMPEG4AAC_HE_V2: return AV_CODEC_ID_AAC;
        default: return AV_CODEC_ID_NONE;
    }
}

static NSData *AACConfiguration(const uint8_t *bytes, size_t size) {
    // Core Media can provide either AudioSpecificConfig or an ESDS cookie
    // that wraps it as MPEG-4 descriptor tag 0x05.
    if (size > 1 && size <= 8 && (bytes[0] >> 3) > 0) return [NSData dataWithBytes:bytes length:size];
    for (size_t i = 0; i + 2 < size; ++i) {
        if (bytes[i] != 0x05) continue;
        size_t length = 0, cursor = i + 1;
        for (unsigned part = 0; part < 4 && cursor < size; ++part) {
            uint8_t byte = bytes[cursor++];
            length = (length << 7) | (byte & 0x7F);
            if (!(byte & 0x80)) {
                if (length >= 2 && length <= 16 && length <= size - cursor &&
                    (bytes[cursor] >> 3) > 0) return [NSData dataWithBytes:bytes + cursor length:length];
                break;
            }
        }
    }
    return nil;
}

static NSData *DecoderConfiguration(CMAudioFormatDescriptionRef description, enum AVCodecID codec,
                                     const AudioStreamBasicDescription *format) {
    size_t size = 0;
    const uint8_t *cookie = CMAudioFormatDescriptionGetMagicCookie(description, &size);
    if (codec == AV_CODEC_ID_OPUS) {
        // HAM supplies the leading and trailing trim as sample buffer attachments.
        uint8_t header[19] = {'O','p','u','s','H','e','a','d',1,2,0,0,0x80,0xBB,0,0,0,0,0};
        return [NSData dataWithBytes:header length:sizeof(header)];
    }
    if (cookie && size && size <= 4096) {
        NSData *config = AACConfiguration(cookie, size);
        if (config) return config;
    }
    if (format->mFormatID != kAudioFormatMPEG4AAC) return nil;
    unsigned index = format->mSampleRate == 48000 ? 3 : 4;
    uint8_t config[2] = {(uint8_t)((2 << 3) | (index >> 1)),
                         (uint8_t)(((index & 1) << 7) | (2 << 3))};
    return [NSData dataWithBytes:config length:sizeof(config)];
}

static void CopyAttachments(CMSampleBufferRef original, CMSampleBufferRef output) {
    for (CMAttachmentMode mode = kCMAttachmentMode_ShouldNotPropagate;
         mode <= kCMAttachmentMode_ShouldPropagate; ++mode) {
        CFDictionaryRef values = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, original, mode);
        if (values) {
            CMSetAttachments(output, values, mode);
            CFRelease(values);
        }
    }
}

@implementation YTMUPlaybackDecoder {
    CMAudioFormatDescriptionRef compressedFormat;
    CMAudioFormatDescriptionRef pcmDescription;
    AVCodecContext *decoder;
    AVFrame *decoded;
    NSMutableData *pcmStorage;
    SwrContext *resampler;
    int inputRate;
    int inputFormat;
    uint64_t inputLayout;
    CMTime previousEnd;
    AudioStreamBasicDescription pcmFormat;
}

- (void)dealloc {
    if (compressedFormat) CFRelease(compressedFormat);
    if (pcmDescription) CFRelease(pcmDescription);
    avcodec_free_context(&decoder);
    av_frame_free(&decoded);
    swr_free(&resampler);
}

- (BOOL)configureForFormat:(CMAudioFormatDescriptionRef)description {
    if (compressedFormat && CFEqual(compressedFormat, description)) return decoder != NULL;
    avcodec_free_context(&decoder);
    av_frame_free(&decoded);
    swr_free(&resampler);
    if (compressedFormat) CFRelease(compressedFormat);
    if (pcmDescription) CFRelease(pcmDescription);
    pcmDescription = NULL;
    compressedFormat = CFRetain(description);
    previousEnd = kCMTimeInvalid;

    const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(description);
    if (!format || format->mChannelsPerFrame != 2 ||
        (format->mSampleRate != 44100 && format->mSampleRate != 48000)) return NO;
    enum AVCodecID codecID = CodecForFormat(format->mFormatID);
    if (codecID == AV_CODEC_ID_NONE) return NO;
    const AVCodec *codec = avcodec_find_decoder(codecID);
    NSData *configuration = DecoderConfiguration(description, codecID, format);
    if (!codec || !configuration.length) return NO;

    AVCodecContext *context = avcodec_alloc_context3(codec);
    if (!context) return NO;
    context->sample_rate = codecID == AV_CODEC_ID_OPUS ? 48000 : (int)format->mSampleRate;
    context->channels = 2;
    context->channel_layout = AV_CH_LAYOUT_STEREO;
    context->extradata = av_mallocz(configuration.length + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!context->extradata) {
        avcodec_free_context(&context);
        return NO;
    }
    memcpy(context->extradata, configuration.bytes, configuration.length);
    context->extradata_size = (int)configuration.length;
    if (avcodec_open2(context, codec, NULL) < 0) {
        avcodec_free_context(&context);
        return NO;
    }
    pcmFormat = (AudioStreamBasicDescription){
        context->sample_rate, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
        2 * sizeof(float), 1, 2 * sizeof(float), 2, 32, 0
    };
    decoded = av_frame_alloc();
    if (!decoded || CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &pcmFormat, 0, NULL,
                0, NULL, NULL, &pcmDescription) != noErr) {
        av_frame_free(&decoded);
        avcodec_free_context(&context);
        return NO;
    }
    decoder = context;
    return YES;
}

- (int)appendDecodedFrames:(float *)samples capacity:(int)capacity {
    int total = 0;
    while (total < capacity) {
        int status = avcodec_receive_frame(decoder, decoded);
        if (status == AVERROR(EAGAIN) || status == AVERROR_EOF) return total;
        if (status < 0 || decoded->channels != 2 || decoded->sample_rate <= 0) return -1;
        uint64_t layout = decoded->channel_layout ?: AV_CH_LAYOUT_STEREO;
        if (!resampler || decoded->sample_rate != inputRate || decoded->format != inputFormat || layout != inputLayout) {
            swr_free(&resampler);
            inputRate = decoded->sample_rate;
            inputFormat = decoded->format;
            inputLayout = layout;
            resampler = swr_alloc_set_opts(NULL, AV_CH_LAYOUT_STEREO, AV_SAMPLE_FMT_FLT, (int)pcmFormat.mSampleRate,
                                           layout, decoded->format, inputRate, 0, NULL);
            if (!resampler || swr_init(resampler) < 0) {
                swr_free(&resampler);
                return -1;
            }
        }
        uint8_t *out = (uint8_t *)(samples + total * 2);
        int converted = swr_convert(resampler, &out, capacity - total,
                                    (const uint8_t **)decoded->extended_data, decoded->nb_samples);
        av_frame_unref(decoded);
        if (converted < 0) return -1;
        total += converted;
    }
    return total;
}

- (CMSampleBufferRef)copyPCMFromSample:(CMSampleBufferRef)sample source:(const void *)source {
    CMAudioFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sample);
    if (!description || ![self configureForFormat:description]) return NULL;
    CMBlockBufferRef data = CMSampleBufferGetDataBuffer(sample);
    CMItemCount count = CMSampleBufferGetNumSamples(sample);
    CMTime time = CMSampleBufferGetPresentationTimeStamp(sample);
    if (!data || count < 1 || count > MaxPackets || !CMTIME_IS_NUMERIC(time)) return NULL;

    if (CMTIME_IS_NUMERIC(previousEnd) && fabs(CMTimeGetSeconds(CMTimeSubtract(time, previousEnd))) > 0.30) {
        avcodec_flush_buffers(decoder);
        swr_free(&resampler);
    }

    const AudioStreamPacketDescription *packets = NULL;
    size_t packetBytes = 0, totalSize = CMBlockBufferGetDataLength(data);
    CMSampleBufferGetAudioStreamPacketDescriptionsPtr(sample, &packets, &packetBytes);
    if (totalSize == 0 || totalSize > MaxPacketBytes || (packets && packetBytes / sizeof(*packets) < (size_t)count)) return NULL;

    if (!pcmStorage) pcmStorage = [NSMutableData dataWithLength:MaxPCMFrames * pcmFormat.mBytesPerFrame];
    float *samples = pcmStorage.mutableBytes;
    size_t offset = 0;
    int processed = 0;
    for (CMItemCount i = 0; i < count; ++i) {
        size_t length = packets ? packets[i].mDataByteSize : CMSampleBufferGetSampleSize(sample, i);
        if (packets) {
            if (packets[i].mStartOffset < 0) return NULL;
            offset = (size_t)packets[i].mStartOffset;
        } else if (count == 1 && length == 0) {
            length = totalSize;
        }
        if (!length || offset > totalSize || length > totalSize - offset) return NULL;
        AVPacket packet = {0};
        if (av_new_packet(&packet, (int)length) < 0) return NULL;
        OSStatus copied = CMBlockBufferCopyDataBytes(data, offset, length, packet.data);
        int sent = copied == noErr ? avcodec_send_packet(decoder, &packet) : -1;
        av_packet_unref(&packet);
        if (sent < 0) return NULL;
        int frames = [self appendDecodedFrames:samples + processed * 2 capacity:MaxPCMFrames - processed];
        if (frames < 0) return NULL;
        processed += frames;
        offset += length;
    }
    if (!processed || processed >= MaxPCMFrames) return NULL;

    previousEnd = CMTimeAdd(time, CMSampleBufferGetDuration(sample));
    if (!CMTIME_IS_NUMERIC(previousEnd)) {
        previousEnd = CMTimeAdd(time, CMTimeMake(processed, (int32_t)pcmFormat.mSampleRate));
    }

    UInt32 byteCount = processed * pcmFormat.mBytesPerFrame;
    for (UInt32 start = 0; start < (UInt32)processed; start += 8192) {
        UInt32 frames = MIN(8192, (UInt32)processed - start);
        AudioBufferList list = {1, {{2, frames * pcmFormat.mBytesPerFrame, samples + 2 * start}}};
        YTMUProcessPlaybackPCM(source, &pcmFormat, &list, frames);
    }

    CMBlockBufferRef block = NULL;
    CMSampleBufferRef output = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, byteCount,
        kCFAllocatorDefault, NULL, 0, byteCount, kCMBlockBufferAssureMemoryNowFlag, &block);
    if (status == noErr) status = CMBlockBufferReplaceDataBytes(samples, block, 0, byteCount);
    if (status == noErr) status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault,
        block, pcmDescription, processed, time, NULL, &output);
    if (block) CFRelease(block);
    if (output) CopyAttachments(sample, output);
    return output;
}

@end
