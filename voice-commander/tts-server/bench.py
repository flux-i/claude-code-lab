#!/usr/bin/env python3
"""Benchmark Chatterbox standard vs Turbo: warm gen time + real-time ratio.

Saves a wav per (model, sentence) to /tmp/bench_<model>_<i>.wav for A/B listening.
Run with the venv python:  ~/.claude/voice/tts-server/.venv/bin/python bench.py
"""
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
    audio = wav.detach().to("cpu").float().numpy().squeeze()
    audio = np.clip(audio, -1.0, 1.0)
    pcm = (audio * 32767.0).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr); w.writeframes(pcm.tobytes())
    return len(pcm) / sr


def bench_standard():
    from chatterbox.tts import ChatterboxTTS
    print(f"\n=== STANDARD (loading on {DEVICE}) ===", flush=True)
    m = ChatterboxTTS.from_pretrained(device=DEVICE)
    print("warming up…", flush=True)
    with torch.no_grad():
        m.generate("Hello there.", audio_prompt_path=REF, exaggeration=0.5, cfg_weight=0.5)
    rows = []
    for i, (label, text) in enumerate(SENTENCES):
        t0 = time.time()
        with torch.no_grad():
            wav = m.generate(text, audio_prompt_path=REF, exaggeration=0.5, cfg_weight=0.5)
        gen = time.time() - t0
        dur = save_wav(wav, m.sr, f"/tmp/bench_standard_{i}.wav")
        rows.append((label, gen, dur))
        print(f"  {label:7s} gen={gen:5.1f}s  audio={dur:4.1f}s  ratio={gen/dur:.2f}x", flush=True)
    del m
    if DEVICE == "mps":
        torch.mps.empty_cache()
    return rows


def bench_turbo():
    from chatterbox.tts_turbo import ChatterboxTurboTTS
    print(f"\n=== TURBO (downloading/loading on {DEVICE}) ===", flush=True)
    m = ChatterboxTurboTTS.from_pretrained(device=DEVICE)
    print("warming up…", flush=True)
    with torch.no_grad():
        m.generate("Hello there.", audio_prompt_path=REF, temperature=0.8)
    rows = []
    for i, (label, text) in enumerate(SENTENCES):
        t0 = time.time()
        with torch.no_grad():
            wav = m.generate(text, audio_prompt_path=REF, temperature=0.8)
        gen = time.time() - t0
        dur = save_wav(wav, m.sr, f"/tmp/bench_turbo_{i}.wav")
        rows.append((label, gen, dur))
        print(f"  {label:7s} gen={gen:5.1f}s  audio={dur:4.1f}s  ratio={gen/dur:.2f}x", flush=True)
    del m
    if DEVICE == "mps":
        torch.mps.empty_cache()
    return rows


if __name__ == "__main__":
    std = bench_standard()
    tur = bench_turbo()
    print("\n=== SUMMARY (gen seconds / ratio) ===", flush=True)
    print(f"{'sentence':8s} {'standard':>16s} {'turbo':>16s} {'speedup':>8s}", flush=True)
    for (l, gs, ds), (_, gt, dt) in zip(std, tur):
        print(f"{l:8s} {gs:6.1f}s {gs/ds:5.2f}x   {gt:6.1f}s {gt/dt:5.2f}x   {gs/gt:5.2f}x", flush=True)
