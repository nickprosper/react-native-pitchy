#import "Pitchy.h"
#import <AVFoundation/AVFoundation.h>
#import <React/RCTLog.h>

@implementation Pitchy {
    AVAudioEngine *audioEngine;
    double sampleRate;
    double minVolume;
    BOOL isRecording;
    BOOL isInitialized;
    // Buffer to accumulate audio data between slices
    NSMutableData *audioBuffer;
    // Buffer to store the full recording data for the session
    NSMutableData *fullRecording;
}

RCT_EXPORT_MODULE()

- (NSArray<NSString *> *)supportedEvents {
  return @[@"onPitchDetected"];
}

RCT_EXPORT_METHOD(init:(NSDictionary *)config) {
    #if TARGET_IPHONE_SIMULATOR
        RCTLogInfo(@"Pitchy module is not supported on the iOS simulator");
        return;
    #endif
    if (!isInitialized) {
        audioEngine = [[AVAudioEngine alloc] init];
        AVAudioInputNode *inputNode = [audioEngine inputNode];
        
        AVAudioFormat *format = [inputNode inputFormatForBus:0];
        sampleRate = format.sampleRate;
        minVolume = [config[@"minVolume"] doubleValue];

        // Install tap on the input node to capture audio buffers.
        // The block calls detectPitch and appends the raw audio to our buffers.
        [inputNode installTapOnBus:0 bufferSize:[config[@"bufferSize"] unsignedIntValue] format:format block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
            [self detectPitch:buffer];
            if (isRecording) {
                // Get the first channel's data (assuming mono or using the first channel)
                float *channelData = buffer.floatChannelData[0];
                NSUInteger length = buffer.frameLength * sizeof(float);
                NSData *data = [NSData dataWithBytes:channelData length:length];
                
                // Initialize the buffers if needed
                if (!audioBuffer) {
                    audioBuffer = [NSMutableData data];
                }
                if (!fullRecording) {
                    fullRecording = [NSMutableData data];
                }
                // Append raw data to both buffers
                [audioBuffer appendData:data];
                [fullRecording appendData:data];
            }
        }];

        // Configure the audio session.
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *error = nil;
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                        mode:AVAudioSessionModeMeasurement
                     options:AVAudioSessionCategoryOptionDefaultToSpeaker
                       error:&error];
        if (error) {
            RCTLogError(@"Error setting AVAudioSession category: %@", error);
        }
        
        [session setActive:YES error:&error];
        if (error) {
            RCTLogError(@"Error activating AVAudioSession: %@", error);
        }

        isInitialized = YES;
    }
}

RCT_EXPORT_METHOD(isRecording:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    resolve(@(isRecording));
}

RCT_EXPORT_METHOD(start:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    if (!isInitialized) {
        reject(@"not_initialized", @"Pitchy module is not initialized", nil);
        return;
    }

    if (isRecording) {
        reject(@"already_recording", @"Already recording", nil);
        return;
    }
    
    // Reset the buffers for a new recording session.
    audioBuffer = [NSMutableData data];
    fullRecording = [NSMutableData data];

    NSError *error = nil;
    [audioEngine startAndReturnError:&error];
    if (error) {
        reject(@"start_error", @"Failed to start audio engine", error);
    } else {
        isRecording = YES;
        resolve(@(YES));
    }
}

RCT_EXPORT_METHOD(stop:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    if (!isRecording) {
        reject(@"not_recording", @"Not recording", nil);
        return;
    }

    [audioEngine stop];
    isRecording = NO;
    
    // Clear the audio buffers after stopping the recording session.
    if (audioBuffer) {
        [audioBuffer setLength:0];
    }
    if (fullRecording) {
        [fullRecording setLength:0];
    }
    
    resolve(@(YES));
}

- (void)detectPitch:(AVAudioPCMBuffer *)buffer {
    float *channelData = buffer.floatChannelData[0];
    std::vector<double> buf(channelData, channelData + buffer.frameLength);

    double detectedPitch = pitchy::autoCorrelate(buf, sampleRate, minVolume);
    
    [self sendEventWithName:@"onPitchDetected" body:@{@"pitch": @(detectedPitch)}];
}

// New method to slice the current recording buffer.
// This returns the raw audio data collected since the last slice call as a base64 encoded string.
RCT_EXPORT_METHOD(slice:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    if (!audioBuffer || audioBuffer.length == 0) {
        resolve(@"");
        return;
    }
    // Encode the raw audio data to a base64 string.
    NSString *base64String = [audioBuffer base64EncodedStringWithOptions:0];
    // Clear the slice buffer after slicing.
    [audioBuffer setLength:0];
    resolve(base64String);
}

// New method to save the full recording to the filesystem using a provided UUID.
// The method writes the raw recording to a file in the app's Documents directory.
RCT_EXPORT_METHOD(saveRecording:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    if (!fullRecording || fullRecording.length == 0) {
        reject(@"no_data", @"No recording data available", nil);
        return;
    }
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths firstObject];
    NSString *filePath = [documentsDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.raw", uuid]];
    
    BOOL success = [fullRecording writeToFile:filePath atomically:YES];
    if (success) {
        // Clear the full recording buffer after a successful save.
        [fullRecording setLength:0];
        resolve(filePath);
    } else {
        reject(@"save_error", @"Failed to save recording", nil);
    }
}

@end
