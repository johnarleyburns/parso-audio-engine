"""Small, ownership-safe Python facade over the Parso native C ABI."""

from __future__ import annotations

from array import array
import ctypes
from dataclasses import dataclass
from enum import IntEnum, IntFlag
import ctypes.util
import math
import os
import sys
from typing import Iterable, Optional, Union


class ParsoError(RuntimeError):
    """Raised when a native Parso operation returns a non-zero status."""

    def __init__(self, status: int, operation: str, detail: str = "") -> None:
        message = f"{operation} failed with native status {status}"
        if detail:
            message += f": {detail}"
        super().__init__(message)
        self.status = status
        self.operation = operation


class AudioCodec(IntEnum):
    """Stable byte-oriented codec selectors from ``parso.h``."""

    WAV = 1
    FLAC = 2
    OGG_VORBIS = 3
    OPUS = 4
    MP3 = 5
    AAC = 6


class EngineCommand(IntEnum):
    """Stable transport and effect command selectors from ``parso.h``."""

    PLAY = 0
    PAUSE = 1
    SET_CUE = 2
    JUMP_CUE = 3
    HOTCUE_SET = 4
    HOTCUE_JUMP = 5
    HOTCUE_DELETE = 6
    LOOP_IN = 7
    LOOP_OUT = 8
    RELOOP_EXIT = 9
    BEATLOOP = 10
    LOOP_SCALE = 11
    LOOP_MOVE = 12
    SET_LOOP = 13
    SET_LOOP_ACTIVE = 14
    BEATJUMP = 15
    SYNC = 16
    SET_MASTER = 17
    SET_KEYLOCK = 18
    SET_SLIP = 19
    JOG_TOUCH = 20
    JOG_MOVE = 21
    JOG_RELEASE = 22
    SEEK = 23
    UNSYNC = 24
    STEM_ARM = 25
    STEM_GAIN = 26
    STEM_MUTE = 27
    STEM_SOLO = 28
    SET_REVERSE = 29
    VINYL_SPEED = 30
    ECHO_SET = 31
    COLORFX_KIND = 32
    BEATFX_KIND = 33
    BEATFX_ONOFF = 34
    BEATFX_RELEASE = 35
    SAMPLER_TRIGGER = 36
    SAMPLER_STOP = 37
    SAMPLER_CONFIG = 38
    LOAD = 39


class ContainerCapability(IntFlag):
    """Container bits reported by a native build."""

    WAV = 1
    FLAC = 2
    OGG_VORBIS = 4
    OPUS = 8
    MP3 = 16
    AAC = 32
    ALAC = 64
    AIFF = 128
    CAF = 256


@dataclass(frozen=True)
class CodecOptions:
    """Options shared by the native offline codec services."""

    compression_level: int = 5
    bitrate_kbps: int = 192
    bits_per_sample: int = 16
    wav_is_float: bool = False
    quality: int = 0
    vbr_quality: Optional[int] = None


@dataclass(frozen=True)
class CodecCapabilities:
    """Capabilities reported by the loaded native library."""

    decode_containers: ContainerCapability
    encode_containers: ContainerCapability
    read_pcm_formats: int
    write_pcm_formats: int
    max_channels: int
    max_sample_rate_hz: int
    offline_services: int


@dataclass(frozen=True)
class DecodedPcm:
    """Managed interleaved float32 PCM copied from a native read."""

    samples: array
    frames: int
    channel_count: int
    sample_rate_hz: int


@dataclass(frozen=True)
class LoudnessResult:
    """EBU R128 measurement returned by the native loudness service."""

    integrated_lufs: float
    true_peak_dbtp: float
    gain_to_target_db: float
    loudness_range_lu: float


@dataclass(frozen=True)
class EngineStats:
    """Snapshot of native headless render counters."""

    master_frame: int
    starved_frames: int
    deck_count: int


class _Capabilities(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("decode_containers", ctypes.c_uint64),
        ("encode_containers", ctypes.c_uint64),
        ("read_pcm_formats", ctypes.c_uint64),
        ("write_pcm_formats", ctypes.c_uint64),
        ("max_channels", ctypes.c_uint32),
        ("max_sample_rate_hz", ctypes.c_uint32),
        ("offline_services", ctypes.c_uint64),
    ]


class _PcmBuffer(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("samples", ctypes.c_void_p),
        ("frames", ctypes.c_uint64),
        ("channel_count", ctypes.c_uint32),
        ("sample_rate_hz", ctypes.c_uint32),
    ]


class _Bytes(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("data", ctypes.c_void_p),
        ("size_bytes", ctypes.c_uint64),
        ("reserved0", ctypes.c_uint32),
        ("reserved1", ctypes.c_uint32),
    ]


class _CodecOptions(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("compression_level", ctypes.c_uint32),
        ("bitrate_kbps", ctypes.c_uint32),
        ("bits_per_sample", ctypes.c_uint32),
        ("wav_is_float", ctypes.c_uint32),
        ("quality", ctypes.c_uint32),
        ("vbr_quality", ctypes.c_uint32),
        ("reserved0", ctypes.c_uint32),
        ("reserved1", ctypes.c_uint32),
    ]


class _SrcOptions(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("source_sample_rate_hz", ctypes.c_uint32),
        ("destination_sample_rate_hz", ctypes.c_uint32),
        ("channel_count", ctypes.c_uint32),
        ("quality", ctypes.c_uint32),
        ("reserved0", ctypes.c_uint32),
        ("reserved1", ctypes.c_uint32),
    ]


class _LoudnessOptions(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("target_lufs", ctypes.c_double),
        ("reserved0", ctypes.c_uint32),
        ("reserved1", ctypes.c_uint32),
    ]


class _LoudnessResult(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("integrated_lufs", ctypes.c_double),
        ("true_peak_dbtp", ctypes.c_double),
        ("gain_to_target_db", ctypes.c_double),
        ("loudness_range_lu", ctypes.c_double),
    ]


class _EngineOptions(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("sample_rate_hz", ctypes.c_uint32),
        ("max_frames", ctypes.c_uint32),
        ("deck_count", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
    ]


class _Control(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("crossfader", ctypes.c_float),
        ("xfade_curve", ctypes.c_float),
        ("master_level", ctypes.c_float),
        ("limiter_ceiling_db", ctypes.c_float),
        ("limiter_enabled", ctypes.c_float),
        ("xfade_assign", ctypes.c_float * 4),
        ("fader", ctypes.c_float * 4),
        ("trim", ctypes.c_float * 4),
    ]


class _OutputView(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("left", ctypes.c_void_p),
        ("right", ctypes.c_void_p),
        ("frames", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
    ]


class _PcmView(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("planes", ctypes.POINTER(ctypes.POINTER(ctypes.c_float))),
        ("frames", ctypes.c_uint64),
        ("channel_count", ctypes.c_uint32),
        ("sample_rate_hz", ctypes.c_uint32),
    ]


class _Command(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("type", ctypes.c_uint32),
        ("deck", ctypes.c_int32),
        ("i0", ctypes.c_int32),
        ("i1", ctypes.c_int32),
        ("i2", ctypes.c_int32),
        ("f0", ctypes.c_float),
        ("f1", ctypes.c_float),
    ]


class _Stats(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("master_frame", ctypes.c_uint64),
        ("starved_frames", ctypes.c_uint64),
        ("deck_count", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
    ]


Samples = Union[Iterable[float], memoryview, array]


class CodecServices:
    """Provides synchronous native codec operations.

    Inputs are copied into temporary native-call storage. Decode results are
    copied into an ``array('f')`` before the native owned buffer is released.
    ``close`` is idempotent and makes subsequent calls fail clearly.
    """

    _ABI_VERSION = 1
    _VBR_CBR = 0xFFFFFFFF

    def __init__(self, library_path: Optional[Union[str, os.PathLike[str]]] = None) -> None:
        self._library = ctypes.CDLL(self._find_library(library_path))
        self._configure_functions()
        self._closed = False

    @staticmethod
    def _find_library(library_path: Optional[Union[str, os.PathLike[str]]]) -> str:
        if library_path is not None:
            return os.fspath(library_path)
        environment_path = os.environ.get("PARSO_AUDIO_LIBRARY")
        if environment_path:
            return environment_path
        discovered = ctypes.util.find_library("parso")
        if discovered:
            return discovered
        raise FileNotFoundError(
            "libparso was not found; pass library_path or set PARSO_AUDIO_LIBRARY"
        )

    def _configure_functions(self) -> None:
        library = self._library
        library.parso_last_error.argtypes = []
        library.parso_last_error.restype = ctypes.c_char_p
        library.parso_capabilities_init.argtypes = [ctypes.POINTER(_Capabilities)]
        library.parso_capabilities_init.restype = ctypes.c_int32
        library.parso_capabilities_get.argtypes = [ctypes.POINTER(_Capabilities)]
        library.parso_capabilities_get.restype = ctypes.c_int32
        library.parso_pcm_buffer_init.argtypes = [ctypes.POINTER(_PcmBuffer)]
        library.parso_pcm_buffer_init.restype = ctypes.c_int32
        library.parso_pcm_buffer_release.argtypes = [ctypes.POINTER(_PcmBuffer)]
        library.parso_pcm_buffer_release.restype = ctypes.c_int32
        library.parso_bytes_init.argtypes = [ctypes.POINTER(_Bytes)]
        library.parso_bytes_init.restype = ctypes.c_int32
        library.parso_bytes_release.argtypes = [ctypes.POINTER(_Bytes)]
        library.parso_bytes_release.restype = ctypes.c_int32
        library.parso_codec_options_init.argtypes = [ctypes.POINTER(_CodecOptions)]
        library.parso_codec_options_init.restype = ctypes.c_int32
        library.parso_codec_read.argtypes = [
            ctypes.POINTER(ctypes.c_uint8),
            ctypes.c_uint64,
            ctypes.c_uint32,
            ctypes.POINTER(_CodecOptions),
            ctypes.POINTER(_PcmBuffer),
        ]
        library.parso_codec_read.restype = ctypes.c_int32
        library.parso_codec_write.argtypes = [
            ctypes.POINTER(_PcmBuffer),
            ctypes.c_uint32,
            ctypes.POINTER(_CodecOptions),
            ctypes.POINTER(_Bytes),
        ]
        library.parso_codec_write.restype = ctypes.c_int32
        library.parso_src_options_init.argtypes = [ctypes.POINTER(_SrcOptions)]
        library.parso_src_options_init.restype = ctypes.c_int32
        library.parso_src_convert.argtypes = [
            ctypes.POINTER(_PcmBuffer),
            ctypes.POINTER(_SrcOptions),
            ctypes.POINTER(_PcmBuffer),
        ]
        library.parso_src_convert.restype = ctypes.c_int32
        library.parso_loudness_options_init.argtypes = [ctypes.POINTER(_LoudnessOptions)]
        library.parso_loudness_options_init.restype = ctypes.c_int32
        library.parso_loudness_result_init.argtypes = [ctypes.POINTER(_LoudnessResult)]
        library.parso_loudness_result_init.restype = ctypes.c_int32
        library.parso_loudness_measure.argtypes = [
            ctypes.POINTER(_PcmBuffer),
            ctypes.POINTER(_LoudnessOptions),
            ctypes.POINTER(_LoudnessResult),
        ]
        library.parso_loudness_measure.restype = ctypes.c_int32

    def close(self) -> None:
        """Close this facade; calling close repeatedly is safe."""

        self._closed = True

    def __enter__(self) -> "CodecServices":
        self._ensure_open()
        return self

    def __exit__(self, _exc_type: object, _exc_value: object, _traceback: object) -> None:
        self.close()

    @property
    def capabilities(self) -> CodecCapabilities:
        """Return the capabilities reported by the loaded native library."""

        self._ensure_open()
        capabilities = _Capabilities(
            size=ctypes.sizeof(_Capabilities), abi_version=self._ABI_VERSION
        )
        self._call("capability initialization", self._library.parso_capabilities_init, capabilities)
        self._call("capability query", self._library.parso_capabilities_get, capabilities)
        return CodecCapabilities(
            ContainerCapability(capabilities.decode_containers),
            ContainerCapability(capabilities.encode_containers),
            capabilities.read_pcm_formats,
            capabilities.write_pcm_formats,
            capabilities.max_channels,
            capabilities.max_sample_rate_hz,
            capabilities.offline_services,
        )

    def encode(
        self,
        samples: Samples,
        sample_rate_hz: int,
        channel_count: int,
        codec: Union[AudioCodec, int],
        options: Optional[CodecOptions] = None,
    ) -> bytes:
        """Encode interleaved float32-compatible samples into owned bytes."""

        self._ensure_open()
        pcm = _as_float_array(samples)
        if not pcm or channel_count not in (1, 2) or sample_rate_hz <= 0:
            raise ValueError("PCM must be non-empty, one or two channel, and have a positive rate")
        if len(pcm) % channel_count:
            raise ValueError("sample count must be divisible by channel_count")
        native_pcm = _PcmBuffer(
            size=ctypes.sizeof(_PcmBuffer),
            abi_version=self._ABI_VERSION,
            samples=ctypes.c_void_p(pcm.buffer_info()[0]),
            frames=len(pcm) // channel_count,
            channel_count=channel_count,
            sample_rate_hz=sample_rate_hz,
        )
        native_options = self._native_options(options)
        output = _Bytes()
        self._call("byte-buffer initialization", self._library.parso_bytes_init, output)
        try:
            status = self._library.parso_codec_write(
                ctypes.byref(native_pcm), int(codec), ctypes.byref(native_options), ctypes.byref(output)
            )
            self._raise_for_status(status, "codec encoding")
            if output.size_bytes > sys.maxsize:
                raise ParsoError(-1, "codec encoding", "output is too large for Python")
            return ctypes.string_at(output.data, output.size_bytes)
        finally:
            self._library.parso_bytes_release(ctypes.byref(output))

    def decode(
        self,
        encoded: Union[bytes, bytearray, memoryview],
        codec: Union[AudioCodec, int],
        options: Optional[CodecOptions] = None,
    ) -> DecodedPcm:
        """Decode complete codec bytes into managed interleaved float32 PCM."""

        self._ensure_open()
        data = bytes(encoded)
        if not data:
            raise ValueError("encoded data cannot be empty")
        native_data = (ctypes.c_uint8 * len(data)).from_buffer_copy(data)
        native_options = self._native_options(options)
        output = _PcmBuffer()
        self._call("PCM-buffer initialization", self._library.parso_pcm_buffer_init, output)
        try:
            status = self._library.parso_codec_read(
                native_data, len(data), int(codec), ctypes.byref(native_options), ctypes.byref(output)
            )
            self._raise_for_status(status, "codec decoding")
            sample_count = output.frames * output.channel_count
            if sample_count > sys.maxsize // 4:
                raise ParsoError(-1, "codec decoding", "output is too large for Python")
            raw = ctypes.string_at(output.samples, sample_count * 4)
            samples = array("f")
            samples.frombytes(raw)
            if sys.byteorder != "little":
                samples.byteswap()
            return DecodedPcm(samples, output.frames, output.channel_count, output.sample_rate_hz)
        finally:
            self._library.parso_pcm_buffer_release(ctypes.byref(output))

    def convert_sample_rate(
        self,
        samples: Samples,
        source_sample_rate_hz: int,
        destination_sample_rate_hz: int,
        channel_count: int,
        quality: int = 0,
    ) -> DecodedPcm:
        """Convert interleaved float32-compatible PCM through native libsamplerate."""

        self._ensure_open()
        pcm = _as_float_array(samples)
        if not pcm or channel_count not in (1, 2) or source_sample_rate_hz <= 0:
            raise ValueError("PCM must be non-empty, one or two channel, and have a positive source rate")
        if destination_sample_rate_hz <= 0 or quality not in (0, 1, 2):
            raise ValueError("destination rate must be positive and quality must be zero, one, or two")
        if len(pcm) % channel_count:
            raise ValueError("sample count must be divisible by channel_count")
        native_input = _PcmBuffer(
            size=ctypes.sizeof(_PcmBuffer),
            abi_version=self._ABI_VERSION,
            samples=ctypes.c_void_p(pcm.buffer_info()[0]),
            frames=len(pcm) // channel_count,
            channel_count=channel_count,
            sample_rate_hz=source_sample_rate_hz,
        )
        options = _SrcOptions(size=ctypes.sizeof(_SrcOptions), abi_version=self._ABI_VERSION)
        self._call("SRC-options initialization", self._library.parso_src_options_init, options)
        options.source_sample_rate_hz = source_sample_rate_hz
        options.destination_sample_rate_hz = destination_sample_rate_hz
        options.channel_count = channel_count
        options.quality = quality
        output = _PcmBuffer()
        self._call("PCM-buffer initialization", self._library.parso_pcm_buffer_init, output)
        try:
            status = self._library.parso_src_convert(
                ctypes.byref(native_input), ctypes.byref(options), ctypes.byref(output)
            )
            self._raise_for_status(status, "sample-rate conversion")
            return self._copy_decoded(output)
        finally:
            self._library.parso_pcm_buffer_release(ctypes.byref(output))

    def measure_loudness(
        self,
        samples: Samples,
        sample_rate_hz: int,
        channel_count: int,
        target_lufs: float = -14.0,
    ) -> LoudnessResult:
        """Measure interleaved float32-compatible PCM through native EBU R128."""

        self._ensure_open()
        pcm = _as_float_array(samples)
        if not pcm or channel_count not in (1, 2) or sample_rate_hz <= 0:
            raise ValueError("PCM must be non-empty, one or two channel, and have a positive rate")
        if len(pcm) % channel_count:
            raise ValueError("sample count must be divisible by channel_count")
        native_input = _PcmBuffer(
            size=ctypes.sizeof(_PcmBuffer),
            abi_version=self._ABI_VERSION,
            samples=ctypes.c_void_p(pcm.buffer_info()[0]),
            frames=len(pcm) // channel_count,
            channel_count=channel_count,
            sample_rate_hz=sample_rate_hz,
        )
        options = _LoudnessOptions(size=ctypes.sizeof(_LoudnessOptions), abi_version=self._ABI_VERSION)
        self._call("loudness-options initialization", self._library.parso_loudness_options_init, options)
        options.target_lufs = target_lufs
        result = _LoudnessResult()
        self._call("loudness-result initialization", self._library.parso_loudness_result_init, result)
        status = self._library.parso_loudness_measure(
            ctypes.byref(native_input), ctypes.byref(options), ctypes.byref(result)
        )
        self._raise_for_status(status, "loudness measurement")
        return LoudnessResult(
            result.integrated_lufs,
            result.true_peak_dbtp,
            result.gain_to_target_db,
            result.loudness_range_lu,
        )

    def _native_options(self, options: Optional[CodecOptions]) -> _CodecOptions:
        selected = options or CodecOptions()
        native = _CodecOptions()
        status = self._library.parso_codec_options_init(ctypes.byref(native))
        self._raise_for_status(status, "codec-options initialization")
        native.compression_level = selected.compression_level
        native.bitrate_kbps = selected.bitrate_kbps
        native.bits_per_sample = selected.bits_per_sample
        native.wav_is_float = int(selected.wav_is_float)
        native.quality = selected.quality
        native.vbr_quality = self._VBR_CBR if selected.vbr_quality is None else selected.vbr_quality
        return native

    @staticmethod
    def _copy_decoded(output: _PcmBuffer) -> DecodedPcm:
        sample_count = output.frames * output.channel_count
        if sample_count > sys.maxsize // 4:
            raise ParsoError(-1, "native PCM copy", "output is too large for Python")
        raw = ctypes.string_at(output.samples, sample_count * 4)
        samples = array("f")
        samples.frombytes(raw)
        if sys.byteorder != "little":
            samples.byteswap()
        return DecodedPcm(samples, output.frames, output.channel_count, output.sample_rate_hz)

    def _ensure_open(self) -> None:
        if self._closed:
            raise ParsoError(-6, "codec service", "service is closed")

    def _call(self, operation: str, function: object, structure: ctypes.Structure) -> None:
        status = function(ctypes.byref(structure))  # type: ignore[union-attr]
        self._raise_for_status(status, operation)

    def _raise_for_status(self, status: int, operation: str) -> None:
        if status == 0:
            return
        detail_bytes = self._library.parso_last_error()
        detail = detail_bytes.decode("utf-8", errors="replace") if detail_bytes else ""
        raise ParsoError(status, operation, detail)


class Engine:
    """Owns a native headless render engine for bounded synchronous callbacks."""

    _ABI_VERSION = 1

    def __init__(
        self,
        sample_rate_hz: int = 48_000,
        max_frames: int = 512,
        deck_count: int = 2,
        library_path: Optional[Union[str, os.PathLike[str]]] = None,
    ) -> None:
        if sample_rate_hz <= 0 or max_frames <= 0 or not 1 <= deck_count <= 4:
            raise ValueError("invalid engine sample rate, block size, or deck count")
        self._library = ctypes.CDLL(CodecServices._find_library(library_path))
        self._configure_functions()
        options = _EngineOptions(
            size=ctypes.sizeof(_EngineOptions), abi_version=self._ABI_VERSION,
            sample_rate_hz=sample_rate_hz, max_frames=max_frames, deck_count=deck_count,
        )
        self._call("engine-options initialization", self._library.parso_engine_options_init, options)
        options.sample_rate_hz = sample_rate_hz
        options.max_frames = max_frames
        options.deck_count = deck_count
        handle = ctypes.c_void_p()
        status = self._library.parso_engine_create(ctypes.byref(options), ctypes.byref(handle))
        self._raise_for_status(status, "engine creation")
        self._handle = handle
        self._max_frames = max_frames
        self._deck_count = deck_count
        self._deck_buffers: dict[int, tuple[tuple[array, ...], object]] = {}

    def _configure_functions(self) -> None:
        library = self._library
        library.parso_last_error.argtypes = []
        library.parso_last_error.restype = ctypes.c_char_p
        library.parso_engine_options_init.argtypes = [ctypes.POINTER(_EngineOptions)]
        library.parso_engine_options_init.restype = ctypes.c_int32
        library.parso_control_init.argtypes = [ctypes.POINTER(_Control)]
        library.parso_control_init.restype = ctypes.c_int32
        library.parso_pcm_view_init.argtypes = [ctypes.POINTER(_PcmView)]
        library.parso_pcm_view_init.restype = ctypes.c_int32
        library.parso_command_init.argtypes = [ctypes.POINTER(_Command)]
        library.parso_command_init.restype = ctypes.c_int32
        library.parso_engine_create.argtypes = [
            ctypes.POINTER(_EngineOptions), ctypes.POINTER(ctypes.c_void_p)
        ]
        library.parso_engine_create.restype = ctypes.c_int32
        library.parso_engine_destroy.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        library.parso_engine_destroy.restype = ctypes.c_int32
        library.parso_engine_set_control.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(_Control)
        ]
        library.parso_engine_set_control.restype = ctypes.c_int32
        library.parso_engine_set_deck_buffer.argtypes = [
            ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(_PcmView)
        ]
        library.parso_engine_set_deck_buffer.restype = ctypes.c_int32
        library.parso_engine_post_command.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(_Command)
        ]
        library.parso_engine_post_command.restype = ctypes.c_int32
        library.parso_engine_render.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(_OutputView)
        ]
        library.parso_engine_render.restype = ctypes.c_int32
        library.parso_engine_get_stats.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(_Stats)
        ]
        library.parso_engine_get_stats.restype = ctypes.c_int32
        library.parso_engine_record_set_active.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        library.parso_engine_record_set_active.restype = ctypes.c_int32
        library.parso_engine_record_drain.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_float),
            ctypes.POINTER(ctypes.c_float),
            ctypes.c_uint32,
            ctypes.POINTER(ctypes.c_uint32),
        ]
        library.parso_engine_record_drain.restype = ctypes.c_int32
        library.parso_engine_record_dropped_frames.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint64)
        ]
        library.parso_engine_record_dropped_frames.restype = ctypes.c_int32
        library.parso_engine_record_reset.argtypes = [ctypes.c_void_p]
        library.parso_engine_record_reset.restype = ctypes.c_int32

    def close(self) -> None:
        """Destroy the native engine; calling close repeatedly is safe."""

        if getattr(self, "_handle", None) and self._handle.value:
            status = self._library.parso_engine_destroy(ctypes.byref(self._handle))
            self._raise_for_status(status, "engine destruction")
            self._handle = ctypes.c_void_p()
            self._deck_buffers.clear()

    def __enter__(self) -> "Engine":
        self._ensure_open()
        return self

    def __exit__(self, _exc_type: object, _exc_value: object, _traceback: object) -> None:
        self.close()

    def set_master_level(self, level: float) -> None:
        """Set the linear master level used by subsequent renders."""

        self._ensure_open()
        control = _Control(size=ctypes.sizeof(_Control), abi_version=self._ABI_VERSION)
        self._call("control initialization", self._library.parso_control_init, control)
        control.master_level = level
        status = self._library.parso_engine_set_control(
            self._handle, ctypes.byref(control)
        )
        self._raise_for_status(status, "setting engine control")

    def set_deck_buffer(
        self,
        deck: int,
        samples: Samples,
        sample_rate_hz: int,
        channel_count: int,
    ) -> None:
        """Install copied interleaved PCM for a deck and retain it until replacement."""

        self._ensure_open()
        if deck < 0 or deck >= self._deck_count:
            raise ValueError("deck is out of range")
        pcm = _as_float_array(samples)
        if not pcm or channel_count not in (1, 2) or sample_rate_hz <= 0:
            raise ValueError("PCM must be non-empty, one or two channel, and have a positive rate")
        if len(pcm) % channel_count:
            raise ValueError("sample count must be divisible by channel_count")
        channel_planes = tuple(
            array("f", pcm[index::channel_count]) for index in range(channel_count)
        )
        pointer_type = ctypes.POINTER(ctypes.c_float)
        planes = (pointer_type * channel_count)()
        for index, channel in enumerate(channel_planes):
            planes[index] = ctypes.cast(channel.buffer_info()[0], pointer_type)
        view = _PcmView(
            size=ctypes.sizeof(_PcmView), abi_version=self._ABI_VERSION,
            planes=planes, frames=len(pcm) // channel_count,
            channel_count=channel_count, sample_rate_hz=sample_rate_hz,
        )
        status = self._library.parso_engine_set_deck_buffer(
            self._handle, deck, ctypes.byref(view)
        )
        self._raise_for_status(status, "setting deck buffer")
        self._deck_buffers[deck] = (channel_planes, planes)

    def post_command(
        self,
        command_type: Union[EngineCommand, int],
        deck: int = -1,
        *,
        i0: int = 0,
        i1: int = 0,
        i2: int = 0,
        f0: float = 0.0,
        f1: float = 0.0,
    ) -> None:
        """Queue one ABI command with explicit POD payload fields.

        ``deck`` may be ``-1`` for global commands. The command is copied into
        the native SPSC queue and applied at the next render boundary.
        """

        self._ensure_open()
        if deck < -1 or deck >= self._deck_count:
            raise ValueError("deck is out of range")
        command = _Command(size=ctypes.sizeof(_Command), abi_version=self._ABI_VERSION)
        self._call("command initialization", self._library.parso_command_init, command)
        command.type = int(command_type)
        command.deck = deck
        command.i0 = i0
        command.i1 = i1
        command.i2 = i2
        command.f0 = f0
        command.f1 = f1
        status = self._library.parso_engine_post_command(
            self._handle, ctypes.byref(command)
        )
        self._raise_for_status(status, "posting engine command")

    def play(self, deck: int) -> None:
        """Queue the portable play command for a deck."""

        self.post_command(EngineCommand.PLAY, deck)

    def pause(self, deck: int) -> None:
        """Queue the portable pause command for a deck."""

        self.post_command(EngineCommand.PAUSE, deck)

    def seek(self, deck: int, seconds: float) -> None:
        """Seek a deck to an absolute position in seconds."""

        if not math.isfinite(seconds) or seconds < 0.0:
            raise ValueError("seconds must be finite and non-negative")
        self.post_command(EngineCommand.SEEK, deck, f0=seconds)

    def set_keylock(self, deck: int, enabled: bool) -> None:
        """Enable or disable a deck's time/pitch key lock."""

        self.post_command(EngineCommand.SET_KEYLOCK, deck, f0=float(enabled))

    def set_slip(self, deck: int, enabled: bool) -> None:
        """Enable or disable slip transport for a deck."""

        self.post_command(EngineCommand.SET_SLIP, deck, f0=float(enabled))

    def render(self, frames: int) -> tuple[array, array]:
        """Render a bounded stereo block into newly allocated managed arrays."""

        self._ensure_open()
        if frames <= 0 or frames > self._max_frames:
            raise ValueError("frames must be positive and no greater than max_frames")
        left = array("f", [0.0]) * frames
        right = array("f", [0.0]) * frames
        output = _OutputView(
            size=ctypes.sizeof(_OutputView), abi_version=self._ABI_VERSION,
            left=ctypes.c_void_p(left.buffer_info()[0]),
            right=ctypes.c_void_p(right.buffer_info()[0]), frames=frames,
        )
        status = self._library.parso_engine_render(
            self._handle, ctypes.byref(output)
        )
        self._raise_for_status(status, "engine render")
        return left, right

    def stats(self) -> EngineStats:
        """Return native render counters and deck topology."""

        self._ensure_open()
        stats = _Stats(size=ctypes.sizeof(_Stats), abi_version=self._ABI_VERSION)
        self._call("stats initialization", self._library.parso_stats_init, stats)
        status = self._library.parso_engine_get_stats(self._handle, ctypes.byref(stats))
        self._raise_for_status(status, "reading engine stats")
        return EngineStats(stats.master_frame, stats.starved_frames, stats.deck_count)

    def set_record_active(self, active: bool) -> None:
        """Enable or disable the bounded native master record ring."""

        self._ensure_open()
        status = self._library.parso_engine_record_set_active(self._handle, int(active))
        self._raise_for_status(status, "setting record state")

    def record_drain(self, max_frames: int) -> tuple[array, array]:
        """Drain up to ``max_frames`` from the native master record ring."""

        self._ensure_open()
        if max_frames <= 0:
            raise ValueError("max_frames must be positive")
        left = array("f", [0.0]) * max_frames
        right = array("f", [0.0]) * max_frames
        out_frames = ctypes.c_uint32()
        float_pointer = ctypes.POINTER(ctypes.c_float)
        status = self._library.parso_engine_record_drain(
            self._handle,
            ctypes.cast(left.buffer_info()[0], float_pointer),
            ctypes.cast(right.buffer_info()[0], float_pointer),
            max_frames,
            ctypes.byref(out_frames),
        )
        self._raise_for_status(status, "draining record ring")
        return left[:out_frames.value], right[:out_frames.value]

    def record_dropped_frames(self) -> int:
        """Return the number of frames discarded because the record ring filled."""

        self._ensure_open()
        dropped = ctypes.c_uint64()
        status = self._library.parso_engine_record_dropped_frames(
            self._handle, ctypes.byref(dropped)
        )
        self._raise_for_status(status, "reading record counter")
        return dropped.value

    def record_reset(self) -> None:
        """Discard pending record frames and reset the dropped-frame counter."""

        self._ensure_open()
        status = self._library.parso_engine_record_reset(self._handle)
        self._raise_for_status(status, "resetting record ring")

    def _ensure_open(self) -> None:
        if not getattr(self, "_handle", None) or not self._handle.value:
            raise ParsoError(-6, "engine", "engine is closed")

    def _call(self, operation: str, function: object, structure: ctypes.Structure) -> None:
        status = function(ctypes.byref(structure))  # type: ignore[union-attr]
        self._raise_for_status(status, operation)

    def _raise_for_status(self, status: int, operation: str) -> None:
        if status == 0:
            return
        detail_bytes = self._library.parso_last_error()
        detail = detail_bytes.decode("utf-8", errors="replace") if detail_bytes else ""
        raise ParsoError(status, operation, detail)


def _as_float_array(samples: Samples) -> array:
    """Copy one-dimensional float-compatible buffer data into native float storage."""

    if isinstance(samples, array) and samples.typecode == "f":
        return array("f", samples)
    try:
        view = memoryview(samples)
    except TypeError:
        return array("f", samples)
    if view.ndim != 1 or not view.c_contiguous:
        raise ValueError("samples must be a contiguous one-dimensional buffer")
    try:
        values = view.tolist()
    except TypeError as error:
        raise ValueError("samples must contain numeric values") from error
    return array("f", values)


__all__ = [
    "AudioCodec",
    "EngineCommand",
    "CodecCapabilities",
    "CodecOptions",
    "CodecServices",
    "ContainerCapability",
    "DecodedPcm",
    "Engine",
    "EngineStats",
    "LoudnessResult",
    "ParsoError",
]
