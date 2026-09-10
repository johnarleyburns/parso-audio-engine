import math
import os
from pathlib import Path
import unittest

from parso_audio import AudioCodec, CodecServices, ContainerCapability, Engine, ParsoError


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

    def test_real_ogg_fixture_decode(self) -> None:
        fixture = Path(__file__).parents[3] / "Tests" / "Fixtures" / "audio" / "audial_waking_up.ogg"
        if not fixture.exists():
            self.skipTest("fixture corpus is unavailable")
        decoded = self.audio.decode(fixture.read_bytes(), AudioCodec.OGG_VORBIS)
        self.assertGreater(decoded.frames, 1_000)
        self.assertIn(decoded.channel_count, (1, 2))
        self.assertGreater(decoded.sample_rate_hz, 8_000)

    def test_real_flac_fixture_decode(self) -> None:
        fixture = Path(__file__).parents[3] / "Tests" / "Fixtures" / "audio" / "wikipedia_chanukah.flac"
        if not fixture.exists():
            self.skipTest("fixture corpus is unavailable")
        decoded = self.audio.decode(fixture.read_bytes(), AudioCodec.FLAC)
        self.assertGreater(decoded.frames, 1_000)
        self.assertIn(decoded.channel_count, (1, 2))
        self.assertGreater(decoded.sample_rate_hz, 8_000)

    def test_close_is_idempotent_and_rejects_calls(self) -> None:
        service = CodecServices(self.library)
        service.close()
        service.close()
        with self.assertRaises(ParsoError):
            _ = service.capabilities

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


if __name__ == "__main__":
    unittest.main()
