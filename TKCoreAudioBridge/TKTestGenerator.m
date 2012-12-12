//
//  TKTestGenerator.m
//  TKCoreAudioBridge
//
//  Created by Tim Kemp on 12/12/2012.
//  Copyright (c) 2012 Tim Kemp. All rights reserved.
//

#import "TKTestGenerator.h"

@implementation TKTestGenerator
{
    SInt16 *tmpBuf;
}

- (id)init
{
    self = [super init];
    if (self) {
        tmpBuf = calloc(4096 * 2, sizeof(SInt16)); // 2 channels, iOS background latency, 16 bit integer samples
        memset(&tmpBuf, 0, sizeof(tmpBuf));
    }
    return self;
}

- (OSStatus) generateSamples:(AudioBufferList *)buffers frames:(int)numFrames
{
    
    return noErr;
}

- (void) dealloc
{
    free(tmpBuf);
}

@end
