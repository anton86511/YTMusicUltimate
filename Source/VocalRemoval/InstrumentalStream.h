#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    float left;
    float right;
} YTMUStereoFrame;

typedef struct {
    uint32_t generation;
    uint32_t sampleRate;
} YTMUInstrumentalStream;

bool YTMUInstrumentalEnable(void);
void YTMUInstrumentalDisable(void);
void YTMUInstrumentalReset(void);
YTMUInstrumentalStream YTMUInstrumentalCurrentStream(void);
uint32_t YTMUInstrumentalRead(uint32_t generation, YTMUStereoFrame *output, uint32_t count);
uint32_t YTMUInstrumentalWrite(uint32_t generation, const YTMUStereoFrame *input,
                                 uint32_t count, uint64_t position);
uint32_t YTMUInstrumentalStatus(void);
bool YTMUInstrumentalIsEnabled(void);
void YTMUInstrumentalReportUnsupported(void);
