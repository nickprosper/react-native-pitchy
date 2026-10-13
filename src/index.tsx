import { NativeEventEmitter } from 'react-native';
import PitchyNativeModule from './NativePitchy';

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

  /**
   * iOS only.
   * Whether Pitchy should manage the global audio session.
   * @default true
   * */
  manageAudioSession?: boolean;
};

export type PitchyInputEvent = {
  pitch: number;
  /** RMS level in dBFS, independent of pitch. Absent in older native builds. */
  volumeDb?: number;
};

export type PitchyEventCallback = (event: PitchyInputEvent) => void;

export type PitchySlice = {
  audio: string;
  duration: number;
};

const Pitchy = {
  init(config?: PitchyConfig): Promise<void> {
    return PitchyNativeModule.init({
      bufferSize: 4096,
      minVolume: -60,
      algorithm: 'ACF2+',
      recordFullAudio: false,
      useVoiceProcessing: false,
      manageAudioSession: true,
      ...config,
    }).then(() => undefined);
  },
  start(): Promise<void> {
    return PitchyNativeModule.start().then(() => undefined);
  },
  stop(): Promise<void> {
    return PitchyNativeModule.stop().then(() => undefined);
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
    return PitchyNativeModule.pause().then(() => undefined);
  },
  resume(): Promise<void> {
    return PitchyNativeModule.resume().then(() => undefined);
  },
  addListener(callback: PitchyEventCallback) {
    return eventEmitter.addListener('onPitchDetected', callback);
  },
};

export default Pitchy;
