#!/usr/bin/env python3
"""Chatterbox TTS server for ClaudeVoice.

Loads Resemble AI's Chatterbox model once and serves synthesized speech over a
tiny local HTTP API. The Swift app POSTs the reply text and plays back the WAV.

Endpoints
  GET  /health  -> 200 "ok" once the model is loaded
  POST /tts     -> body {"text": "...", "exaggeration"?: f, "cfg_weight"?: f}
                   returns audio/wav (16-bit PCM, mono, model sample rate)

Config via env (with sensible defaults for a lively-but-stable assistant voice):
  TTS_PORT          listen port                 (default 8765)
  TTS_EXAGGERATION  expressiveness 0.25..1.0    (default 0.6)
  TTS_CFG           guidance / pacing 0.0..1.0  (default 0.4, lower = more expressive)
  TTS_VOICE         path to a reference .wav for zero-shot voice cloning (optional)
  TTS_DEVICE        force mps|cuda|cpu          (default: auto)
"""

import io
import os
import re
import sys
import json
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
import torch
from chatterbox.tts import ChatterboxTTS

PORT = int(os.environ.get("TTS_PORT", "8765"))
EXAG = float(os.environ.get("TTS_EXAGGERATION", "0.6"))
CFG = float(os.environ.get("TTS_CFG", "0.4"))
TEMP = float(os.environ.get("TTS_TEMPERATURE", "0.8"))
VOICE = os.environ.get("TTS_VOICE", "").strip()
# "turbo" = fast path (~1x real-time, ignores exaggeration/cfg); "standard" = expressive but slow.
MODEL_KIND = os.environ.get("TTS_MODEL", "turbo").strip().lower()
# Long replies sent as ONE generate() call make Chatterbox rush its prosody (the
# "bullet train" effect). We split a reply into sentence-sized chunks (<= MAX_CHUNK
# chars), synth each at a natural pace, and stitch them with GAP_MS of silence so
# sentence boundaries get real pauses. Both are tunable via env.
MAX_CHUNK = int(os.environ.get("TTS_MAX_CHUNK", "240"))
GAP_MS = int(os.environ.get("TTS_GAP_MS", "300"))


def pick_device() -> str:
    forced = os.environ.get("TTS_DEVICE", "").strip()
    if forced:
        return forced
    if torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


DEVICE = pick_device()
print(f"[chatterbox] loading {MODEL_KIND} model on {DEVICE} … (first run downloads weights)", flush=True)
if MODEL_KIND == "turbo":
    from chatterbox.tts_turbo import ChatterboxTurboTTS
    MODEL = ChatterboxTurboTTS.from_pretrained(device=DEVICE)
else:
    MODEL = ChatterboxTTS.from_pretrained(device=DEVICE)
SR = MODEL.sr
print(
    f"[chatterbox] ready on 127.0.0.1:{PORT}  model={MODEL_KIND} "
    f"sr={SR} temp={TEMP} voice={VOICE or 'default'}",
    flush=True,
)


def to_wav_bytes(wav, sr: int) -> bytes:
    """Encode a Chatterbox output tensor (1, N) float[-1,1] as 16-bit PCM WAV."""
    audio = wav.detach().to("cpu").float().numpy().squeeze()
    audio = np.clip(audio, -1.0, 1.0)
    pcm = (audio * 32767.0).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())
    return buf.getvalue()


def split_text(text: str, max_chunk: int = MAX_CHUNK) -> list:
    """Break a reply into sentence-sized chunks so the model keeps a natural pace.

    Long single-shot inputs make Chatterbox compress its timing; short ones don't.
    Splits on sentence boundaries, greedily packs sentences up to max_chunk chars,
    and hard-splits any single over-long sentence on a comma (or length as a last
    resort) so no chunk is big enough to trigger the rushing.
    """
    text = re.sub(r"\s+", " ", text.strip())
    if not text:
        return []
    sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]
    chunks: list = []
    cur = ""
    for s in sentences:
        while len(s) > max_chunk:
            cut = s.rfind(",", 0, max_chunk)
            if cut < max_chunk // 2:
                cut = max_chunk
            chunks.append(s[:cut].strip())
            s = s[cut:].strip()
        if not cur:
            cur = s
        elif len(cur) + 1 + len(s) <= max_chunk:
            cur += " " + s
        else:
            chunks.append(cur)
            cur = s
    if cur:
        chunks.append(cur)
    return chunks


def synth(text: str, exaggeration: float, cfg_weight: float) -> bytes:
    if MODEL_KIND == "turbo":
        kwargs = {"temperature": TEMP}  # turbo ignores exaggeration/cfg_weight
    else:
        kwargs = {"exaggeration": exaggeration, "cfg_weight": cfg_weight}
    if VOICE and os.path.exists(VOICE):
        kwargs["audio_prompt_path"] = VOICE

    chunks = split_text(text) or [text]
    gap = torch.zeros(1, max(1, int(SR * GAP_MS / 1000.0)))
    segments = []
    with torch.no_grad():
        for i, chunk in enumerate(chunks):
            wav = MODEL.generate(chunk, **kwargs).detach().to("cpu").float()
            if wav.dim() == 1:
                wav = wav.unsqueeze(0)
            segments.append(wav)
            if i < len(chunks) - 1:
                segments.append(gap)
    full = torch.cat(segments, dim=1) if len(segments) > 1 else segments[0]
    return to_wav_bytes(full, SR)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # silence per-request logging
        pass

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path != "/tts":
            self.send_response(404)
            self.end_headers()
            return
        try:
            n = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(n) or b"{}")
            text = (payload.get("text") or "").strip()
            if not text:
                self.send_response(400)
                self.end_headers()
                return
            exaggeration = float(payload.get("exaggeration", EXAG))
            cfg_weight = float(payload.get("cfg_weight", CFG))
            audio = synth(text, exaggeration, cfg_weight)
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(audio)))
            self.end_headers()
            self.wfile.write(audio)
        except BrokenPipeError:
            pass  # client (Swift) stopped/replaced playback — fine
        except Exception as e:  # noqa: BLE001 - log and 500, never crash the server
            sys.stderr.write(f"[chatterbox] error: {e}\n")
            sys.stderr.flush()
            try:
                self.send_response(500)
                self.end_headers()
            except Exception:
                pass


if __name__ == "__main__":
    # Warm up: the first generation compiles MPS kernels (~tens of seconds). Doing
    # it once here at boot means the first *real* reply is fast, not a cold stall.
    try:
        print("[chatterbox] warming up …", flush=True)
        synth("Hello there.", EXAG, CFG)
        print("[chatterbox] warmup done — ready for requests", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"[chatterbox] warmup skipped: {e}", flush=True)

    # serialize generation: one model, requests handled one at a time is fine
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
