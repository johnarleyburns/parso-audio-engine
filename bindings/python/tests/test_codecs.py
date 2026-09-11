import math
import os
from pathlib import Path
import threading
import unittest

from parso_audio import (
    AudioCodec,
    CodecServices,
    ContainerCapability,
    Engine,
    EngineCommand,
    EngineEventType,
    MixRecorder,
    ParsoError,
)
from parso_audio.acceptance import mp3_prefix


class CodecServicesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        library = os.environ.get("PARSO_AUDIO_LIBRARY")
        if not library:
            library = str(Path(__file__).parents[3] / "build-native" / "libparso.so")
        if not Path(library).exists():
            raise unittest.SkipTest(f"native library is unavailable: {library}")
        cls.library = library
        cls.audio = CodecServices(library)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.audio.close()

    def test_capabilities_advertise_xiph_vorbis(self) -> None:
        capabilities = self.audio.capabilities
        self.assertTrue(capabilities.encode_containers & ContainerCapability.OGG_VORBIS)
        self.assertTrue(capabilities.decode_containers & ContainerCapability.OGG_VORBIS)

    def test_vorbis_round_trip(self) -> None:
        samples = [
            0.25 * math.sin(2.0 * math.pi * 440.0 * index / 48_000.0)
            for index in range(4_800)
        ]
        encoded = self.audio.encode(samples, 48_000, 1, AudioCodec.OGG_VORBIS)
        decoded = self.audio.decode(encoded, AudioCodec.OGG_VORBIS)
        self.assertEqual(decoded.channel_count, 1)
        self.assertEqual(decoded.sample_rate_hz, 48_000)
        self.assertGreater(decoded.frames, 0)
        self.assertEqual(len(decoded.samples), decoded.frames)

    def test_sample_rate_conversion(self) -> None:
        samples = [0.25 * math.sin(2.0 * math.pi * 440.0 * index / 48_000.0) for index in range(4_800)]
        converted = self.audio.convert_sample_rate(samples, 48_000, 24_000, 1)
        self.assertEqual(converted.sample_rate_hz, 24_000)
        self.assertEqual(converted.channel_count, 1)
        self.assertGreater(converted.frames, 0)
        self.assertLess(abs(converted.frames - 2_400), 8)

    def test_loudness_measurement(self) -> None:
        samples = [0.25] * 48_000
        result = self.audio.measure_loudness(samples, 48_000, 1)
        self.assertTrue(math.isfinite(result.integrated_lufs))
        self.assertTrue(math.isfinite(result.true_peak_dbtp))

    def test_analysis_tempo_summary(self) -> None:
        samples = [0.0] * (48_000 * 8)
        for beat in range(0, len(samples), 24_000):
            samples[beat:beat + 128] = [1.0] * 128
        result = self.audio.analyze(samples, 48_000, 1)
        self.assertAlmostEqual(result.duration_seconds, 8.0, places=6)
        self.assertGreater(result.peak, 0.99)
        self.assertGreater(result.bpm_confidence, 0.5)
        self.assertGreater(result.bpm, 118.0)
        self.assertLess(result.bpm, 122.0)

    def test_key_estimate(self) -> None:
        samples = []
        for index in range(48_000):
            time = index / 48_000.0
            samples.append(
                0.25 * math.sin(2.0 * math.pi * 110.0 * time)
                + 0.20 * math.sin(2.0 * math.pi * 220.0 * time)
                + 0.20 * math.sin(2.0 * math.pi * 261.63 * time)
                + 0.20 * math.sin(2.0 * math.pi * 329.63 * time)
            )
        result = self.audio.estimate_key(samples, 48_000, 1)
        self.assertEqual(result.tonic_pitch_class, 9)
        self.assertTrue(result.is_minor)
        self.assertEqual((result.camelot_number, result.camelot_letter), (8, "A"))
        self.assertGreater(result.confidence, 0.3)

    def test_structure_sections(self) -> None:
        samples = [0.0] * (48_000 * 8)
        for index in range(48_000 * 2, 48_000 * 4):
            samples[index] = 0.5 * math.sin(2.0 * math.pi * 110.0 * index / 48_000.0)
        for index in range(48_000 * 4, 48_000 * 6):
            samples[index] = 0.8 * math.sin(2.0 * math.pi * 220.0 * index / 48_000.0)
        sections = self.audio.structure(samples, 48_000, 1, bpm=120.0)
        self.assertGreaterEqual(len(sections), 3)
        self.assertEqual(sections[0].kind, "intro")
        self.assertTrue(all(section.start_seconds >= 0.0 for section in sections))

    def test_waveform_min_max_summary(self) -> None:
        samples = [math.sin(2.0 * math.pi * index / 32.0) for index in range(1_024)]
        minimum, maximum = self.audio.waveform(samples, 48_000, 1, 32)
        self.assertEqual(len(minimum), 32)
        self.assertEqual(len(maximum), 32)
        self.assertLess(minimum[0], -0.9)
        self.assertGreater(maximum[0], 0.9)

    def test_real_ogg_fixture_decode(self) -> None:
        fixture = Path(__file__).parents[3] / "Tests" / "Fixtures" / "audio" / "audial_waking_up.ogg"
        if not fixture.exists():
            self.skipTest("fixture corpus is unavailable")
        decoded = self.audio.decode(fixture.read_bytes(), AudioCodec.OGG_VORBIS)
        self.assertGreater(decoded.frames, 1_000)
        self.assertIn(decoded.channel_count, (1, 2))
        self.assertGreater(decoded.sample_rate_hz, 8_000)
        summary = self.audio.analyze(decoded.samples, decoded.sample_rate_hz, decoded.channel_count)
        minimum, maximum = self.audio.waveform(
            decoded.samples, decoded.sample_rate_hz, decoded.channel_count, 32
        )
        self.assertGreater(summary.duration_seconds, 0.0)
        self.assertTrue(math.isfinite(summary.peak))
        self.assertEqual(len(minimum), 32)
        self.assertEqual(len(maximum), 32)

    def test_real_flac_fixture_decode(self) -> None:
        fixture = Path(__file__).parents[3] / "Tests" / "Fixtures" / "audio" / "wikipedia_chanukah.flac"
        if not fixture.exists():
            self.skipTest("fixture corpus is unavailable")
        decoded = self.audio.decode(fixture.read_bytes(), AudioCodec.FLAC)
        self.assertGreater(decoded.frames, 1_000)
        self.assertIn(decoded.channel_count, (1, 2))
        self.assertGreater(decoded.sample_rate_hz, 8_000)
        summary = self.audio.analyze(decoded.samples, decoded.sample_rate_hz, decoded.channel_count)
        minimum, maximum = self.audio.waveform(
            decoded.samples, decoded.sample_rate_hz, decoded.channel_count, 32
        )
        self.assertGreater(summary.duration_seconds, 0.0)
        self.assertTrue(math.isfinite(summary.rms))
        self.assertEqual(len(minimum), 32)
        self.assertEqual(len(maximum), 32)

    def test_real_mp3_fixture_prefix_decode(self) -> None:
        fixture = Path(__file__).parents[3] / "Tests" / "Fixtures" / "audio" / "gostreyshen_world.mp3"
        if not fixture.exists():
            self.skipTest("fixture corpus is unavailable")
        encoded = mp3_prefix(fixture.read_bytes(), 30.0)
        decoded = self.audio.decode(encoded, AudioCodec.MP3)
        self.assertGreater(decoded.frames / decoded.sample_rate_hz, 30.0)
        self.assertEqual(decoded.channel_count, 2)

    def test_close_is_idempotent_and_rejects_calls(self) -> None:
        service = CodecServices(self.library)
        service.close()
        service.close()
        with self.assertRaises(ParsoError):
            _ = service.capabilities

    def test_engine_serializes_render_and_close(self) -> None:
        engine = Engine(max_frames=64, library_path=self.library)
        started = threading.Event()
        errors = []

        def render_until_close() -> None:
            started.set()
            try:
                for _ in range(256):
                    engine.render(32)
            except ParsoError as error:
                if error.status != -6:
                    errors.append(error)

        worker = threading.Thread(target=render_until_close)
        worker.start()
        self.assertTrue(started.wait(1.0))
        engine.close()
        worker.join(2.0)
        self.assertFalse(worker.is_alive())
        self.assertEqual(errors, [])
        engine.close()

    def test_headless_engine_renders_bounded_blocks(self) -> None:
        with Engine(max_frames=256, library_path=self.library) as engine:
            engine.set_master_level(0.8)
            left, right = engine.render(128)
            self.assertEqual(len(left), 128)
            self.assertEqual(len(right), 128)
            self.assertTrue(all(sample == 0.0 for sample in left))
            stats = engine.stats()
            self.assertEqual(stats.master_frame, 128)
            self.assertEqual(stats.deck_count, 2)
            with self.assertRaises(ValueError):
                engine.render(257)

    def test_headless_engine_keeps_deck_pcm_alive(self) -> None:
        samples = [0.2 * math.sin(2.0 * math.pi * 220.0 * index / 48_000.0) for index in range(4_800)]
        with Engine(max_frames=256, library_path=self.library) as engine:
            engine.set_deck_buffer(0, samples, 48_000, 1)
            engine.play(0)
            left, right = engine.render(128)
            self.assertTrue(any(abs(sample) > 1.0e-6 for sample in left))
            self.assertEqual(len(left), len(right))

    def test_headless_engine_crossfader_control_requires_two_decks(self) -> None:
        with Engine(max_frames=256, library_path=self.library) as engine:
            with self.assertRaises(ValueError):
                engine.set_crossfader(1.5)
            engine.set_crossfader(-1.0)
            engine.set_crossfader(1.0)
        with self.assertRaises(ValueError):
            Engine(max_frames=256, deck_count=1, library_path=self.library)

    def test_headless_engine_record_ring_drains_off_thread_surface(self) -> None:
        samples = [0.2 * math.sin(2.0 * math.pi * 220.0 * index / 48_000.0) for index in range(4_800)]
        with Engine(max_frames=256, library_path=self.library) as engine:
            engine.set_deck_buffer(0, samples, 48_000, 1)
            engine.play(0)
            engine.set_record_active(True)
            engine.render(256)
            left, right = engine.record_drain(256)
            self.assertEqual(len(left), 256)
            self.assertEqual(len(right), 256)
            self.assertEqual(engine.record_dropped_frames(), 0)
            engine.record_reset()
            self.assertEqual(len(engine.record_drain(1)[0]), 0)

    def test_mix_recorder_consumes_record_tap_and_encodes(self) -> None:
        samples = [0.2] * 4_800
        recorder = MixRecorder(self.audio, 48_000)
        with Engine(max_frames=256, library_path=self.library) as engine:
            engine.set_deck_buffer(0, samples, 48_000, 1)
            engine.play(0)
            engine.set_record_active(True)
            engine.render(256)
            self.assertEqual(recorder.append_engine(engine, 256), 256)
        encoded = recorder.encode()
        decoded = self.audio.decode(encoded, AudioCodec.WAV)
        self.assertEqual(decoded.frames, 256)
        self.assertEqual(decoded.channel_count, 2)
        recorder.reset()
        self.assertEqual(recorder.frames, 0)

    def test_headless_engine_exposes_shared_transport_command_payload(self) -> None:
        samples = [0.2 * math.sin(2.0 * math.pi * 220.0 * index / 48_000.0) for index in range(4_800)]
        with Engine(max_frames=256, library_path=self.library) as engine:
            engine.set_deck_buffer(0, samples, 48_000, 1)
            engine.post_command(EngineCommand.PLAY, 0)
            engine.set_keylock(0, True)
            engine.set_slip(0, True)
            engine.seek(0, 0.01)
            engine.post_command(EngineCommand.SET_LOOP, 0, i0=1, f0=0.01, f1=0.05)
            engine.set_cue(0, 0.01)
            engine.jump_cue(0)
            engine.set_hotcue(0, 0, 0.02)
            engine.jump_hotcue(0, 0)
            engine.delete_hotcue(0, 0)
            engine.set_loop(0, 0.01, 0.05)
            engine.set_loop_active(0, True)
            engine.beat_loop(0, 1.0, 0.01)
            left, right = engine.render(128)
            self.assertEqual(len(left), len(right))
            self.assertTrue(any(abs(sample) > 1.0e-6 for sample in left))
            events = engine.poll_events()
            self.assertTrue(any(event.type == EngineEventType.STATE and event.deck == 0 for event in events))

    def test_headless_engine_publishes_mixer_eq_and_fx_controls(self) -> None:
        samples = [0.2 * math.sin(2.0 * math.pi * 220.0 * index / 48_000.0) for index in range(9_600)]
        with Engine(max_frames=256, library_path=self.library) as engine:
            engine.set_deck_buffer(0, samples, 48_000, 1)
            engine.set_mixer_controls(
                xfade_assign=(2.0, 2.0, 2.0, 2.0),
                eq_low=(-70.0, 0.0, 0.0, 0.0),
                color_kind=(0.0, 0.0, 0.0, 0.0),
                color_amount=(-0.8, 0.0, 0.0, 0.0),
                beatfx_kind=16.0,
                beatfx_beats=1.0,
                beatfx_depth=0.8,
                beatfx_assign=3.0,
                beatfx_on=True,
                master_reverb_send=0.25,
            )
            engine.play(0)
            left, right = engine.render(256)
            self.assertEqual(len(left), len(right))
            self.assertTrue(any(abs(sample) > 1.0e-6 for sample in left))

    def test_headless_engine_rejects_invalid_command_deck(self) -> None:
        with Engine(max_frames=64, library_path=self.library) as engine:
            with self.assertRaises(ValueError):
                engine.post_command(EngineCommand.PLAY, 2)
            with self.assertRaises(ValueError):
                engine.seek(0, -0.1)
            with self.assertRaises(ValueError):
                engine.set_hotcue(0, 8)


if __name__ == "__main__":
    unittest.main()
