# Linux device backend

The Linux native SDK keeps device I/O outside `CParsoEngine`. The supported
host adapter in this repository uses the PipeWire command-line stream client
(`pw-cat`) and communicates with it through fixed-size raw float32 blocks:

```text
PipeWire capture -> reader thread -> bounded capture queue -> engine render
engine render -> bounded output queues -> writer threads -> PipeWire playback
```

The render call never performs a PipeWire, ALSA, filesystem, process, or lock
operation. Capture and playback workers own those operations, and the host
application owns the callback schedule. Master, monitor, and booth streams may
be sent to separate PipeWire targets. The native master record tap is drained
by the control side and can be written to a WAV file.

## Build and run

The setup script installs `pipewire-bin`, which provides `pw-cat` on Debian and
Ubuntu. It also installs `ffmpeg`, `python3-pip`, and `python3-venv` for the
Linux acceptance and packaging checks:

```bash
./scripts/setup-linux.sh --no-android --no-windows-cross-build
cmake -S . -B build-linux -G Ninja -DPARSO_BUILD_TESTS=ON
cmake --build build-linux --target parso_linux_pipewire_host
```

Render to the default PipeWire sink for five seconds:

```bash
./build-linux/parso_linux_pipewire_host --seconds 5
```

Capture from the default source and record the resulting master bus:

```bash
./build-linux/parso_linux_pipewire_host \
  --seconds 30 --capture --record /tmp/parso-linux-recording.wav
```

Targets accept PipeWire node names or numeric target IDs. Use `pw-cli ls Node`
to discover them. Monitor and booth outputs can be routed independently:

```bash
./build-linux/parso_linux_pipewire_host \
  --output-target alsa_output.pci-0000_00_1f.3.analog-stereo \
  --monitor-target alsa_output.pci-0000_00_1f.3.analog-stereo \
  --booth-target alsa_output.pci-0000_00_1f.3.analog-stereo \
  --capture-target alsa_input.pci-0000_00_1f.3.analog-stereo \
  --capture --seconds 30
```

`--no-device` runs the same engine, queue, routing, capture-silence, and record
contract without launching a system stream. It is the deterministic CTest
smoke path and is suitable for CI. Device route changes, unplug/replug, and
human listening remain hardware acceptance checks.

The adapter does not link the project against PipeWire or ALSA libraries. This
keeps the shipping native library dependency-free and avoids adding a
copyleft runtime dependency; `pw-cat` is an optional host executable used only
by this Linux adapter.
