//
//  TKCoreAudioBridge.h
//  TKCoreAudioBridge
//
//  Created by Tim Kemp on 26/09/2012.
//  Copyright (c) 2012 Tim Kemp. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

@class TKRecording;

@protocol SampleSource <NSObject>
@required

- (OSStatus) generateSamples:(AudioBufferList *) buffers frames:(int) numFrames;

@end

@interface TKCoreAudioBridge : NSObject

@property (nonatomic, retain) id<SampleSource> sampleSource;
@property (readonly) BOOL isPlaying;

+ (TKCoreAudioBridge *) sharedAudioBridge;

- (id) init;
- (void) start;

// Recording
- (void) createRecordingFileWithURL:(NSURL *)url;
- (void) startRecord;
- (void) stopRecord;

// Playback
- (void) setPlaybackURL:(NSURL *) url;
- (void) startPlayback;
- (void) stopPlayback;

@end
