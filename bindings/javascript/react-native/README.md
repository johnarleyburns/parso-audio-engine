# React Native host contract

The JavaScript adapter talks to a native module registered as
`NativeModules.ParsoAudio`. The module owns the C ABI handle and must keep
borrowed deck/microphone buffers alive until replacement or engine close.

The required synchronous methods are listed in
`../src/react-native.js`. Methods should copy values at the bridge boundary and
must never be called from an Android Oboe or iOS Core Audio callback. The
native device host should render directly through `parso_engine_render` and
keep device capture in its native ring, while JavaScript uses
`recordDrain`, `pollEvents`, and the analysis/codec calls on the control side.

An application can implement this contract over the existing Android AAR
(`Bindings/ParsoAudioAndroid`) or its iOS framework. Keeping that host choice
outside this package avoids shipping a second DSP/device implementation and
lets applications select the React Native architecture supported by their
React Native version (legacy NativeModules or TurboModules).
