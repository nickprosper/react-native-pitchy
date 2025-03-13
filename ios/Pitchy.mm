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
          if (self->isRecording) {
                // Get the first channel's data (assuming mono or using the first channel)
                float *channelData = buffer.floatChannelData[0];
                NSUInteger length = buffer.frameLength * sizeof(float);
                NSData *data = [NSData dataWithBytes:channelData length:length];
                
                // Initialize the buffers if needed
              if (!self->audioBuffer) {
                self->audioBuffer = [NSMutableData data];
                }
            if (!self->fullRecording) {
              self->fullRecording = [NSMutableData data];
                }
                // Append raw data to both buffers
            [self->audioBuffer appendData:data];
            [self->fullRecording appendData:data];
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
    // Dispatch the pitch detection work on a background queue with a defined QoS.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        float *channelData = buffer.floatChannelData[0];
        std::vector<double> buf(channelData, channelData + buffer.frameLength);
        
      double detectedPitch = pitchy::autoCorrelate(buf, self->sampleRate, self->minVolume);
        // Optionally log the detected pitch (for debugging)
        //RCTLogInfo(@"Detected Pitch %f", detectedPitch);
        
        // Now dispatch the event sending on the main thread.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self sendEventWithName:@"onPitchDetected" body:@{@"pitch": @(detectedPitch)}];
        });
    });
}

// New method to slice the current recording buffer.
// This returns the raw audio data collected since the last slice call as a base64 encoded WAV file.
// It ensures that the resulting audio is at least 2 seconds long by padding the start with zeros if needed,
// resamples the audio to 16 kHz mono, and calculates the duration (in milliseconds) of the resulting audio.
RCT_EXPORT_METHOD(slice:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    if (!audioBuffer || audioBuffer.length == 0) {
        resolve(@{ @"audio": @"", @"duration": @(0) });
        return;
    }
    
    // Calculate the current number of float samples in the audioBuffer
    NSUInteger floatCount = audioBuffer.length / sizeof(float);
    // Determine the required number of samples for 2 seconds at the original sample rate
    NSUInteger requiredSamples = (NSUInteger)(2.0 * sampleRate);
    
    // Create padded data if the current audio is shorter than required
    NSMutableData *paddedData;
    if (floatCount < requiredSamples) {
        NSUInteger padSamples = requiredSamples - floatCount;
        // Create a buffer for the total required samples (zero-filled by default)
        paddedData = [NSMutableData dataWithLength:requiredSamples * sizeof(float)];
        // Explicitly fill the first part with zeros (optional, since dataWithLength zeros it out)
        memset(paddedData.mutableBytes, 0, padSamples * sizeof(float));
        // Copy the original audioBuffer data into paddedData after the zeros
        [paddedData replaceBytesInRange:NSMakeRange(padSamples * sizeof(float), floatCount * sizeof(float)) withBytes:audioBuffer.bytes];
    } else {
        paddedData = [NSMutableData dataWithData:audioBuffer];
    }
    
    // At this point, paddedData contains the original audio samples (in float) at the original sample rate.
    // Next, resample the audio to 16 kHz mono using AVAudioConverter.
    
    // Create input and output AVAudioFormats
    AVAudioFormat *inputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                                   sampleRate:sampleRate
                                                                     channels:1
                                                                  interleaved:NO];
    AVAudioFormat *outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                                    sampleRate:16000
                                                                      channels:1
                                                                   interleaved:NO];
    
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat];
    if (!converter) {
        reject(@"converter_error", @"Failed to create AVAudioConverter", nil);
        return;
    }
    
    // Prepare the input buffer from paddedData
    NSUInteger originalSampleCount = paddedData.length / sizeof(float);
    AVAudioFrameCount inputFrameCount = (AVAudioFrameCount)originalSampleCount;
    AVAudioPCMBuffer *inputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inputFormat frameCapacity:inputFrameCount];
    inputBuffer.frameLength = inputFrameCount;
    memcpy(inputBuffer.floatChannelData[0], paddedData.bytes, paddedData.length);
    
    // Estimate the required number of output frames based on the ratio of sample rates
    AVAudioFrameCount outputCapacity = (AVAudioFrameCount)(inputFrameCount * (16000.0 / sampleRate)) + 1;
    AVAudioPCMBuffer *outputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat frameCapacity:outputCapacity];
    
    NSError *convError = nil;
    __block BOOL finished = NO;
    AVAudioConverterOutputStatus status = [converter convertToBuffer:outputBuffer error:&convError withInputFromBlock:^AVAudioBuffer * _Nullable(AVAudioPacketCount requestedFrames, AVAudioConverterInputStatus * _Nonnull outStatus) {
        if (finished) {
            *outStatus = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }
        finished = YES;
        *outStatus = AVAudioConverterInputStatus_HaveData;
        return inputBuffer;
    }];
    
    if (status != AVAudioConverterOutputStatus_EndOfStream && convError != nil) {
        RCTLogError(@"Resampling error: %@", convError);
        reject(@"resample_error", @"Resampling failed", convError);
        return;
    }
    
    // Now outputBuffer contains the resampled audio at 16 kHz
    // Use the resampled data for further processing
    NSUInteger resampledFrameCount = outputBuffer.frameLength;
    const float *resampledSamples = outputBuffer.floatChannelData[0];
    
    // Convert the resampled float samples to PCM int16
    NSMutableData *pcmData = [NSMutableData dataWithLength:resampledFrameCount * sizeof(int16_t)];
    int16_t *pcmSamples = (int16_t *)pcmData.mutableBytes;
    for (NSUInteger i = 0; i < resampledFrameCount; i++) {
        float sample = resampledSamples[i];
        if (sample > 1.0) sample = 1.0;
        if (sample < -1.0) sample = -1.0;
        pcmSamples[i] = (int16_t)(sample * 32767);
    }
    
    // Create a WAV header for PCM int16 format with a sample rate of 16000
    uint32_t pcmDataLength = (uint32_t)pcmData.length;
    uint32_t sampleRateInt = 16000;
    uint16_t channels = 1;
    uint16_t bitsPerSample = 16;
    uint32_t byteRate = sampleRateInt * channels * bitsPerSample / 8;
    uint16_t blockAlign = channels * bitsPerSample / 8;
    uint32_t chunkSize = 36 + pcmDataLength;
    
    NSMutableData *wavData = [NSMutableData dataWithCapacity:(44 + pcmDataLength)];
    [wavData appendBytes:"RIFF" length:4];
    [wavData appendBytes:&chunkSize length:4];
    [wavData appendBytes:"WAVE" length:4];
    [wavData appendBytes:"fmt " length:4];
    uint32_t subchunk1Size = 16;
    [wavData appendBytes:&subchunk1Size length:4];
    uint16_t audioFormat = 1; // PCM
    [wavData appendBytes:&audioFormat length:2];
    [wavData appendBytes:&channels length:2];
    [wavData appendBytes:&sampleRateInt length:4];
    [wavData appendBytes:&byteRate length:4];
    [wavData appendBytes:&blockAlign length:2];
    [wavData appendBytes:&bitsPerSample length:2];
    [wavData appendBytes:"data" length:4];
    [wavData appendBytes:&pcmDataLength length:4];
    
    // Append the PCM data
    [wavData appendData:pcmData];
    
    // Base64 encode the complete WAV data and prepend the data URL header
    NSString *base64String = [wavData base64EncodedStringWithOptions:0];
    NSString *audioResult = [NSString stringWithFormat:@"data:audio/wav;base64,%@", base64String];
    
    // Calculate the duration in milliseconds based on the resampled data
    double durationSeconds = ((double)resampledFrameCount) / 16000.0;
    double durationMs = durationSeconds * 1000.0;
    
    // Clear the slice buffer after slicing
    [audioBuffer setLength:0];
    
    // Return a dictionary with both audio and duration
    resolve(@{ @"audio": audioResult, @"duration": @(durationMs) });
}

RCT_EXPORT_METHOD(saveRecording:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    if (!fullRecording || fullRecording.length == 0) {
        reject(@"no_data", @"No recording data available", nil);
        return;
    }
    
    // Convert the accumulated float audio data to PCM int16
    NSUInteger floatCount = fullRecording.length / sizeof(float);
    const float *floatSamples = (const float *)fullRecording.bytes;
    NSMutableData *pcmData = [NSMutableData dataWithLength:floatCount * sizeof(int16_t)];
    int16_t *pcmSamples = (int16_t *)pcmData.mutableBytes;
    for (NSUInteger i = 0; i < floatCount; i++) {
        float sample = floatSamples[i];
        if (sample > 1.0) sample = 1.0;
        if (sample < -1.0) sample = -1.0;
        pcmSamples[i] = (int16_t)(sample * 32767);
    }
    
    // Create a WAV header for PCM int16 format
    uint32_t pcmDataLength = (uint32_t)pcmData.length;
    uint32_t sampleRateInt = (uint32_t)sampleRate;
    uint16_t channels = 1;
    uint16_t bitsPerSample = 16;
    uint32_t byteRate = sampleRateInt * channels * bitsPerSample / 8;
    uint16_t blockAlign = channels * bitsPerSample / 8;
    uint32_t chunkSize = 36 + pcmDataLength;
    
    NSMutableData *wavData = [NSMutableData dataWithCapacity:(44 + pcmDataLength)];
    [wavData appendBytes:"RIFF" length:4];
    [wavData appendBytes:&chunkSize length:4];
    [wavData appendBytes:"WAVE" length:4];
    [wavData appendBytes:"fmt " length:4];
    uint32_t subchunk1Size = 16;
    [wavData appendBytes:&subchunk1Size length:4];
    uint16_t audioFormat = 1; // PCM
    [wavData appendBytes:&audioFormat length:2];
    [wavData appendBytes:&channels length:2];
    [wavData appendBytes:&sampleRateInt length:4];
    [wavData appendBytes:&byteRate length:4];
    [wavData appendBytes:&blockAlign length:2];
    [wavData appendBytes:&bitsPerSample length:2];
    [wavData appendBytes:"data" length:4];
    [wavData appendBytes:&pcmDataLength length:4];
    
    // Append the PCM data
    [wavData appendData:pcmData];
    
    // Write the wavData to a file in the app's Documents directory with a .wav extension
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths firstObject];
    NSString *filePath = [documentsDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.wav", uuid]];
    
    BOOL success = [wavData writeToFile:filePath atomically:YES];
    if (success) {
        // Clear the full recording buffer after a successful save.
        [fullRecording setLength:0];
        resolve(filePath);
    } else {
        reject(@"save_error", @"Failed to save recording", nil);
    }
}

@end
