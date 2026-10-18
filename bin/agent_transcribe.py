#!/usr/bin/env python3
import sys
import os

if len(sys.argv) < 2:
    sys.exit(1)

wav_path = sys.argv[1]
if not os.path.exists(wav_path) or os.path.getsize(wav_path) == 0:
    print("")
    sys.exit(0)

try:
    from faster_whisper import WhisperModel
    model = WhisperModel("base.en", device="cpu", compute_type="int8")
    segments, _ = model.transcribe(wav_path, beam_size=5)
    text = " ".join([seg.text.strip() for seg in segments if seg.text.strip()])
    print(text.strip())
except Exception as e:
    sys.stderr.write(f"Transcription error: {e}\n")
    sys.exit(1)
