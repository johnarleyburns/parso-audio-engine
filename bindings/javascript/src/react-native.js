"use strict";

const { CodecServices, Engine, MixRecorder, createFacade } = require("./index.js");

function createReactNativeBackend(nativeModule) {
  if (!nativeModule) {
    let reactNative;
    try { reactNative = require("react-native"); } catch (error) {
      throw new Error(`React Native runtime is unavailable: ${error.message}`);
    }
    nativeModule = reactNative.NativeModules.ParsoAudio;
  }
  if (!nativeModule) throw new Error("NativeModules.ParsoAudio is unavailable; install the ParsoAudio React Native module");
  const required = [
    "capabilities", "readWav", "readPcm", "writeWav", "writePcm", "codecRead", "codecWrite",
    "convertSampleRate", "measureLoudness", "analyze", "estimateKey", "structure", "waveform",
    "engineCreate", "engineDestroy", "engineSetControl", "engineSetDeckBuffer", "engineSetMicBuffer",
    "enginePostCommand", "engineRender", "engineRenderMonitor", "engineRenderBooth", "engineStats",
    "enginePollEvents", "engineRecordSetActive", "engineRecordDrain", "engineRecordDroppedFrames",
    "engineRecordReset",
  ];
  for (const method of required) if (typeof nativeModule[method] !== "function") throw new Error(`React Native module is missing ${method}()`);
  return nativeModule;
}

function createReactNative(options = {}) {
  return createFacade(createReactNativeBackend(options.nativeModule));
}

module.exports = { createReactNativeBackend, createReactNative, CodecServices, Engine, MixRecorder };
