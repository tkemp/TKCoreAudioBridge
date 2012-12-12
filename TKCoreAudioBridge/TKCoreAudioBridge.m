//
//  TKCoreAudioBridge.m
//  Cellular
//
//  Created by Tim Kemp on 26/09/2012.
//  Copyright (c) 2012 Liminal Dynamics. All rights reserved.
//

#import <AudioToolbox/AudioToolbox.h>
#import "TKCoreAudioBridge.h"

// Buses - makes life easier when we're plugging things in in the AUGraph
#define BUS_MIXER_INPUT_SYNTH 0
#define BUS_MIXER_INPUT_PLAYER 1
#define BUS_MIXER_OUTPUT 0
#define BUS_PLAYER_OUTPUT 0
#define BUS_REMOTEIO_OUTPUT 0

#pragma mark C-style declarations for callbacks in a class extension
@interface TKCoreAudioBridge ()

OSStatus generatorRenderCallback(void                       *inRefCon,
                                 AudioUnitRenderActionFlags *ioActionFlags,
                                 const AudioTimeStamp       *inTimeStamp,
                                 UInt32                     inBusNumber,
                                 UInt32                     inNumberFrames,
                                 AudioBufferList            *ioData);
OSStatus playRenderNotify(void                        *inRefCon,
                          AudioUnitRenderActionFlags  *ioActionFlags,
                          const AudioTimeStamp        *inTimeStamp,
                          UInt32                      inBusNumber,
                          UInt32                      inNumberFrames,
                          AudioBufferList             *ioData);
OSStatus recordRenderNotify(void                        *inRefCon,
                            AudioUnitRenderActionFlags  *ioActionFlags,
                            const AudioTimeStamp        *inTimeStamp,
                            UInt32                      inBusNumber,
                            UInt32                      inNumberFrames,
                            AudioBufferList             *ioData);

OSStatus checkError(OSStatus error, const char *operation, bool shouldExit);
void checkErrorAndExit(OSStatus error, const char *operation);
- (OSStatus) getGeneratedSamples:(AudioBufferList *) ioData frames:(UInt32) numFrames;

@end

#pragma mark 'Info' structs used as inRefCons to the render notify callbacks
typedef struct RecordingInfo {
    bool isRecording;
    ExtAudioFileRef fileRef;
} RecordingInfo;

typedef struct PlaybackInfo {
    bool isPlaying;
    long framesPlayed;
    ScheduledAudioFileRegion region;
    ExtAudioFileRef fileRef;
    __unsafe_unretained TKCoreAudioBridge *cab;
} PlaybackInfo;

#pragma mark Start of implementation proper
@implementation TKCoreAudioBridge
{
    id<SampleSource> _sampleSource;
    AudioStreamBasicDescription _outputASBD;   // Stream format for the application
    AudioStreamBasicDescription _playerASBD;   // Stream format for the file player
    AudioUnit                   _playerUnit;   // Plays back recordings
    AudioUnit                   _mixerUnit;    // Mixes played recordings with live synth audio. Synth is a render callback on one of the input buses
    AudioUnit                   _outputUnit;   // Sends sound to the speakers/jack/interface
    AUGraph                     _graph;
    
    // Recording stuff
    RecordingInfo _curRecording;
    PlaybackInfo  _curPlayback;                // Or make an array of these for more than one file player
    AudioStreamBasicDescription _recorderASBD; // Stream format for the recorder
}
@synthesize sampleSource = _sampleSource;

static TKCoreAudioBridge * sharedBridge = nil;

- (id) init
{
    self = [super init];
    if (self) {
        // Set desired audio output format as the device wants
        memset(&_outputASBD, 0, sizeof(_outputASBD));
        _outputASBD.mSampleRate        = 44100.0;
        _outputASBD.mFormatID          = kAudioFormatLinearPCM;
        _outputASBD.mFormatFlags       = kAudioFormatFlagsCanonical;    // On iOS, equivalent to kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
        _outputASBD.mBytesPerPacket    = 2 * 2;
        _outputASBD.mBytesPerFrame     = 2 * 2;
        _outputASBD.mFramesPerPacket   = 1;
        _outputASBD.mChannelsPerFrame  = 2;
        _outputASBD.mBitsPerChannel    = 16;
        
        // Set recording format for CAF lpcm
        memset(&_recorderASBD, 0, sizeof(_recorderASBD));
        _recorderASBD.mSampleRate          = 44100.00;
        _recorderASBD.mFormatID            = kAudioFormatLinearPCM;
        _recorderASBD.mFormatFlags         = kAudioFormatFlagsCanonical;// On iOS, equivalent to kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsPacked;
        _recorderASBD.mBytesPerPacket      = 2 * 2;
        _recorderASBD.mBytesPerFrame       = 2 * 2;
        _recorderASBD.mFramesPerPacket     = 1;
        _recorderASBD.mChannelsPerFrame    = 2;
        _recorderASBD.mBitsPerChannel      = 16;
        
        // Zero the player format, since it'll be set by the player itself later
        memset(&_playerASBD, 0, sizeof(_playerASBD));
        
        // Clear out the info structs ready for use
        _curRecording.isRecording = NO;
        _curPlayback.isPlaying = NO;
        _curPlayback.cab = self;
        memset(&_curPlayback.region, 0, sizeof(_curPlayback.region));
    }
    
    return self;
}

#pragma mark Chris Adamson's error prettifier
OSStatus checkError(OSStatus error, const char *operation, bool shouldExit)
{
    if (error == noErr)
        return noErr;
    
    char errorString[20];
    // Is it a 4 character code?
    *(UInt32 *)(errorString + 1) = CFSwapInt32HostToBig(error);
    if (isprint(errorString[1]) && isprint(errorString[2]) && isprint(errorString[3]) && isprint(errorString[4])) {
        errorString[0] = errorString[5] = '\'';
        errorString[6] = '\0';
    } else { // No, format as integer
        sprintf(errorString, "%d", (int)error);
    }
    
    NSLog([NSString stringWithFormat:@"Error in CoreAudio bridge: %s (%s)", operation, errorString]);
    
    if (shouldExit)
        exit(error);
    else
        return error;
}

void checkErrorAndExit(OSStatus error, const char *operation)
{
    checkError(error, operation, true);
}

#pragma mark Graph setup
- (void) createAUGraph
{
    // Create the graph
    checkErrorAndExit(NewAUGraph(&_graph),
                      "NewAUGraph failed");
    
    // Create the default output node description
    AudioComponentDescription outputDesc = { 0 };
    outputDesc.componentType = kAudioUnitType_Output;
    outputDesc.componentSubType = kAudioUnitSubType_RemoteIO;
    outputDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    // Create the mixer node description
    AudioComponentDescription mixerDesc = { 0 };
    mixerDesc.componentType = kAudioUnitType_Mixer;
    mixerDesc.componentSubType = kAudioUnitSubType_MultiChannelMixer;
    mixerDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    // Create the file player node description
    AudioComponentDescription playerDesc = { 0 };
    playerDesc.componentType = kAudioUnitType_Generator;
    playerDesc.componentSubType = kAudioUnitSubType_AudioFilePlayer;
    playerDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    // Add the nodes
    AUNode outputNode, mixerNode, playerNode;
    checkErrorAndExit(AUGraphAddNode(_graph,
                                     &outputDesc,
                                     &outputNode),
                      "AUGraphAddNode failed: adding output node");
    checkErrorAndExit(AUGraphAddNode(_graph,
                                     &mixerDesc,
                                     &mixerNode),
                      "AUGraphAddNode failed: adding synth node");
    checkErrorAndExit(AUGraphAddNode(_graph,
                                     &playerDesc,
                                     &playerNode),
                      "AUGraphAddNode failed: adding player node");
    
    // Open the graph
    checkErrorAndExit(AUGraphOpen(_graph),
                      "AUGraphOpen failed");
    
    // Get the mixer AU
    checkErrorAndExit(AUGraphNodeInfo(_graph,
                                      mixerNode,
                                      NULL,
                                      &_mixerUnit),
                      "AUGraphNodeInfo failed: getting synth unit");
    
    // Get the output AU
    checkErrorAndExit(AUGraphNodeInfo(_graph,
                                      outputNode,
                                      NULL,
                                      &_outputUnit),
                      "AUGraphNodeInfo failed: getting output unit");
    
    // Get the player AU
    checkErrorAndExit(AUGraphNodeInfo(_graph,
                                      playerNode,
                                      NULL,
                                      &_playerUnit),
                      "AUGraphNodeInfo failed: getting player unit");
    
    // Get the ASBD from the player unit, update with channels
    UInt32 playerASBDsize;
    checkError(AudioUnitGetProperty(_playerUnit,
                                    kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Output,
                                    BUS_PLAYER_OUTPUT,
                                    &_playerASBD,
                                    &playerASBDsize),
               "AudioUnitSetProperty failed: getting stream format from the player unit", false);
    _playerASBD.mChannelsPerFrame = 2;
    _playerASBD.mSampleRate = 44100.0;
    checkError(AudioUnitSetProperty(_playerUnit,
                                    kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Output,
                                    BUS_PLAYER_OUTPUT,
                                    &_playerASBD,
                                    sizeof(_playerASBD)),
               "AudioUnitSetProperty failed: setting channels & sample rate to player output ASBD", false);
    
    // Set ASBD on the mixer unit
    checkError(AudioUnitSetProperty(_mixerUnit,
                                    kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Input,
                                    BUS_MIXER_INPUT_SYNTH,
                                    &_outputASBD,
                                    sizeof(_outputASBD)),
               "AudioUnitSetProperty failed: setting stream format on input of mixer unit", false);
    
    checkError(AudioUnitSetProperty(_mixerUnit,
                                    kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Output,
                                    BUS_MIXER_OUTPUT,
                                    &_outputASBD,
                                    sizeof(_outputASBD)),
               "AudioUnitSetProperty failed: setting stream format on output of mixer unit", false);
    
    // Set the number of inputs on the mixer
    UInt32 numMixerInputs = 2;
    checkError(AudioUnitSetProperty(_mixerUnit,
                                    kAudioUnitProperty_ElementCount,
                                    kAudioUnitScope_Input,
                                    0,
                                    &numMixerInputs,
                                    sizeof(numMixerInputs)),
               "AudioUnitSetProperty failed: setting number of mixer inputs", false);
    
    // Set ASBD on the output unit
    checkError(AudioUnitSetProperty(_outputUnit,
                                    kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Input,
                                    BUS_REMOTEIO_OUTPUT,
                                    &_outputASBD,
                                    sizeof(_outputASBD)),
               "AudioUnitSetProperty failed: setting stream format on input of output unit", false);
    
    // Add callback to the mixer unit
    AURenderCallbackStruct callback;
    callback.inputProc = &generatorRenderCallback;
    callback.inputProcRefCon = (__bridge void *) self;
    checkErrorAndExit(AudioUnitSetProperty(_mixerUnit,
                                           kAudioUnitProperty_SetRenderCallback,
                                           kAudioUnitScope_Input,
                                           BUS_MIXER_INPUT_SYNTH,
                                           &callback,
                                           sizeof(callback)),
                      "AudioUnitSetProperty failed: setting the render callback on the mixer unit");
    
    // Enable output on the output unit
    UInt32 outputEnableFlag = 1;
    checkErrorAndExit(AudioUnitSetProperty(_outputUnit,
                                           kAudioOutputUnitProperty_EnableIO,
                                           kAudioUnitScope_Output,
                                           BUS_REMOTEIO_OUTPUT,
                                           &outputEnableFlag,
                                           sizeof(outputEnableFlag)),
                      "AudioUnitSetProperty failed: enabling output on RemoteIO unit");
    
    // Connect the nodes
    checkErrorAndExit(AUGraphConnectNodeInput(_graph,
                                              mixerNode,
                                              BUS_MIXER_OUTPUT,
                                              outputNode,
                                              BUS_REMOTEIO_OUTPUT),
                      "AUGraphConnectNodeInput failed: connecting synth to output");
    checkErrorAndExit(AUGraphConnectNodeInput(_graph,
                                              playerNode,
                                              BUS_PLAYER_OUTPUT,
                                              mixerNode,
                                              BUS_MIXER_INPUT_PLAYER),
                      "AUGraphConnectNodeInput failed: connecting player to mixer");
    
    // Set mixer levels
    checkError(AudioUnitSetParameter(_mixerUnit,
                                     kMultiChannelMixerParam_Volume,
                                     kAudioUnitScope_Input,
                                     BUS_MIXER_INPUT_PLAYER,
                                     1.0,
                                     0),
               "AudioUnitSetParameter failed: setting mixer level for PLAYER INPUT", false);
    checkError(AudioUnitSetParameter(_mixerUnit,
                                     kMultiChannelMixerParam_Volume,
                                     kAudioUnitScope_Input,
                                     BUS_MIXER_INPUT_SYNTH,
                                     1.0,
                                     0),
               "AudioUnitSetParameter failed: setting mixer level for PLAYER INPUT", false);
    checkError(AudioUnitSetParameter(_mixerUnit,
                                     kMultiChannelMixerParam_Volume,
                                     kAudioUnitScope_Output,
                                     BUS_MIXER_OUTPUT,
                                     1.0,
                                     0),
               "AudioUnitSetParameter failed: setting mixer level for PLAYER INPUT", false);
    checkError(AudioUnitSetParameter(_mixerUnit,
                                     kMultiChannelMixerParam_Enable,
                                     kAudioUnitScope_Input,
                                     BUS_MIXER_INPUT_PLAYER,
                                     1,
                                     0),
               "AudioUnitSetParameter failed: setting mixer enabled for PLAYER INPUT", false);
    
    // Initialize the graph
    checkErrorAndExit(AUGraphInitialize(_graph),
                      "AUGraphInitialize failed");
}

// Builds and then the AUGraph
- (void) start
{
    [self createAUGraph];
    checkErrorAndExit(AUGraphStart(_graph),
                      "AUGraphStart failed");
}

// Stops and then tears down the graph
- (void) stop
{
    checkErrorAndExit(AUGraphStop(_graph),
                      "AUGraphStop failed");
    checkErrorAndExit(AUGraphUninitialize(_graph),
                      "AUGraphUninitialize failed");
    checkErrorAndExit(AUGraphClose(_graph),
                      "AUGraphClose failed");
}

#pragma mark Render callback
/*
 This looks like (and is) an extra step between the render callback and the 
 sample generation code. It's here in case there's a need for additional processing in ObjC- land or access to other properties of the CoreAudioBridge.
 If you don't need it, feel free to pass in the _sampleSource ivar to inRefCon instead.
 */
OSStatus generatorRenderCallback(void                       *inRefCon,
                                 AudioUnitRenderActionFlags *ioActionFlags,
                                 const AudioTimeStamp       *inTimeStamp,
                                 UInt32                     inBusNumber,
                                 UInt32                     inNumberFrames,
                                 AudioBufferList            *ioData)
{
    TKCoreAudioBridge *cab = (__bridge TKCoreAudioBridge *) inRefCon;
    return [cab getGeneratedSamples:ioData frames:inNumberFrames];
}

- (OSStatus) getGeneratedSamples:(AudioBufferList *) ioData frames:(UInt32) numFrames
{
    OSStatus result = [_sampleSource generateSamples:ioData frames:numFrames];
    return result;
}

#pragma mark Recording
/** Uses Extended Audio File Services to create a recording at the URL.
 Then primes the recorder, so it can start immediately in the real-time context.
 This should be called on app startup, then when the user *stops* recording, 
 so there's a new file immediately ready for their next recording.
 
 @param: url - a URL to somewhere in the app sandbox's Documents directory
 
 */
- (void) createRecordingFileWithURL:(NSURL *)url
{
    if (_curRecording.fileRef) {
        NSLog(@"Cleaning up spurious record file reference");
        [self stopRecord]; // Clean up any old file reference; shouldn't really ever get called
    }
    
    CFURLRef urlRef = (__bridge CFURLRef) url;
    AudioChannelLayout layout;
    memset(&layout, 0, sizeof(layout));
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
    checkError(ExtAudioFileCreateWithURL(urlRef,
                                         kAudioFileCAFType,
                                         &_recorderASBD,
                                         &layout,
                                         kAudioFileFlags_EraseFile,
                                         &_curRecording.fileRef),
               "ExtAudioFileCreateWithURL failed: creating file", false);
    checkError(ExtAudioFileWriteAsync(_curRecording.fileRef,
                                      0,
                                      NULL),
               "ExtAudioFileWriteAsync failed: initializing write buffers", false);
}

- (void) startRecord
{
    _curRecording.isRecording = YES;
    // Add the recorder render notify to the output unit
    // Do this here because we only want the notify callback fired when we're actually recording
    checkError(AudioUnitAddRenderNotify(_mixerUnit,
                                        &recordRenderNotify,
                                        &_curRecording),
               "AudioUnitAddRenderNotify failed: adding recorder to RemoteIO", false);
}

- (void) stopRecord
{
    // Remove the recorder render notify from the output unit
    checkError(AudioUnitRemoveRenderNotify(_mixerUnit,
                                           &recordRenderNotify,
                                           &_curRecording),
               "AudioUnitAddRenderNotify failed: adding recorder to RemoteIO", false);
    _curRecording.isRecording = NO;
    
    // Close the recording file
    checkError(ExtAudioFileDispose(_curRecording.fileRef), "ExtAudioFileDispose failed: closing file.", false);
    
    // Can chuck out the fileRef since we won't use it in playback
    _curRecording.fileRef = NULL;
}

/** This is the render notify added to the mixer. It's called whenever the mixer pulls new samples through it.
 It will capture everything going through the mixer, including playbacks. If you
 want to record only new stuff, don't add this callback and instead handle
 recording in the generator callback itself. You can use the isRecording boolean
 to decide whether or not to write to the file.
 
 @param: inRefCon: this is a RecordingInfo struct pointer.
 @param: The usual render notify parameters
 @return Returns the error, if any, from the async write call.
 
 */
OSStatus recordRenderNotify(void                        *inRefCon,
                            AudioUnitRenderActionFlags  *ioActionFlags,
                            const AudioTimeStamp        *inTimeStamp,
                            UInt32                      inBusNumber,
                            UInt32                      inNumberFrames,
                            AudioBufferList             *ioData)
{
    OSStatus result = noErr;
    
    RecordingInfo *info = (RecordingInfo *)inRefCon;
    if (*ioActionFlags & kAudioUnitRenderAction_PostRender && info->isRecording) {
        result = checkError(ExtAudioFileWriteAsync(info->fileRef,
                                                   inNumberFrames,
                                                   ioData),
                            "ExtAudioFileWriteAsync failed", false);
    }
    
    return result;
}

#pragma mark Playback stuff
- (void) setPlaybackURL:(NSURL *) url;
{
    _curPlayback.fileRef = NULL;
    
    // Get the URL of the new recording we want to play
    CFURLRef urlRef = (__bridge CFURLRef) url;
    // Get an AudioFileID, not the ExtAudioFileRef we wrote to
    AudioFileID audioFile;
    
    // Open the file
    checkError(AudioFileOpenURL(urlRef,
                                kAudioFileReadPermission,
                                kAudioFileCAFType,
                                &audioFile),
               "AudioFileOpenURL failed: opening file", false);
    
    // Get the format
    AudioStreamBasicDescription fileDesc = { 0 };
    UInt32 asbdSize = sizeof(fileDesc);
	checkError(AudioFileGetProperty(audioFile,
                                    kAudioFilePropertyDataFormat,
									&asbdSize,
                                    &fileDesc),
			   "AudioFileGetProperty failed: couldn't get file's data format", false);
    
    // Tell the playback AU to use the file
    checkError(AudioUnitSetProperty(_playerUnit,
                                    kAudioUnitProperty_ScheduledFileIDs,
                                    kAudioUnitScope_Global,
                                    0,
                                    &audioFile,
                                    sizeof(audioFile)),
               "AudioUnitSetProperty failed: setting ScheduledFileIDs on playback unit", false);
    
    // Get file length
    SInt64 nFrames;
    UInt32 paramSize = sizeof(nFrames);
    checkError(AudioFileGetProperty(audioFile,
                                    kAudioFilePropertyAudioDataPacketCount,
                                    &paramSize,
                                    &nFrames),
               "AudioFileGetProperty failed: getting packet count", false);
    // Setup the region
    memset(&_curPlayback.region.mTimeStamp, 0, sizeof(_curPlayback.region.mTimeStamp));
    _curPlayback.region.mTimeStamp.mFlags = kAudioTimeStampSampleTimeValid;
    _curPlayback.region.mTimeStamp.mSampleTime = 0;
    _curPlayback.region.mCompletionProc = NULL;
    _curPlayback.region.mCompletionProcUserData = NULL;
    _curPlayback.region.mAudioFile = audioFile;
    _curPlayback.region.mLoopCount = 0;
    _curPlayback.region.mStartFrame = 0;
    _curPlayback.region.mFramesToPlay = nFrames*fileDesc.mFramesPerPacket;
}

- (void) startPlayback
{
    _curPlayback.framesPlayed = 0;
    // Apply the region to the file player AU
    checkError(AudioUnitSetProperty(_playerUnit,
                                    kAudioUnitProperty_ScheduledFileRegion,
                                    kAudioUnitScope_Global,
                                    0,
                                    &_curPlayback.region,
                                    sizeof(_curPlayback.region)),
               "AudioUnitSetProperty failed: setting the player AU's region property", false);
    
    // Prime the player
    UInt32 defaultVal = 0;
	checkError(AudioUnitSetProperty(_playerUnit,
                                    kAudioUnitProperty_ScheduledFilePrime,
									kAudioUnitScope_Global,
                                    0,
                                    &defaultVal,
                                    sizeof(defaultVal)),
			   "AudioUnitSetProperty failed: priming the player", false);
    
    // Set up the start time
    AudioTimeStamp startTime;
    memset(&startTime, 0, sizeof(startTime));
    startTime.mFlags = kAudioTimeStampSampleTimeValid;
    startTime.mSampleTime = -1;
    checkError(AudioUnitSetProperty(_playerUnit,
                                    kAudioUnitProperty_ScheduleStartTimeStamp,
                                    kAudioUnitScope_Global,
                                    0,
                                    &startTime,
                                    sizeof(startTime)),
               "AudioUnitSetProperty failed: setting start time", false);
    // Add render notify to playback unit
    checkError(AudioUnitAddRenderNotify(_playerUnit,
                                        &playRenderNotify,
                                        &_curPlayback),
               "AudioUnitAddRenderNotify failed: adding playback notify to player", false);
    _curPlayback.isPlaying = YES;
}

- (void) stopPlayback
{
    checkError(AudioUnitReset(_playerUnit,
                              kAudioUnitScope_Global,
                              0),
               "AudioUnitReset failed: stopping AudioFilePlayer playback", false);
    // Remove render notify from playback unit
    checkError(AudioUnitRemoveRenderNotify(_playerUnit,
                                           &playRenderNotify,
                                           &_curPlayback),
               "AudioUnitAddRenderNotify failed: adding playback notify to player", false);
    _curPlayback.isPlaying = NO;
}

- (BOOL) isPlaying
{
    return _curPlayback.isPlaying;
}

/** Render notify added to the playback unit so we can keep track of when the
 file has finished playing.
 
 This is set up to loop as soon as the file is finished. It's obvious how to
 change this: just remove the call to startPlayback.
 
 @param: inRefCon: A PlaybackInfo struct.
 @return We could set our own errors here, but for now it just says "all is well."
 
 */
OSStatus playRenderNotify(void                        *inRefCon,
                          AudioUnitRenderActionFlags  *ioActionFlags,
                          const AudioTimeStamp        *inTimeStamp,
                          UInt32                      inBusNumber,
                          UInt32                      inNumberFrames,
                          AudioBufferList             *ioData)
{
    if (*ioActionFlags & kAudioUnitRenderAction_PostRender) {
        PlaybackInfo *info = (PlaybackInfo *)inRefCon;
        info->framesPlayed += inNumberFrames;
        if (info->framesPlayed >= info->region.mFramesToPlay) {
            [info->cab stopPlayback];
            [info->cab startPlayback];
        }
    }
    
    return noErr;
}

// Not a single malloc or calloc in the entire class, so very little to dispose of.
- (void) dealloc
{
    [self stop];
}

#pragma mark Singleton stuff
+ (TKCoreAudioBridge *) sharedAudioBridge
{
    if (self) {
        if (sharedBridge == nil) {
            (void )[[self alloc] init];
        }
    }
    
    return sharedBridge;
}

+ (id)allocWithZone:(NSZone *)zone
{
    @synchronized(self) {
        if (sharedBridge == nil) {
            sharedBridge = [super allocWithZone:zone];
            return sharedBridge;
        }
    }
    
    return nil;
}

- (id)copyWithZone:(NSZone *)zone
{
    return self;
}


@end
