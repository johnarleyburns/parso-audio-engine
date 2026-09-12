"use strict";

const path = require("node:path");
const fs = require("node:fs");
const { CodecServices, Engine, MixRecorder, ParsoError, createFacade, normalizeNativeError } = require("./index.js");

function resolveAddon(addonPath) {
  if (addonPath) return addonPath;
  const candidates = [
    path.join(__dirname, "..", "native", "parso_node.node"),
    path.join(process.cwd(), "parso_node.node"),
  ];
  const found = candidates.find((candidate) => fs.existsSync(candidate));
  if (!found) throw new Error("parso_node.node was not found; build the Electron native addon first");
  return found;
}

function createElectronBackend(options = {}) {
  let addon;
  try { addon = require(resolveAddon(options.addonPath)); } catch (error) { throw normalizeNativeError(error, "Electron native addon load"); }
  if (!addon || addon.abiVersion !== 1) throw new Error("unsupported parso Node-API addon ABI");
  return addon;
}

function createElectron(options = {}) {
  return createFacade(createElectronBackend(options));
}

module.exports = { createElectronBackend, createElectron, CodecServices, Engine, MixRecorder, ParsoError };
