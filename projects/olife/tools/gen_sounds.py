#!/usr/bin/env python3
"""UX A2 (03.10, olife_a2): short synthesized feedback sounds for the events the user's prototype had no sound for
(content/olife_client/sounds/olife/fx_*.wav, 22050 Hz mono 16-bit, 0.08-0.45 s). Deterministic (no randomness
except a seeded noise burst). The user's own sounds (inject/grab/release/delete/refuse/ok .ogg) stay as they are.

  python3 tools/olife/gen_sounds.py            # writes the files, prints name, duration, peak
"""
import math
import os
import random
import struct
import wave

SR = 22050
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "content", "olife_client", "sounds", "olife")


def env(i, n, a=0.01, r=0.6):
    t = i / SR
    d = n / SR
    if t < a:
        return t / a
    k = (t - a) / max(1e-6, d - a)
    return max(0.0, 1.0 - k) ** (1.0 / max(0.05, r))


def tone(freqs, dur, vol=0.5, shape="sine", glide=None, a=0.008, r=0.5):
    """sequence of (freq, dur) notes or one freq with optional glide (f0 -> f1)"""
    out = []
    for f, d in freqs if isinstance(freqs, list) else [(freqs, dur)]:
        n = int(SR * d)
        ph = 0.0
        for i in range(n):
            ff = f if glide is None else f + (glide - f) * i / n
            ph += 2 * math.pi * ff / SR
            if shape == "sine":
                v = math.sin(ph)
            elif shape == "square":
                v = 1.0 if math.sin(ph) >= 0 else -1.0
                v *= 0.35
            else:  # soft triangle
                v = 2 / math.pi * math.asin(math.sin(ph))
            out.append(v * vol * env(i, n, a, r))
    return out


def noise(dur, vol=0.3, seed=7):
    rnd = random.Random(seed)
    n = int(SR * dur)
    prev = 0.0
    out = []
    for i in range(n):
        prev = prev * 0.7 + rnd.uniform(-1, 1) * 0.3
        out.append(prev * vol * env(i, n, 0.002, 0.3))
    return out


def mix(*parts):
    n = max(len(p) for p in parts)
    return [sum(p[i] for p in parts if i < len(p)) for i in range(n)]


SOUNDS = {
    "fx_stop": lambda: tone(520, 0.16, 0.45, "tri", glide=330),
    "fx_save": lambda: tone([(880, 0.06), (1320, 0.10)], 0, 0.40, "sine"),
    "fx_spawn": lambda: tone(300, 0.22, 0.45, "sine", glide=900),
    "fx_fork": lambda: tone([(660, 0.07), (0.0001, 0.03), (990, 0.09)], 0, 0.40, "sine"),
    "fx_throttle": lambda: tone([(180, 0.08), (0.0001, 0.04), (180, 0.08), (0.0001, 0.04), (180, 0.10)], 0, 0.5, "square"),
    "fx_freeze": lambda: mix(tone(1600, 0.40, 0.25, "sine", glide=700, r=0.8), tone(2400, 0.40, 0.10, "sine", glide=1100, r=0.8)),
    "fx_unfreeze": lambda: mix(tone(700, 0.30, 0.25, "sine", glide=1600, r=0.8), tone(1100, 0.30, 0.10, "sine", glide=2400, r=0.8)),
    "fx_op": lambda: tone([(784, 0.09), (1046, 0.09), (784, 0.12)], 0, 0.35, "tri"),
    "fx_kick": lambda: mix(tone(140, 0.30, 0.6, "sine", glide=60), noise(0.12, 0.25)),
    "fx_restart": lambda: tone(440, 0.45, 0.4, "tri", glide=110, r=0.9),
    "fx_chat": lambda: tone([(1200, 0.035), (1600, 0.05)], 0, 0.22, "sine"),
}


def write(name, samples):
    peak = max(1e-9, max(abs(v) for v in samples))
    k = min(1.0, 0.9 / peak)
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v * k)) * 32767)) for v in samples))
    return path, len(samples) / SR, peak * k


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for n, f in SOUNDS.items():
        p, d, pk = write(n, f())
        print("%-12s %.2f s peak %.2f %s" % (n, d, pk, os.path.relpath(p)))
