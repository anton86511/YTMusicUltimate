#pragma once

#import <Foundation/Foundation.h>
#include <stdbool.h>

void YTMUStartVocalRemoval(const char *modelPath, void (^completion)(bool success));
void YTMUStopVocalRemoval(void);
