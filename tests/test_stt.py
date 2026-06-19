import importlib.util
from importlib.machinery import SourceFileLoader
import struct
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "stt"
SPEC = importlib.util.spec_from_loader(
    "stt_cli",
    SourceFileLoader("stt_cli", str(MODULE_PATH)),
)
stt = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stt)


class AudioHelpersTests(unittest.TestCase):
    def test_build_wav_header_matches_payload(self):
        pcm = struct.pack("<4h", 0, 1000, -1000, 0)
        wav = stt._build_wav(pcm)

        self.assertEqual(wav[:4], b"RIFF")
        self.assertEqual(wav[8:12], b"WAVE")
        self.assertEqual(struct.unpack("<I", wav[40:44])[0], len(pcm))
        self.assertEqual(wav[44:], pcm)

    def test_audio_rms_silence_and_signal(self):
        silence = struct.pack("<1600h", *([0] * 1600))
        signal = struct.pack("<1600h", *([4096] * 1600))

        self.assertEqual(stt._audio_rms(silence), 0.0)
        self.assertAlmostEqual(stt._audio_rms(signal), 0.125, places=3)

    def test_has_speech_requires_sustained_frames(self):
        silence = struct.pack("<8000h", *([0] * 8000))
        signal = struct.pack("<8000h", *([4096] * 8000))

        self.assertFalse(stt._has_speech(silence))
        self.assertTrue(stt._has_speech(signal))


class HallucinationTests(unittest.TestCase):
    def test_filters_known_artifacts(self):
        self.assertTrue(stt._is_hallucination("(keyboard clicking)"))
        self.assertTrue(stt._is_hallucination("字幕由自动生成"))
        self.assertTrue(stt._is_hallucination("[BLANK_AUDIO]"))

    def test_keeps_normal_text(self):
        self.assertFalse(stt._is_hallucination("今天下午三点开会。"))
        self.assertFalse(stt._is_hallucination("Please send the report tomorrow."))


if __name__ == "__main__":
    unittest.main()
