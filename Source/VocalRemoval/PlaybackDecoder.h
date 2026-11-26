#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

@interface YTMUPlaybackDecoder : NSObject

// The caller owns the returned buffer. It is nil when the original should be used.
- (CMSampleBufferRef)copyPCMFromSample:(CMSampleBufferRef)sample source:(const void *)source CF_RETURNS_RETAINED;

@end
