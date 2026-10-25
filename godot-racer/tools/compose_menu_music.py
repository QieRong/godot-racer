"""Original menu loop, generated mathematically; no sampled or external music.

Build-only dependencies: numpy, soundfile (libsndfile Vorbis encoder).
python tools/compose_menu_music.py --output assets/audio/menu_theme.ogg
Game playback has no Python dependency. Waveform is deterministic; container metadata may vary.
"""
import argparse
import hashlib
import json
import threading
from pathlib import Path

import numpy as np
import soundfile as sf

RATE = 22050
TEMPO = 100
BEAT = 60 / TEMPO
LENGTH = BEAT * 4 * 16
COUNT = round(RATE * LENGTH)
mix = np.zeros((COUNT, 2), dtype=np.float64)


def note(midi, start, duration, gain, pan=0.0, pad=False):
    """Soft envelopes and wrapped release tails keep the loop seam continuous."""
    t = np.arange(round((duration + 0.3) * RATE)) / RATE
    frequency = 440 * 2 ** ((midi - 69) / 12)
    attack = 0.15 if pad else 0.025
    envelope = np.minimum(t / attack, 1) * np.minimum(np.maximum((duration + 0.3 - t) / 0.3, 0), 1)
    if not pad:
        envelope *= np.exp(-t * 3.2 / max(duration, 0.2))
    wave = np.sin(2 * np.pi * frequency * t) + 0.14 * np.sin(4 * np.pi * frequency * t)
    signal = gain * envelope * wave
    positions = (round(start * RATE) + np.arange(len(t))) % COUNT
    np.add.at(mix[:, 0], positions, signal * np.sqrt((1 - pan) / 2))
    np.add.at(mix[:, 1], positions, signal * np.sqrt((1 + pan) / 2))


# Generic harmony, independently specified here; sixteen bars, no borrowed melody.
chords = [(45, 52, 60, 64), (41, 48, 57, 60), (48, 55, 60, 64), (43, 50, 59, 62)]
motif = [0, 2, 1, 3, 2, 1, 0, 2]
for bar in range(16):
    chord = chords[bar % 4]
    start = bar * BEAT * 4
    for pitch in chord[1:]:
        note(pitch, start, BEAT * 4, 0.023, pad=True)
    for beat in [0, 2]:
        note(chord[0] - 12, start + beat * BEAT, BEAT * 1.8, 0.065)
    for index, degree in enumerate(motif):
        # Alternate register/placement creates restrained movement instead of a loud lead.
        pitch = chord[degree] + 12
        note(pitch, start + index * BEAT / 2, BEAT * 0.8,
             0.026 if index % 2 == 0 else 0.018, (-1 if index % 2 else 1) * 0.25)

mix = np.tanh(mix * 1.8)
peak = np.max(np.abs(mix))
mix *= 0.65 / max(peak, 1e-9)
parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "assets/audio/menu_theme.ogg")
args = parser.parse_args()
args.output.parent.mkdir(parents=True, exist_ok=True)
errors = []


def encode():
    try:
        sf.write(args.output, mix.astype(np.float32), RATE, format="OGG", subtype="VORBIS")
    except Exception as error:
        errors.append(error)


# Windows Python主线程的1MB栈会使本机Vorbis编码器栈溢出（0xC00000FD）。
# 单独16MB栈编码线程已用同一编码器/同一格式小样复现验证，不修改系统配置。
threading.stack_size(16 * 1024 * 1024)
worker = threading.Thread(target=encode)
worker.start()
worker.join()
if errors:
    raise errors[0]
decoded, rate = sf.read(args.output, always_2d=True)
report = {"rate": rate, "channels": decoded.shape[1], "seconds": len(decoded) / rate,
          "peak": float(np.max(np.abs(decoded))), "rms": float(np.sqrt(np.mean(decoded**2))),
          "seam_max_delta": float(np.max(np.abs(decoded[0] - decoded[-1]))),
          "sha256": hashlib.sha256(args.output.read_bytes()).hexdigest(), "bytes": args.output.stat().st_size}
print(json.dumps(report, indent=2))
