# JavaScript bindings

`@parsoaudio/javascript` provides one JavaScript API for Electron and React
Native. The shared facade covers the current versioned Parso C ABI: codec and
WAV/PCM conversion, sample-rate conversion, loudness, analysis, waveform/key/
structure services, bounded headless engine control/rendering, auxiliary buses,
and the off-thread recording tap.

## Electron

Build the Node-API addon beside the native library:

```bash
cmake -S . -B build-js \
  -DPARSO_BUILD_NODE_ADDON=ON \
  -DPARSO_BUILD_TESTS=OFF \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build-js --target ParsoNodeAddon --parallel
```

The addon uses Node-API rather than a V8 ABI, so the same native module is
usable from supported Node and Electron versions. Keep `parso_node.node` and
`libparso.so` (or the platform equivalent) together in the application bundle.

```js
const { createElectron } = require("@parsoaudio/javascript/electron");
const { AudioCodec } = require("@parsoaudio/javascript");

const { CodecServices, Engine } = createElectron({
  addonPath: "/path/to/parso_node.node",
});
const audio = new CodecServices();
const encoded = audio.encode(new Float32Array([0, 0.25, -0.25]), 48_000, 1, AudioCodec.WAV);
const decoded = audio.decode(encoded, AudioCodec.WAV);
const engine = new Engine({ maxFrames: 512 });
```

The native addon is synchronous and must stay off an Electron renderer’s UI
thread for long offline operations. The native render callback never enters
JavaScript.

## React Native

React Native uses the same facade against a synchronous native-module contract.
Install the JavaScript package and register a native module named
`ParsoAudio`; the module must implement the methods listed in
`src/react-native.js`. This JavaScript package supplies that adapter and its
contract; the host application supplies the small Android/iOS native module
that connects those methods to its existing AAR or framework. The module’s
methods are control/offline calls only. A low-latency Android/iOS device
callback must call the native engine directly, not pass audio blocks through
the React Native bridge.

```js
const { createReactNative } = require("@parsoaudio/javascript/react-native");

const { CodecServices, Engine } = createReactNative();
const audio = new CodecServices();
const engine = new Engine({ sampleRateHz: 48_000, maxFrames: 256 });
```

The native module contract intentionally permits an application to use its
existing Android AAR or iOS framework host. `bindings/javascript` does not
duplicate an audio device implementation or launch emulators/simulators.

## Tests

The repository’s Node tests exercise the shared facade and the real Node-API
addon against the CMake native library:

```bash
node --test bindings/javascript/test/*.test.js
```

The base package has no runtime npm dependency. Native artifacts are supplied
by the platform build and are not hidden inside the JavaScript package.
