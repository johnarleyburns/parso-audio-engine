"use strict";

class ParsoError extends Error {
  constructor(status, operation, detail = "") {
    super(`${operation} failed with native status ${status}${detail ? `: ${detail}` : ""}`);
    this.name = "ParsoError";
    this.status = status;
    this.operation = operation;
  }
}

const AudioCodec = Object.freeze({ WAV: 1, FLAC: 2, OGG_VORBIS: 3, OPUS: 4, MP3: 5, AAC: 6 });
const EngineCommand = Object.freeze({
  PLAY: 0, PAUSE: 1, SET_CUE: 2, JUMP_CUE: 3, HOTCUE_SET: 4, HOTCUE_JUMP: 5,
  HOTCUE_DELETE: 6, LOOP_IN: 7, LOOP_OUT: 8, RELOOP_EXIT: 9, BEATLOOP: 10,
  LOOP_SCALE: 11, LOOP_MOVE: 12, SET_LOOP: 13, SET_LOOP_ACTIVE: 14, BEATJUMP: 15,
  SYNC: 16, SET_MASTER: 17, SET_KEYLOCK: 18, SET_SLIP: 19, JOG_TOUCH: 20,
  JOG_MOVE: 21, JOG_RELEASE: 22, SEEK: 23, UNSYNC: 24, STEM_ARM: 25,
  STEM_GAIN: 26, STEM_MUTE: 27, STEM_SOLO: 28, SET_REVERSE: 29, VINYL_SPEED: 30,
  ECHO_SET: 31, COLORFX_KIND: 32, BEATFX_KIND: 33, BEATFX_ONOFF: 34,
  BEATFX_RELEASE: 35, SAMPLER_TRIGGER: 36, SAMPLER_STOP: 37, SAMPLER_CONFIG: 38,
  LOAD: 39,
});
const IsolatorProfile = Object.freeze({ GENERIC: 0, WARM2: 1 });
const ContainerCapability = Object.freeze({
  WAV: 1, FLAC: 2, OGG_VORBIS: 4, OPUS: 8, MP3: 16, AAC: 32, ALAC: 64, AIFF: 128, CAF: 256,
});
const OfflineService = Object.freeze({ SRC: 1, LOUDNESS: 2, ANALYSIS: 4 });

function asFloat32(samples, name = "samples") {
  if (samples instanceof Float32Array) return samples;
  if (ArrayBuffer.isView(samples) && samples.BYTES_PER_ELEMENT === 4) {
    return new Float32Array(samples.buffer, samples.byteOffset, samples.byteLength / 4);
  }
  if (Array.isArray(samples)) return Float32Array.from(samples);
  throw new TypeError(`${name} must be a Float32Array or numeric array`);
}

function asBytes(bytes, name = "encoded") {
  if (bytes instanceof Uint8Array) return bytes;
  if (ArrayBuffer.isView(bytes)) return new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes instanceof ArrayBuffer) return new Uint8Array(bytes);
  throw new TypeError(`${name} must be a Uint8Array or ArrayBuffer`);
}

function validatePcm(samples, sampleRateHz, channelCount) {
  if (samples.length === 0 || !Number.isInteger(sampleRateHz) || sampleRateHz <= 0 ||
      ![1, 2].includes(channelCount) || samples.length % channelCount !== 0) {
    throw new RangeError("PCM must be non-empty, one or two channel, divisible, and use a positive rate");
  }
}

function validateFrames(frames, maxFrames) {
  if (!Number.isInteger(frames) || frames <= 0 || frames > maxFrames) {
    throw new RangeError(`frames must be between 1 and ${maxFrames}`);
  }
}

function normalizeNativeError(error, operation) {
  if (error instanceof ParsoError) return error;
  const status = Number.isInteger(error?.status) ? error.status : -7;
  return new ParsoError(status, operation, error?.message || String(error));
}

class CodecServices {
  constructor(backend) {
    if (!backend) throw new TypeError("a native backend is required");
    this._backend = backend;
    this._closed = false;
  }

  _open() { if (this._closed) throw new ParsoError(-6, "codec service", "service is closed"); }
  close() { this._closed = true; }
  capabilities() { this._open(); return this._backend.capabilities(); }
  readWav(encoded) { this._open(); return this._backend.readWav(asBytes(encoded)); }
  readPcm(encoded, sampleRateHz, channelCount, bitsPerSample) {
    this._open();
    return this._backend.readPcm(asBytes(encoded), sampleRateHz, channelCount, bitsPerSample);
  }
  writeWav(samples, sampleRateHz, channelCount, bitsPerSample = 16, isFloat = false) {
    this._open(); const pcm = asFloat32(samples); validatePcm(pcm, sampleRateHz, channelCount);
    return this._backend.writeWav(pcm, sampleRateHz, channelCount, bitsPerSample, Number(isFloat));
  }
  writePcm(samples, sampleRateHz, channelCount, bitsPerSample = 16) {
    this._open(); const pcm = asFloat32(samples); validatePcm(pcm, sampleRateHz, channelCount);
    return this._backend.writePcm(pcm, sampleRateHz, channelCount, bitsPerSample);
  }
  encode(samples, sampleRateHz, channelCount, codec, options = {}) {
    this._open(); const pcm = asFloat32(samples); validatePcm(pcm, sampleRateHz, channelCount);
    return this._backend.codecWrite(pcm, sampleRateHz, channelCount, codec, options);
  }
  decode(encoded, codec, options = {}) {
    this._open(); return this._backend.codecRead(asBytes(encoded), codec, options);
  }
  convertSampleRate(samples, sourceSampleRateHz, destinationSampleRateHz, channelCount, quality = 0) {
    this._open(); const pcm = asFloat32(samples); validatePcm(pcm, sourceSampleRateHz, channelCount);
    return this._backend.convertSampleRate(pcm, sourceSampleRateHz, destinationSampleRateHz, channelCount, quality);
  }
  measureLoudness(samples, sampleRateHz, channelCount, targetLufs = -14) {
    this._open(); const pcm = asFloat32(samples); validatePcm(pcm, sampleRateHz, channelCount);
    return this._backend.measureLoudness(pcm, sampleRateHz, channelCount, targetLufs);
  }
  analyze(samples, sampleRateHz, channelCount, options = {}) {
    this._open(); const pcm = asFloat32(samples); validatePcm(pcm, sampleRateHz, channelCount);
    return this._backend.analyze(pcm, sampleRateHz, channelCount, options);
  }
  estimateKey(samples, sampleRateHz, channelCount, options = {}) {
    this._open(); const pcm = asFloat32(samples); validatePcm(pcm, sampleRateHz, channelCount);
    return this._backend.estimateKey(pcm, sampleRateHz, channelCount, options);
  }
  structure(samples, sampleRateHz, channelCount, options = {}) {
    this._open(); const pcm = asFloat32(samples); validatePcm(pcm, sampleRateHz, channelCount);
    return this._backend.structure(pcm, sampleRateHz, channelCount, options);
  }
  waveform(samples, sampleRateHz, channelCount, bucketCount) {
    this._open(); const pcm = asFloat32(samples); validatePcm(pcm, sampleRateHz, channelCount);
    return this._backend.waveform(pcm, sampleRateHz, channelCount, bucketCount);
  }
}

class Engine {
  constructor(backend, options = {}) {
    if (!backend) throw new TypeError("a native backend is required");
    this._backend = backend;
    this._closed = false;
    this._maxFrames = options.maxFrames ?? 512;
    this._handle = backend.engineCreate(options);
    this._buffers = new Map();
    this._mic = null;
  }
  _open() { if (this._closed) throw new ParsoError(-6, "engine", "engine is closed"); }
  close() {
    if (!this._closed) { this._backend.engineDestroy(this._handle); this._buffers.clear(); this._mic = null; this._closed = true; }
  }
  setMasterLevel(level) { this._open(); this._backend.engineSetControl(this._handle, { masterLevel: level }); }
  setCrossfader(position) { this._open(); this._backend.engineSetControl(this._handle, { crossfader: position }); }
  setMixerControls(controls) { this._open(); this._backend.engineSetControl(this._handle, controls); }
  setDeckBuffer(deck, samples, sampleRateHz, channelCount = 1) {
    this._open(); const pcm = asFloat32(samples); validatePcm(pcm, sampleRateHz, channelCount);
    const frames = pcm.length / channelCount;
    const left = new Float32Array(frames); const right = channelCount === 2 ? new Float32Array(frames) : null;
    for (let i = 0; i < frames; i++) { left[i] = pcm[i * channelCount]; if (right) right[i] = pcm[i * 2 + 1]; }
    this._backend.engineSetDeckBuffer(this._handle, deck, left, right, frames, sampleRateHz);
    this._buffers.set(deck, { left, right });
  }
  setMicBuffer(samples, sampleRateHz, channelCount = 1) {
    this._open(); const pcm = asFloat32(samples); validatePcm(pcm, sampleRateHz, channelCount);
    const frames = pcm.length / channelCount;
    const left = new Float32Array(frames); const right = channelCount === 2 ? new Float32Array(frames) : null;
    for (let i = 0; i < frames; i++) { left[i] = pcm[i * channelCount]; if (right) right[i] = pcm[i * 2 + 1]; }
    this._backend.engineSetMicBuffer(this._handle, left, right, frames, sampleRateHz);
    this._mic = { left, right };
  }
  postCommand(type, deck = -1, payload = {}) { this._open(); return this._backend.enginePostCommand(this._handle, type, deck, payload); }
  play(deck) { return this.postCommand(EngineCommand.PLAY, deck); }
  pause(deck) { return this.postCommand(EngineCommand.PAUSE, deck); }
  seek(deck, seconds) { if (!Number.isFinite(seconds) || seconds < 0) throw new RangeError("seconds must be finite and non-negative"); return this.postCommand(EngineCommand.SEEK, deck, { f0: seconds }); }
  setKeylock(deck, enabled) { return this.postCommand(EngineCommand.SET_KEYLOCK, deck, { f0: Number(enabled) }); }
  setSlip(deck, enabled) { return this.postCommand(EngineCommand.SET_SLIP, deck, { f0: Number(enabled) }); }
  render(frames) { this._open(); validateFrames(frames, this._maxFrames); return this._backend.engineRender(this._handle, frames); }
  renderMonitor(frames) { this._open(); validateFrames(frames, this._maxFrames); return this._backend.engineRenderMonitor(this._handle, frames); }
  renderBooth(frames) { this._open(); validateFrames(frames, this._maxFrames); return this._backend.engineRenderBooth(this._handle, frames); }
  stats() { this._open(); return this._backend.engineStats(this._handle); }
  pollEvents(maxEvents = 64) { this._open(); return this._backend.enginePollEvents(this._handle, maxEvents); }
  setRecordActive(active) { this._open(); return this._backend.engineRecordSetActive(this._handle, Number(active)); }
  recordDrain(maxFrames) {
    this._open(); validateFrames(maxFrames, this._maxFrames);
    const block = this._backend.engineRecordDrain(this._handle, maxFrames);
    const frames = block.frames ?? block.left.length;
    return { left: block.left.slice(0, frames), right: block.right.slice(0, frames), frames };
  }
  recordDroppedFrames() { this._open(); return this._backend.engineRecordDroppedFrames(this._handle); }
  recordReset() { this._open(); return this._backend.engineRecordReset(this._handle); }
}

class MixRecorder {
  constructor(audio, sampleRateHz, codec = AudioCodec.WAV, options = {}) {
    this.audio = audio; this.sampleRateHz = sampleRateHz; this.codec = codec; this.options = options; this._samples = [];
  }
  get frames() { return this._samples.length / 2; }
  append(left, right) {
    const l = asFloat32(left, "left"); const r = asFloat32(right, "right");
    if (!l.length || l.length !== r.length) throw new RangeError("record blocks must have equal non-zero lengths");
    for (let i = 0; i < l.length; i++) this._samples.push(l[i], r[i]);
  }
  appendEngine(engine, maxFrames) {
    const block = engine.recordDrain(maxFrames);
    if (block.left.length) this.append(block.left, block.right);
    return block.left.length;
  }
  encode() { if (!this._samples.length) throw new RangeError("cannot encode an empty recording"); return this.audio.encode(Float32Array.from(this._samples), this.sampleRateHz, 2, this.codec, this.options); }
  reset() { this._samples = []; }
}

function createFacade(backend) {
  return { CodecServices: class extends CodecServices { constructor() { super(backend); } }, Engine: class extends Engine { constructor(options) { super(backend, options); } }, MixRecorder, backend };
}

function createElectronBackend(options) { return require("./electron.js").createElectronBackend(options); }
function createElectron(options) { return require("./electron.js").createElectron(options); }
function createReactNativeBackend(nativeModule) { return require("./react-native.js").createReactNativeBackend(nativeModule); }
function createReactNative(options) { return require("./react-native.js").createReactNative(options); }

module.exports = {
  AudioCodec, EngineCommand, IsolatorProfile, ContainerCapability, OfflineService,
  ParsoError, CodecServices, Engine, MixRecorder, createFacade,
  createElectronBackend, createElectron, createReactNativeBackend, createReactNative,
  asFloat32, asBytes, normalizeNativeError,
};
