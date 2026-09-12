"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { MixRecorder, ParsoError, asFloat32 } = require("../src/index.js");

test("shared facade validates PCM and preserves recorder frame counts", () => {
  assert.deepEqual(Array.from(asFloat32([1, 2, 3])), [1, 2, 3]);
  assert.throws(() => asFloat32("not PCM"), TypeError);
  const calls = [];
  const audio = { encode(samples, rate, channels, codec) { calls.push([samples.length, rate, channels, codec]); return new Uint8Array([1, 2]); } };
  const recorder = new MixRecorder(audio, 48_000);
  recorder.append(Float32Array.from([1, 2]), Float32Array.from([3, 4]));
  assert.equal(recorder.frames, 2);
  assert.deepEqual(Array.from(recorder.encode()), [1, 2]);
  assert.deepEqual(calls, [[4, 48_000, 2, 1]]);
  recorder.reset();
  assert.equal(recorder.frames, 0);
});

test("shared facade reports native-shaped errors consistently", () => {
  const error = new ParsoError(-3, "codec decoding", "unsupported");
  assert.equal(error.status, -3);
  assert.match(error.message, /unsupported/);
});
