"""Small, ownership-safe Python facade over the Parso native C ABI."""

from __future__ import annotations

from array import array
import ctypes
from dataclasses import dataclass
from enum import IntEnum, IntFlag
import ctypes.util
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
    "CodecCapabilities",
    "CodecOptions",
    "CodecServices",
    "ContainerCapability",
    "DecodedPcm",
    "LoudnessResult",
    "ParsoError",
]
