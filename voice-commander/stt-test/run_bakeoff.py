#!/usr/bin/env python3
"""STT bake-off: Apple on-device (current ClaudeVoice path) vs Spokenly (gpt-4o-mini-transcribe, cloud).

Corpus = the user's real Spokenly History (identical audio for both engines).
Spokenly's transcript is the REFERENCE — note it is NOT perfect ground truth
(a few short technical clips were themselves mis-transcribed, some into Urdu),
so WER here means "disagreement with the cloud model", not absolute error.
"""
import json, os, glob, subprocess, re, sys, unicodedata

HIST = os.path.expanduser("~/Library/Containers/app.spokenly/Data/Library/Application Support/Spokenly/History")
HERE = os.path.dirname(os.path.abspath(__file__))
APPLE = os.path.join(HERE, "apple-stt")

def load_pairs():
    pairs = []
    for js in sorted(glob.glob(os.path.join(HIST, "*", "*.json"))):
        try:
            d = json.load(open(js))
            res = d["content"]["dictation"]["_0"]["success"]["_0"]["result"]
        except Exception:
            continue
        td = res.get("transcriptionData", {})
        ref = " ".join(s.get("text", "") for s in td.get("segments", [])).strip()
        m4a = js[:-5] + ".m4a"
        if not os.path.exists(m4a):
            continue
        pairs.append({
            "date": os.path.basename(os.path.dirname(js)),
            "id": os.path.basename(js)[:8],
            "m4a": m4a,
            "dur": float(res.get("audioFile", {}).get("duration", 0)),
            "spokenly": ref,
        })
    return pairs

def is_nonlatin(s):
    return any(unicodedata.category(c).startswith("L") and ord(c) > 0x2bf for c in s)

def norm(s):
    s = s.lower()
    s = re.sub(r"[^\w\s]", " ", s)          # drop punctuation
    s = re.sub(r"\s+", " ", s).strip()
    return s

def wer(ref, hyp):
    r, h = norm(ref).split(), norm(hyp).split()
    if not r:
        return (0.0 if not h else 1.0), len(r), len(h)
    # Levenshtein on words
    dp = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, dp[0] = dp[0], i
        for j in range(1, len(h) + 1):
            cur = dp[j]
            dp[j] = min(dp[j] + 1, dp[j-1] + 1, prev + (r[i-1] != h[j-1]))
            prev = cur
    return dp[len(h)] / len(r), len(r), len(h)

CACHE = os.path.join(HERE, "apple_results.json")

def run_apple(pairs):
    # Cache Apple output so re-analysis is instant; pass --fresh to recompute.
    if os.path.exists(CACHE) and "--fresh" not in sys.argv:
        return {o["file"]: o for o in json.load(open(CACHE))}
    files = [p["m4a"] for p in pairs]
    out = subprocess.run([APPLE] + files, capture_output=True, text=True)
    if out.returncode != 0:
        print("apple-stt failed:\n", out.stderr, file=sys.stderr); sys.exit(1)
    arr = json.loads(out.stdout)
    json.dump(arr, open(CACHE, "w"), indent=2)
    return {o["file"]: o for o in arr}

def main():
    pairs = load_pairs()
    print(f"Corpus: {len(pairs)} clips from {HIST}\n")
    apple = run_apple(pairs)

    rows, total_ref_words, total_errs = [], 0, 0
    apple_time, total_dur = 0, 0
    exact = 0
    scored = 0
    for p in pairs:
        a = apple.get(p["m4a"], {})
        ahyp = a.get("transcript", "")
        w, rwords, _ = wer(p["spokenly"], ahyp)
        flag = ""
        if not p["spokenly"].strip():
            flag = "SILENCE"        # reference empty
        elif is_nonlatin(p["spokenly"]):
            flag = "REF-NONLATIN"   # Spokenly itself produced Urdu/garbage
        else:
            total_ref_words += rwords
            total_errs += round(w * rwords)
            scored += 1
            if norm(p["spokenly"]) == norm(ahyp):
                exact += 1
        apple_time += a.get("elapsedMs", 0)
        total_dur += p["dur"]
        rows.append((p, ahyp, w, flag, a.get("elapsedMs", 0)))

    # ---- per-clip detail ----
    for p, ahyp, w, flag, ms in rows:
        tag = f" [{flag}]" if flag else ""
        head = f"{p['date']} {p['id']} ({p['dur']:.1f}s, apple {ms}ms){tag}"
        if flag:
            print(f"\n■ {head}\n  WER:    n/a")
        else:
            print(f"\n■ {head}\n  WER:    {w*100:.0f}%")
        print(f"  spokenly: {p['spokenly']!r}")
        print(f"  apple:    {ahyp!r}")

    agg = (total_errs / total_ref_words * 100) if total_ref_words else 0

    # --- duration buckets + reliability (severe drop = Apple returned <30% of ref words) ---
    buckets = {"≤6s (commands)": [0,0,0,0], "6–20s (medium)": [0,0,0,0], ">20s (long)": [0,0,0,0]}
    severe = []   # voiced-latin clips where Apple lost most of the words
    for p, ahyp, w, flag, ms in rows:
        if flag:
            continue
        b = "≤6s (commands)" if p["dur"] <= 6 else ("6–20s (medium)" if p["dur"] <= 20 else ">20s (long)")
        rw = len(norm(p["spokenly"]).split())
        buckets[b][0] += 1
        buckets[b][1] += round(w * rw)
        buckets[b][2] += rw
        if rw and len(norm(ahyp).split()) < 0.3 * rw:
            severe.append((p, ahyp))

    print("\n" + "=" * 70)
    print("SUMMARY  (Apple on-device vs Spokenly/gpt-4o-mini-transcribe reference)")
    print("=" * 70)
    print(f"clips total              : {len(pairs)}")
    print(f"  scored (latin, voiced) : {scored}")
    print(f"  silence (ref empty)    : {sum(1 for r in rows if r[3]=='SILENCE')}")
    print(f"  ref non-latin (Spokenly cloud itself mis-fired to Urdu): "
          f"{sum(1 for r in rows if r[3]=='REF-NONLATIN')}")
    print(f"aggregate word error rate: {agg:.1f}%   (lower = closer to cloud)")
    print(f"exact matches (scored)   : {exact}/{scored}")
    print()
    print("WER by clip length (the use case lives in ≤6s commands):")
    for b, (n, e, rw, _) in buckets.items():
        if n:
            print(f"  {b:18s}: {e/rw*100:5.1f}%  over {n} clips / {rw} ref words")
    print()
    print(f"RELIABILITY — Apple severely dropped/empty on {len(severe)} voiced clips "
          f"(returned <30% of the words):")
    for p, ahyp in severe:
        print(f"  · {p['id']} ({p['dur']:.0f}s): apple={ahyp[:40]!r}  vs  {p['spokenly'][:50]!r}…")
    print()
    print(f"apple compute time       : {apple_time/1000:.1f}s for {total_dur:.1f}s audio "
          f"({apple_time/10/total_dur:.0f}% of realtime), $0, fully offline")
    print(f"spokenly                 : OpenAI gpt-4o-mini-transcribe, per-call cost, "
          f"needs network (free tier capped 50/80)")

if __name__ == "__main__":
    main()
