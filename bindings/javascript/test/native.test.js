"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { createElectron, createElectronBackend } = require("../src/electron.js");

const addonPath = process.env.PARSO_NODE_ADDON || path.resolve(__dirname, "../../../build-js/parso_node.node");
let addon;
try { addon = createElectronBackend({ addonPath }); } catch (error) { throw new Error(`native addon unavailable at ${addonPath}: ${error.message}`); }
const { CodecServices, Engine } = createElectron({ addonPath });

test("Electron Node-API addon exposes the complete current offline surface", () => {
  assert.equal(addon.abiVersion, 1);
  const capabilities = addon.capabilities();
  assert.equal(Number(capabilities.offlineServices), 7);
  const audio = new CodecServices();
  const samples = Float32Array.from([-0.75, -0.25, 0, 0.25, 0.75, 0.5]);
  const wav = audio.writeWav(samples, 48_000, 2);
  const decodedWav = audio.readWav(wav);
  assert.equal(Number(decodedWav.frames), 3);
  assert.equal(decodedWav.channelCount, 2);
  assert.ok(Math.abs(decodedWav.samples[0] + 0.75) < 1 / 32_000);
  const raw = audio.writePcm(samples, 48_000, 2);
  const decodedRaw = audio.readPcm(raw, 48_000, 2, 16);
  assert.equal(Number(decodedRaw.frames), 3);
  const src = audio.convertSampleRate(Float32Array.from([0, 1, 0, -1]), 48_000, 24_000, 1);
  assert.equal(src.sampleRateHz, 24_000);
  const loudness = audio.measureLoudness(Float32Array.from({ length: 48_000 }, () => 0.25), 48_000, 1);
  assert.ok(Number.isFinite(loudness.integratedLufs));
  const analysis = audio.analyze(Float32Array.from({ length: 48_000 }, (_, index) => index % 2_000 === 0 ? 1 : 0), 48_000, 1);
  assert.equal(analysis.durationSeconds, 1);
  const waveform = audio.waveform(Float32Array.from({ length: 128 }, (_, index) => Math.sin(index)), 48_000, 1, 8);
  assert.equal(waveform.minimum.length, 8);
  audio.close();
});

test("Electron engine retains buffers and exposes render buses and recording", () => {
  const engine = new Engine({ maxFrames: 64 });
  const tone = Float32Array.from({ length: 4_800 }, (_, index) => Math.sin(index / 10) * 0.2);
  engine.setDeckBuffer(0, tone, 48_000, 1);
  engine.setMicBuffer(tone, 48_000, 1);
  engine.setMasterLevel(0.8);
  engine.play(0);
  const output = engine.render(32);
  assert.equal(output.left.length, 32);
  assert.equal(engine.renderMonitor(32).right.length, 32);
  assert.equal(engine.renderBooth(32).left.length, 32);
  assert.equal(engine.stats().masterFrame, 32);
  engine.setRecordActive(true);
  engine.render(32);
  const block = engine.recordDrain(64);
  assert.equal(block.frames, 32);
  assert.equal(block.left.length, 32);
  assert.equal(engine.recordDroppedFrames(), 0);
  engine.recordReset();
  engine.close();
  assert.throws(() => engine.render(1), /closed/);
});
