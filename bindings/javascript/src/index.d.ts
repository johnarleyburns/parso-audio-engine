export type Pcm = Float32Array | number[];
export type Bytes = Uint8Array | ArrayBuffer;
export interface CodecOptions { compressionLevel?: number; bitrateKbps?: number; bitsPerSample?: number; wavIsFloat?: boolean; quality?: number; vbrQuality?: number; }
export interface Capabilities { decodeContainers: number; encodeContainers: number; readPcmFormats: number; writePcmFormats: number; maxChannels: number; maxSampleRateHz: number; offlineServices: number; }
export interface DecodedPcm { samples: Float32Array; frames: number; channelCount: number; sampleRateHz: number; }
export interface AnalysisResult { durationSeconds: number; rms: number; peak: number; bpm: number; bpmConfidence: number; }
export interface LoudnessResult { integratedLufs: number; truePeakDbtp: number; gainToTargetDb: number; loudnessRangeLu: number; }
export interface KeyResult { tonicPitchClass: number; isMinor: boolean; camelotNumber: number; camelotLetter: string; confidence: number; }
export interface StructureSection { startSeconds: number; kind: string; bar: number; energy: number; confidence: number; }
export interface StereoBlock { left: Float32Array; right: Float32Array; }
export interface EngineOptions { sampleRateHz?: number; maxFrames?: number; deckCount?: number; isolatorProfile?: number; }
export declare const AudioCodec: Readonly<Record<string, number>>;
export declare const EngineCommand: Readonly<Record<string, number>>;
export declare const IsolatorProfile: Readonly<Record<string, number>>;
export declare const ContainerCapability: Readonly<Record<string, number>>;
export declare const OfflineService: Readonly<Record<string, number>>;
export declare class ParsoError extends Error { status: number; operation: string; }
export declare class CodecServices {
  constructor(backend: any); close(): void; capabilities(): Capabilities; readWav(encoded: Bytes): DecodedPcm; readPcm(encoded: Bytes, sampleRateHz: number, channelCount: number, bitsPerSample: number): DecodedPcm;
  writeWav(samples: Pcm, sampleRateHz: number, channelCount: number, bitsPerSample?: number, isFloat?: boolean): Uint8Array; writePcm(samples: Pcm, sampleRateHz: number, channelCount: number, bitsPerSample?: number): Uint8Array;
  encode(samples: Pcm, sampleRateHz: number, channelCount: number, codec: number, options?: CodecOptions): Uint8Array; decode(encoded: Bytes, codec: number, options?: CodecOptions): DecodedPcm;
  convertSampleRate(samples: Pcm, sourceSampleRateHz: number, destinationSampleRateHz: number, channelCount: number, quality?: number): DecodedPcm;
  measureLoudness(samples: Pcm, sampleRateHz: number, channelCount: number, targetLufs?: number): LoudnessResult; analyze(samples: Pcm, sampleRateHz: number, channelCount: number, options?: object): AnalysisResult;
  estimateKey(samples: Pcm, sampleRateHz: number, channelCount: number, options?: object): KeyResult; structure(samples: Pcm, sampleRateHz: number, channelCount: number, options?: object): StructureSection[]; waveform(samples: Pcm, sampleRateHz: number, channelCount: number, bucketCount: number): { minimum: Float32Array; maximum: Float32Array; };
}
export declare class Engine {
  constructor(backend: any, options?: EngineOptions); close(): void; setMasterLevel(level: number): void; setCrossfader(position: number): void; setMixerControls(controls: object): void; setDeckBuffer(deck: number, samples: Pcm, sampleRateHz: number, channelCount?: number): void; setMicBuffer(samples: Pcm, sampleRateHz: number, channelCount?: number): void;
  postCommand(type: number, deck?: number, payload?: object): void; play(deck: number): void; pause(deck: number): void; seek(deck: number, seconds: number): void; setKeylock(deck: number, enabled: boolean): void; setSlip(deck: number, enabled: boolean): void;
  render(frames: number): StereoBlock; renderMonitor(frames: number): StereoBlock; renderBooth(frames: number): StereoBlock; stats(): object; pollEvents(maxEvents?: number): object[]; setRecordActive(active: boolean): void; recordDrain(maxFrames: number): StereoBlock; recordDroppedFrames(): number; recordReset(): void;
}
export declare class MixRecorder { constructor(audio: CodecServices, sampleRateHz: number, codec?: number, options?: CodecOptions); readonly frames: number; append(left: Pcm, right: Pcm): void; appendEngine(engine: Engine, maxFrames: number): number; encode(): Uint8Array; reset(): void; }
export interface BindingFacade { CodecServices: new () => CodecServices; Engine: new (options?: EngineOptions) => Engine; MixRecorder: typeof MixRecorder; backend: any; }
export declare function createFacade(backend: any): BindingFacade;
export declare function createElectronBackend(options?: { addonPath?: string }): any;
export declare function createElectron(options?: { addonPath?: string }): BindingFacade;
export declare function createReactNativeBackend(nativeModule?: any): any;
export declare function createReactNative(options?: { nativeModule?: any }): BindingFacade;
