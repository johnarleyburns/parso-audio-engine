"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { createReactNativeBackend, createReactNative } = require("../src/react-native.js");

const methods = [
  "capabilities", "readWav", "readPcm", "writeWav", "writePcm", "codecRead", "codecWrite",
  "convertSampleRate", "measureLoudness", "analyze", "estimateKey", "structure", "waveform",
  "engineCreate", "engineDestroy", "engineSetControl", "engineSetDeckBuffer", "engineSetMicBuffer",
  "enginePostCommand", "engineRender", "engineRenderMonitor", "engineRenderBooth", "engineStats",
  "enginePollEvents", "engineRecordSetActive", "engineRecordDrain", "engineRecordDroppedFrames",
  "engineRecordReset",
];

test("React Native adapter validates the complete native-module contract", () => {
  const nativeModule = Object.fromEntries(methods.map((method) => [method, () => undefined]));
  assert.equal(createReactNativeBackend(nativeModule), nativeModule);
  const facade = createReactNative({ nativeModule });
  assert.equal(typeof facade.CodecServices, "function");
  assert.equal(typeof facade.Engine, "function");
  assert.equal(facade.backend, nativeModule);
  assert.throws(() => createReactNativeBackend({}), /missing capabilities/);
});
