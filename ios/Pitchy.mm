#import "Pitchy.h"
#import <AVFoundation/AVFoundation.h>
#import <React/RCTLog.h>
#import <vector>

@implementation Pitchy {
    AVAudioEngine *audioEngine;
    double sampleRate;
    double minVolume;

    // State flags
    BOOL isRecording;
    BOOL isInitialized;
    BOOL recordFullAudio;   // opt-in full-session capture
    BOOL isPaused;          // soft pause without tearing down the engine

    // Buffers
    NSMutableData *audioBuffer;   // float32 slice buffer (always kept)
    NSMutableData *fullRecording; // optional session-long int16 PCM
}

RCT_EXPORT_MODULE()

- (NSArray<NSString *> *)supportedEvents {
    return @[@"onPitchDetected"];
}

#pragma mark - Initialisation

RCT_EXPORT_METHOD(init:(NSDictionary *)config) {
#if TARGET_IPHONE_SIMULATOR
    RCTLogInfo(@"Pitchy module is not supported on the iOS simulator");
    return;
#endif

    if (!isInitialized) {
        audioEngine = [[AVAudioEngine alloc] init];

        /* ---------- AVAudioSession ---------- */
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *error = nil;

        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                       mode:AVAudioSessionModeMeasurement
                    options:AVAudioSessionCategoryOptionDefaultToSpeaker
                      error:&error];
        if (error) RCTLogError(@"Error setting AVAudioSession category: %@", error);

        [session setPreferredSampleRate:44100 error:&error];
        if (error) RCTLogError(@"Error setting preferred sample rate: %@", error);

        [session setActive:YES error:&error];
        if (error) RCTLogError(@"Error activating AVAudioSession: %@", error);

        /* ---------- Input format ---------- */
        AVAudioInputNode *inputNode = [audioEngine inputNode];
        AVAudioFormat *format = [inputNode inputFormatForBus:0];

        sampleRate = format.sampleRate > 0 ? format.sampleRate : 44100;
        RCTLogInfo(@"Input format sampleRate: %f, channelCount: %u",
                   format.sampleRate, (unsigned int)format.channelCount);

        /* ---------- Params from JS ---------- */
        minVolume       = [config[@"minVolume"]       doubleValue];
        recordFullAudio = [config[@"recordFullAudio"] boolValue];
        isPaused        = NO;

        /* ---------- Tap for pitch + capture ---------- */
        [inputNode installTapOnBus:0
                        bufferSize:[config[@"bufferSize"] unsignedIntValue]
                            format:format
                             block:^(AVAudioPCMBuffer * _Nonnull buffer,
                                     AVAudioTime * _Nonnull when) {
            [self detectPitch:buffer];

            if (self->isRecording && !self->isPaused) {
                float *channelData = buffer.floatChannelData[0];
                AVAudioFrameCount frames = buffer.frameLength;

                /* ---- slice buffer (float32) ---- */
                NSData *slice = [NSData dataWithBytes:channelData
                                               length:frames * sizeof(float)];
                if (!self->audioBuffer) self->audioBuffer = [NSMutableData data];
                [self->audioBuffer appendData:slice];

                /* ---- optional full recording (int16) ---- */
                if (self->recordFullAudio) {
                    if (!self->fullRecording) self->fullRecording = [NSMutableData data];

                    NSMutableData *pcmBlock =
                        [NSMutableData dataWithLength:frames * sizeof(int16_t)];
                    int16_t *dst = (int16_t *)pcmBlock.mutableBytes;
                    for (NSUInteger i = 0; i < frames; i++) {
                        float s = channelData[i];
                        if (s > 1.0f)  s = 1.0f;
                        if (s < -1.0f) s = -1.0f;
                        dst[i] = (int16_t)(s * 32767);
                    }
                    [self->fullRecording appendData:pcmBlock];
                }
            }
        }];

        isInitialized = YES;
    }
}

#pragma mark - Recording control

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

    audioBuffer   = [NSMutableData data];
    fullRecording = [NSMutableData data];
    isPaused      = NO;

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

    if (audioBuffer)   [audioBuffer   setLength:0];
    if (fullRecording) [fullRecording setLength:0];

    resolve(@(YES));
}

RCT_EXPORT_METHOD(pause:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    if (!isRecording) {
        reject(@"not_recording", @"Not recording", nil);
        return;
    }
    isPaused = YES;
    resolve(@(YES));
}

RCT_EXPORT_METHOD(resume:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    if (!isRecording) {
        reject(@"not_recording", @"Not recording", nil);
        return;
    }
    isPaused = NO;
    resolve(@(YES));
}

#pragma mark - Pitch detection

- (void)detectPitch:(AVAudioPCMBuffer *)buffer {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        float *channelData = buffer.floatChannelData[0];
        std::vector<double> buf(channelData, channelData + buffer.frameLength);

        double pitch = pitchy::autoCorrelate(buf, self->sampleRate, self->minVolume);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self sendEventWithName:@"onPitchDetected" body:@{ @"pitch": @(pitch) }];
        });
    });
}


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

    NSMutableData *pcmData = [NSMutableData dataWithData:fullRecording];

    /* ---- WAV header ---- */
    uint32_t pcmLen       = (uint32_t)pcmData.length;
    uint32_t sr           = (uint32_t)sampleRate;
    uint16_t channels     = 1;
    uint16_t bitsPerSample= 16;
    uint32_t byteRate     = sr * channels * bitsPerSample / 8;
    uint16_t blockAlign   = channels * bitsPerSample / 8;
    uint32_t chunkSize    = 36 + pcmLen;

    NSMutableData *wav = [NSMutableData dataWithCapacity:(44 + pcmLen)];
    [wav appendBytes:"RIFF" length:4];
    [wav appendBytes:&chunkSize length:4];
    [wav appendBytes:"WAVE" length:4];
    [wav appendBytes:"fmt " length:4];
    uint32_t subchunk1 = 16;
    [wav appendBytes:&subchunk1 length:4];
    uint16_t audioFmt = 1;
    [wav appendBytes:&audioFmt length:2];
    [wav appendBytes:&channels length:2];
    [wav appendBytes:&sr length:4];
    [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&blockAlign length:2];
    [wav appendBytes:&bitsPerSample length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&pcmLen length:4];
    [wav appendData:pcmData];

    /* ---- File path ---- */
    NSArray  *paths   = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                            NSUserDomainMask, YES);
    NSString *dir     = [paths firstObject];
    NSString *filePath= [dir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"%@.wav", uuid]];

    BOOL ok = [wav writeToFile:filePath atomically:YES];
    if (ok) {
        [fullRecording setLength:0];  // clear for next session
        resolve(filePath);
    } else {
        reject(@"save_error", @"Failed to save recording", nil);
    }
}

@end
