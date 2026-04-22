#ifdef __cplusplus
#pragma once
#endif

#import <Foundation/Foundation.h>
#import <React/RCTBridgeModule.h>

/**
 * Spec protocol for the Pitchy native module.
 * This protocol defines the interface for the React Native JavaScript code to interact with.
 */
@protocol NativePitchySpec <RCTBridgeModule>

/**
 * Initialize the audio engine with the provided configuration.
 */
- (void)init:(NSDictionary *)config
     resolver:(RCTPromiseResolveBlock)resolve
     rejecter:(RCTPromiseRejectBlock)reject;

/**
 * Start pitch detection.
 */
- (void)start:(RCTPromiseResolveBlock)resolve
       reject:(RCTPromiseRejectBlock)reject;

/**
 * Pauses the pitch detection / recording
 */
- (void)pause:(RCTPromiseResolveBlock)resolve
       reject:(RCTPromiseRejectBlock)reject;

/**
 * Resumes the pitch detection / recording after a pause
 */
- (void)resume:(RCTPromiseResolveBlock)resolve
       reject:(RCTPromiseRejectBlock)reject;

/**
 * Stop pitch detection.
 */
- (void)stop:(RCTPromiseResolveBlock)resolve
      reject:(RCTPromiseRejectBlock)reject;

/**
 * Query if pitch detection is currently active.
 */
- (void)isRecording:(RCTPromiseResolveBlock)resolve
            reject:(RCTPromiseRejectBlock)reject;

/**
 * Apply iOS audio session preferences managed by the host app.
 */
- (void)applyAudioSessionPreferences:(NSDictionary *)preferences
                            resolver:(RCTPromiseResolveBlock)resolve
                            rejecter:(RCTPromiseRejectBlock)reject;

@end
