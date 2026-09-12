# JavaScript, Electron, and React Native

The JavaScript binding is deliberately split into a shared facade and a host
adapter:

```text
CodecServices / Engine / MixRecorder
              │
       shared JavaScript API
          ┌───┴────┐
       Electron   React Native
       Node-API   NativeModules.ParsoAudio
```

Electron uses a Node-API addon (`bindings/javascript/native/parso_node.cpp`)
that calls the versioned `parso.h` ABI. It copies native-owned output into
typed arrays and retains deck/microphone input arrays in the JavaScript
`Engine` object for the lifetime required by the borrowed C ABI.

React Native uses the same method names through `NativeModules.ParsoAudio`.
Those calls are control/offline calls. Device output, microphone capture,
route recovery, and callback timing stay in the Android/iOS native host. No
audio callback crosses the React Native bridge.

The current JavaScript surface is synchronous because it maps directly to the
existing synchronous C ABI. Applications should schedule long analysis,
encoding, and decoding calls away from the UI thread. It includes WAV and raw
PCM boundaries in addition to capability-advertised codecs; unsupported native
formats continue to report the native status.

Node-API is used instead of a V8-specific addon ABI. This avoids rebuilding the
Electron addon for each Electron/V8 release while still requiring one native
artifact per target operating system and architecture. The package does not
bundle native libraries and does not run emulators or simulators in CI.
