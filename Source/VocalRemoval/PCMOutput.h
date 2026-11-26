#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>

typedef void (*YTMUPCMProcessor)(const void *, const AudioStreamBasicDescription *, AudioBufferList *, UInt32);
bool YTMUInstallPCMOutput(YTMUPCMProcessor processor);
void YTMUProcessPlaybackPCM(const void *source, const AudioStreamBasicDescription *format,
                             AudioBufferList *buffers, UInt32 frames);
