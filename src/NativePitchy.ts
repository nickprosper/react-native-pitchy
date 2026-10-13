import type {TurboModule} from 'react-native';
import {TurboModuleRegistry} from 'react-native';

export type PitchyConfig = {
  bufferSize: number;
  minVolume: number;
  algorithm: string;
  recordFullAudio: boolean;
  useVoiceProcessing: boolean;
  manageAudioSession: boolean;
};

export type PitchySlice = {
  audio: string;
  duration: number;
};

export interface Spec extends TurboModule {
  init(config: PitchyConfig): Promise<boolean>;
  start(): Promise<boolean>;
  stop(): Promise<boolean>;
  pause(): Promise<boolean>;
  resume(): Promise<boolean>;
  isRecording(): Promise<boolean>;
  slice(): Promise<PitchySlice>;
  saveRecording(filename: string): Promise<string>;
  saveRecordingWithOptions(filename: string, options: Object): Promise<string>;
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('Pitchy');
