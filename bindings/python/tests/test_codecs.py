import math
import os
from pathlib import Path
import unittest

from parso_audio import AudioCodec, CodecServices, ContainerCapability, ParsoError


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

    def test_close_is_idempotent_and_rejects_calls(self) -> None:
        service = CodecServices(self.library)
        service.close()
        service.close()
        with self.assertRaises(ParsoError):
            _ = service.capabilities


if __name__ == "__main__":
    unittest.main()
