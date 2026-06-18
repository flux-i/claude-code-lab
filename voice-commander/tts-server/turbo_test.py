#!/usr/bin/env python3
"""Turbo-only warm speed test on the British reference. Saves + plays each clip."""
import os
import time
import wave
import numpy as np
import torch

REF = os.path.expanduser("~/.claude/voice/tts-server/reference.wav")
DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"
SENTENCES = [
    ("short",  "Done. The build is green."),
    ("medium", "I've created the branch and run the tests. Forty-eight passed, and nothing failed."),
    ("long",   "Here is a summary of what I changed. I refactored the parser, added three new tests, "
               "updated the documentation, and pushed everything to a new branch for your review."),
]

def save_wav(wav, sr, path):
    audio = np.clip(wav.detach().to("cpu").float().numpy().squeeze(), -1.0, 1.0)
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
        w.writeframes((audio * 32767.0).astype("<i2").tobytes())
    return len(audio) / sr

from chatterbox.tts_turbo import ChatterboxTurboTTS
print(f"=== TURBO (loading on {DEVICE}) ===", flush=True)
m = ChatterboxTurboTTS.from_pretrained(device=DEVICE)
print("warming up…", flush=True)
with torch.no_grad():
    m.generate("Hello there.", audio_prompt_path=REF, temperature=0.8)
print("--- warm results ---", flush=True)
for i, (label, text) in enumerate(SENTENCES):
    t0 = time.time()
    with torch.no_grad():
        wav = m.generate(text, audio_prompt_path=REF, temperature=0.8)
    gen = time.time() - t0
    path = f"/tmp/turbo_{label}.wav"
    dur = save_wav(wav, m.sr, path)
    print(f"  {label:7s} gen={gen:5.1f}s  audio={dur:4.1f}s  ratio={gen/dur:.2f}x", flush=True)
    os.system(f"afplay {path}")
    time.sleep(0.4)
print("DONE", flush=True)
