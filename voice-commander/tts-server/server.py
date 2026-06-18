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
import struct
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
# Streaming uses smaller per-sentence chunks than the batch path so synthesis keeps
# pace with playback (fewer/no gaps after the first word). 90 was measured as the
# sweet spot on M3 Pro: ~2.4s to first word, ~0.75s total gap, then gapless (synth
# stays >1x real-time so it never falls behind, even on long replies). Tunable via env.
STREAM_MAX_CHUNK = int(os.environ.get("TTS_STREAM_MAX_CHUNK", "90"))


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

# Prepare the voice conditioning ONCE. Previously synth() passed audio_prompt_path
# on *every* generate() call, so Chatterbox re-encoded the reference wav (voice
# encoder + s3gen embed) for each sentence of a reply — pure repeated work. We do it
# a single time here and reuse the cached MODEL.conds for all chunks.
if VOICE and os.path.exists(VOICE):
    print(f"[chatterbox] preparing voice conditionals once from {VOICE} …", flush=True)
    MODEL.prepare_conditionals(VOICE)

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


def _sentences(text: str, max_chunk: int) -> list:
    """Split text into sentences, hard-splitting any sentence longer than max_chunk
    on a comma (or length as a last resort) so no single piece is huge."""
    text = re.sub(r"\s+", " ", text.strip())
    if not text:
        return []
    out: list = []
    for s in (p.strip() for p in re.split(r"(?<=[.!?])\s+", text) if p.strip()):
        while len(s) > max_chunk:
            cut = s.rfind(",", 0, max_chunk)
            if cut < max_chunk // 2:
                cut = max_chunk
            out.append(s[:cut].strip())
            s = s[cut:].strip()
        if s:
            out.append(s)
    return out


def _pack(sentences: list, max_chunk: int) -> list:
    """Greedily pack sentences into chunks up to max_chunk chars."""
    chunks: list = []
    cur = ""
    for s in sentences:
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


def split_text(text: str, max_chunk: int = MAX_CHUNK) -> list:
    """Batch chunking: pack sentences up to max_chunk so the model keeps a natural
    pace (long single-shot inputs make Chatterbox rush; packed sentences don't)."""
    return _pack(_sentences(text, max_chunk), max_chunk)


def split_stream(text: str, max_chunk: int = STREAM_MAX_CHUNK) -> list:
    """Streaming chunking: small per-sentence chunks (long sentences hard-split on
    commas to <= max_chunk). Kept deliberately short and uniform so that, with synth
    running near real-time, each chunk finishes before the previous one stops
    playing — first word in ~2-3s AND minimal gaps after it. Packing sentences into
    big chunks (as the batch path does) reintroduces the stall we're avoiding."""
    return _sentences(text, max_chunk)


def synth_segments(text: str, exaggeration: float, cfg_weight: float, stream: bool = False):
    """Yield one wav tensor (1, N) per chunk, in order.

    The voice conditioning is prepared once at startup (see above), so we never
    pass audio_prompt_path here — each chunk reuses the cached MODEL.conds. The
    batch endpoint (/tts) packs sentences for an even pace; the streaming endpoint
    (/tts_stream) uses the ramp split so the first sentence ships on its own and
    speech starts in ~1-2s regardless of reply length.
    """
    if MODEL_KIND == "turbo":
        kwargs = {"temperature": TEMP}  # turbo ignores exaggeration/cfg_weight
    else:
        kwargs = {"exaggeration": exaggeration, "cfg_weight": cfg_weight}

    chunks = (split_stream(text) if stream else split_text(text)) or [text]
    with torch.no_grad():
        for chunk in chunks:
            wav = MODEL.generate(chunk, **kwargs).detach().to("cpu").float()
            if wav.dim() == 1:
                wav = wav.unsqueeze(0)
            yield wav


def synth(text: str, exaggeration: float, cfg_weight: float) -> bytes:
    """Batch path: synthesize the whole reply and return one WAV (sentence gaps)."""
    gap = torch.zeros(1, max(1, int(SR * GAP_MS / 1000.0)))
    segments = []
    for i, wav in enumerate(synth_segments(text, exaggeration, cfg_weight)):
        if i:
            segments.append(gap)
        segments.append(wav)
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
        if self.path not in ("/tts", "/tts_stream"):
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
            if self.path == "/tts_stream":
                # Stream one self-contained WAV per sentence chunk, framed as
                # [4-byte big-endian length][wav bytes], flushed the instant each is
                # ready. The client plays each as it arrives, so the first word is
                # heard in ~1-2s no matter how long the whole reply is.
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.end_headers()
                for wav in synth_segments(text, exaggeration, cfg_weight, stream=True):
                    b = to_wav_bytes(wav, SR)
                    self.wfile.write(struct.pack(">I", len(b)))
                    self.wfile.write(b)
                    self.wfile.flush()
                return
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
