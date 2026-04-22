import { NativeModules, NativeEventEmitter, Platform } from 'react-native';

const LINKING_ERROR =
  `The package 'react-native-pitchy' doesn't seem to be linked. Make sure: \n\n` +
  Platform.select({ ios: "- You have run 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go\n';

const PitchyNativeModule = NativeModules.Pitchy
  ? NativeModules.Pitchy
  : new Proxy(
      {},
      {
        get() {
          throw new Error(LINKING_ERROR);
        },
      }
    );

const eventEmitter = new NativeEventEmitter(PitchyNativeModule);

export type PitchyAlgorithm = 'ACF2+';

export type PitchyConfig = {
  /**
   * The size of the buffer used to record audio.
   * @default 4096
   */
  bufferSize?: number;
  /**
   * The minimum volume required to start detecting pitch.
   * @default -60
   */
  minVolume?: number;
  /**
   * The algorithm used to detect pitch.
   * @default 'ACF2+'
   */
  algorithm?: PitchyAlgorithm;

  recordFullAudio?: boolean;
  /**
   * Enable Apple's built-in voice processing, which applies acoustic echo cancellation
   * and noise suppression to the microphone feed.
   * @default false
   */
  useVoiceProcessing?: boolean;
};

export type PitchyEventCallback = ({ pitch }: { pitch: number }) => void;

export type PitchySlice = {
  audio: string;
  duration: number;
};

export type PitchyAudioSessionPreferences = {
  mode?: 'default' | 'measurement' | 'voiceChat';
  preferredSampleRate?: number;
  preferredIOBufferDuration?: number;
  preferredInputChannels?: number;
  prefersSpeakerOutput?: boolean;
};

const Pitchy = {
  init(config?: PitchyConfig): Promise<void> {
    return PitchyNativeModule.init({
      bufferSize: 4096,
      minVolume: -60,
      algorithm: 'ACF2+',
      recordFullAudio: false,
      useVoiceProcessing: false,
      ...config,
    });
  },
  start(): Promise<void> {
    return PitchyNativeModule.start();
  },
  stop(): Promise<void> {
    return PitchyNativeModule.stop();
  },
  slice(): Promise<PitchySlice> {
    return PitchyNativeModule.slice();
  },
  saveRecording(filename: string, options?: { format?: 'wav' | 'mp3' | 'aac' }): Promise<string> {
    // Prefer the new method with options if available
    if (typeof (PitchyNativeModule as any).saveRecordingWithOptions === 'function') {
      return (PitchyNativeModule as any).saveRecordingWithOptions(filename, options ?? {});
    }
    return PitchyNativeModule.saveRecording(filename);
  },
  isRecording(): Promise<boolean> {
    return PitchyNativeModule.isRecording();
  },
  pause(): Promise<void> {
    return PitchyNativeModule.pause();
  },
  resume(): Promise<void> {
    return PitchyNativeModule.resume();
  },
  applyAudioSessionPreferences(preferences: PitchyAudioSessionPreferences): Promise<void> {
    if (typeof PitchyNativeModule.applyAudioSessionPreferences !== 'function') {
      return Promise.resolve();
    }
    return PitchyNativeModule.applyAudioSessionPreferences(preferences ?? {});
  },
  addListener(callback: PitchyEventCallback) {
    return eventEmitter.addListener('onPitchDetected', callback);
  },
};

export default Pitchy;
