"""Bake deterministic, layered combat foley to ordinary 48 kHz / PCM16 WAV.

No downloads, recordings, model calls, or runtime synthesis. Uses NumPy only.
Re-run: python tools/bake_combat_audio.py
The recipe, seed, loudness, file hashes, and numerical QA travel with the assets.
"""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import wave

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "game" / "assets" / "audio_v3"
REPORT = ROOT / "audio" / "combat_v3"
RATE = 48000
VARIANTS = 3
PEAK = 0.76

# Seconds and material recipes. These are independent performances, not pitch copies.
SPECS = {
    "swing_light": (0.190, "cloth + narrow blade air shear + steel micro resonance"),
    "swing_back": (0.205, "backhand air shear + grip creak + trailing blade ring"),
    "swing_heavy": (0.285, "broadband air displacement + low pressure + grip snap"),
    "swing_air": (0.235, "open-air blade hiss + leather stretch + mid resonance"),
    "swing_upper": (0.230, "upward accelerating air column + blade-flex ring"),
    "dash": (0.180, "cloth rush + low boot scrape + air shear"),
    "dash_strike": (0.265, "fast air shear + heavy grip snap + sharp steel edge"),
    "light": (0.225, "damped flesh body + leather slap + blade edge scrape"),
    "heavy": (0.340, "low pressure impact + flesh tear + grit + damped blade modes"),
    "launch": (0.285, "dense body impact + high blade scrape + upward air release"),
    "metal_hit": (0.365, "steel plate modal vibration + bright impact grit + low contact body"),
    "guard": (0.435, "two steel blades contact + inharmonic high modes + hand/grip body"),
    "hurt": (0.295, "leather thud + broad body strike + expelled filtered air"),
    "step": (0.185, "boot sole on stone + leather fold + secondary heel contact"),
    "run_step": (0.180, "hard boot heel + sole compression + short leather contact"),
    "run_stop": (0.300, "boot friction on stone + cloth pull + heel settle"),
    "jump": (0.200, "boot push-off + cloth stretch + small air release"),
    "land": (0.360, "paired boot impact + low sole compression + stone grit + cloth settle"),
    "charge": (0.405, "reverse blade-air gather + muted steel partials + grip draw"),
    "draw_strike": (0.365, "instant steel release + fast broadband cut + low pressure impulse"),
    "rage": (0.470, "rough low air pressure + crackling ember impulses + damped steel"),
    "rage_strike": (0.360, "two blade shear layers + low impact pressure + gritty crackle"),
    "thrust": (0.185, "needle-like air shear + short steel tip ring + leather snap"),
    "death": (0.510, "monster breath collapse + body-to-floor thud + leather/grit fall"),
    "wave": (0.680, "three soft struck-metal warning intervals + low arena pulse"),
    "victory": (1.190, "four warm bell/modal intervals with natural overlapping decay"),
    "ui": (0.110, "quiet leather/mechanical interface click with damped metal overtone"),
}


def seed_for(kind: str, variant: int) -> int:
    return int.from_bytes(hashlib.sha256(f"combat-v3:{kind}:{variant}".encode()).digest()[:8], "little")


def band_noise(n: int, rng: np.random.Generator, low: float, high: float) -> np.ndarray:
    """Smooth sixth-order spectral shaping, padded to avoid circular edge impulses."""
    length = n + 1024
    freq = np.fft.rfftfreq(length, 1 / RATE)
    safe = np.maximum(freq, 0.001)
    high_pass = 1 / (1 + (low / safe) ** 6)
    low_pass = 1 / (1 + (safe / high) ** 6)
    spec = np.fft.rfft(rng.normal(0, 1, length)) * high_pass * low_pass
    result = np.fft.irfft(spec, length)[512 : n + 512]
    return result / max(np.std(result), 1e-8)


def exp_env(t: np.ndarray, decay: float, onset: float = 0, attack: float = 0.0008) -> np.ndarray:
    dt = t - onset
    return np.where(dt >= 0, np.minimum(np.maximum(dt, 0) / attack, 1) * np.exp(-np.maximum(dt, 0) / decay), 0)


def burst(t: np.ndarray, rng: np.random.Generator, low: float, high: float, decay: float, onset: float = 0, gain: float = 1) -> np.ndarray:
    return band_noise(len(t), rng, low, high) * exp_env(t, decay, onset) * gain


def body(t: np.ndarray, rng: np.random.Generator, frequency: float, decay: float, gain: float = 1, onset: float = 0) -> np.ndarray:
    dt = np.maximum(t - onset, 0)
    # Contact pressure rapidly bends the resonant frequency down rather than beeping.
    phase = 2 * np.pi * (frequency * dt + frequency * 0.018 * (1 - np.exp(-dt / 0.007)))
    return np.sin(phase + rng.uniform(-0.15, 0.15)) * exp_env(t, decay, onset, 0.0012) * gain


def metal(t: np.ndarray, rng: np.random.Generator, fundamental: float, decay: float, gain: float = 1, onset: float = 0) -> np.ndarray:
    # Inharmonic elastic plate/beam modes; high modes damp much faster than low modes.
    result = np.zeros(len(t))
    dt = np.maximum(t - onset, 0)
    ratios = (1.0, 1.94, 2.79, 4.12, 5.67, 7.13, 9.29)
    for index, ratio in enumerate(ratios):
        freq = fundamental * ratio * rng.uniform(0.97, 1.03)
        env = exp_env(t, decay / (1 + index * 0.33), onset, 0.0004)
        result += np.sin(2 * np.pi * freq * dt + rng.uniform(-0.07, 0.07)) * env / (1 + index * 0.75)
    return result * gain * 0.46


def air(t: np.ndarray, rng: np.random.Generator, onset: float, span: float, weight: float = 1, bright: float = 1) -> np.ndarray:
    p = np.clip((t - onset) / span, 0, 1)
    env = np.sin(np.pi * p) ** 1.9 * (1 - p * 0.38)
    env *= (t > onset) & (t < onset + span)
    # Distinct low displacement, turbulent mid body, and fast edge hiss bands.
    low = band_noise(len(t), rng, 80, 530)
    mid = band_noise(len(t), rng, 650 * bright, 2600 * bright)
    edge = band_noise(len(t), rng, 3200 * bright, 10500)
    grit = 0.84 + 0.16 * np.sin(2 * np.pi * rng.uniform(33, 52) * t)
    return (low * 0.15 + mid * 0.61 + edge * p**1.5 * 0.24) * env * grit * weight


def leather(t: np.ndarray, rng: np.random.Generator, onset: float, gain: float = 1) -> np.ndarray:
    snap = burst(t, rng, 950, 5300, 0.009, onset, 0.26)
    creak = burst(t, rng, 300, 1350, 0.045, onset + 0.008, 0.21)
    fold = body(t, rng, rng.uniform(130, 190), 0.025, 0.22, onset + 0.004)
    return (snap + creak + fold) * gain


def foot(t: np.ndarray, rng: np.random.Generator, onset: float, gain: float = 1, hard: bool = False) -> np.ndarray:
    sole = body(t, rng, rng.uniform(72, 105), 0.043, 0.63, onset)
    stone = burst(t, rng, 620, 5300, 0.011 if hard else 0.016, onset, 0.15 if hard else 0.12)
    heel = body(t, rng, rng.uniform(180, 230), 0.021, 0.19, onset + rng.uniform(0.019, 0.030))
    secondary = burst(t, rng, 300, 1550, 0.022, onset + 0.023, 0.12)
    return gain * (sole + stone + heel + secondary + leather(t, rng, onset + 0.009, 0.35))


def crackle(t: np.ndarray, rng: np.random.Generator, gain: float = 1) -> np.ndarray:
    impulses = np.zeros(len(t))
    for _ in range(14):
        pos = int(rng.uniform(0.005, min(t[-1] - 0.015, 0.25)) * RATE)
        length = min(int(RATE * 0.005), len(t) - pos)
        impulses[pos : pos + length] += rng.normal(0, 1, length) * np.exp(-np.arange(length) / (RATE * 0.0009)) * rng.uniform(0.09, 0.28)
    return impulses * gain


def render(kind: str, variant: int) -> np.ndarray:
    rng = np.random.default_rng(seed_for(kind, variant))
    duration = SPECS[kind][0] * rng.uniform(0.96, 1.05)
    t = np.arange(round(duration * RATE)) / RATE
    out = np.zeros(len(t))
    if kind.startswith("swing_") or kind in ("dash", "dash_strike", "thrust"):
        if kind == "swing_light":
            out = air(t, rng, 0.007, 0.137, 0.58, 1.02) + leather(t, rng, 0.015, 0.23) + metal(t, rng, 820, 0.075, 0.045, 0.096)
        elif kind == "swing_back":
            out = air(t, rng, 0.014, 0.153, 0.62, 0.86) + leather(t, rng, 0.010, 0.35) + metal(t, rng, 770, 0.077, 0.052, 0.105)
        elif kind == "swing_heavy":
            out = air(t, rng, 0.010, 0.230, 0.76, 0.72) + body(t, rng, 65, 0.050, 0.11, 0.084) + leather(t, rng, 0.048, 0.49) + metal(t, rng, 640, 0.078, 0.051, 0.178)
        elif kind == "swing_air":
            out = air(t, rng, 0.008, 0.190, 0.68, 1.22) + leather(t, rng, 0.025, 0.22) + metal(t, rng, 1040, 0.055, 0.035, 0.125)
        elif kind == "swing_upper":
            out = air(t, rng, 0.015, 0.190, 0.68, 1.15) + metal(t, rng, 955, 0.071, 0.061, 0.110) + leather(t, rng, 0.015, 0.28)
        elif kind == "dash":
            out = air(t, rng, 0.004, 0.153, 0.56, 0.8) + burst(t, rng, 200, 1100, 0.066, 0.007, 0.08) + leather(t, rng, 0.016, 0.33)
        elif kind == "dash_strike":
            out = air(t, rng, 0.002, 0.190, 0.75, 1.16) + metal(t, rng, 1010, 0.085, 0.09, 0.084) + leather(t, rng, 0.022, 0.36) + body(t, rng, 77, 0.03, 0.08, 0.067)
        else:
            out = air(t, rng, 0.003, 0.108, 0.57, 1.35) + metal(t, rng, 1135, 0.068, 0.065, 0.025) + leather(t, rng, 0.011, 0.25)
    elif kind in ("light", "heavy", "launch", "hurt"):
        heavy = kind == "heavy"
        out = body(t, rng, rng.uniform(63, 90) if heavy else rng.uniform(103, 137), 0.067 if heavy else 0.044, 0.70)
        out += burst(t, rng, 190, 1600, 0.041 if heavy else 0.030, 0.003, 0.20)
        out += burst(t, rng, 1700, 6900, 0.017, 0.001, 0.115 if heavy else 0.10)
        out += leather(t, rng, 0.005, 0.80 if heavy else 0.56)
        out += metal(t, rng, 770 if heavy else 1010, 0.068, 0.04, 0.006)
        if heavy:
            out += crackle(t, rng, 0.43) * np.exp(-t / 0.080)
            out += body(t, rng, 47, 0.095, 0.30, 0.009)
        if kind == "launch":
            out += air(t, rng, 0.012, 0.165, 0.18, 1.18) + metal(t, rng, 1240, 0.083, 0.08, 0.016)
        if kind == "hurt":
            out += burst(t, rng, 260, 1050, 0.083, 0.026, 0.18)
    elif kind in ("metal_hit", "guard"):
        fundamental = rng.uniform(620, 750) if kind == "guard" else rng.uniform(780, 880)
        out = metal(t, rng, fundamental, 0.173 if kind == "guard" else 0.135, 0.73)
        out += metal(t, rng, fundamental * 1.32, 0.086, 0.26, 0.0009)
        out += burst(t, rng, 2600, 12000, 0.0075, 0.0005, 0.145)
        out += body(t, rng, 145, 0.023, 0.24) + leather(t, rng, 0.004, 0.25)
    elif kind in ("step", "run_step", "run_stop", "jump", "land"):
        if kind == "step":
            out = foot(t, rng, 0.002, 0.70) + leather(t, rng, 0.047, 0.10)
        elif kind == "run_step":
            out = foot(t, rng, 0.001, 0.94, True) + burst(t, rng, 1500, 7000, 0.006, 0.014, 0.065)
        elif kind == "run_stop":
            out = burst(t, rng, 500, 3800, 0.106, 0.004, 0.15) + foot(t, rng, 0.099, 0.5)
            out += leather(t, rng, 0.027, 0.30) + body(t, rng, 75, 0.044, 0.16, 0.007)
        elif kind == "jump":
            out = foot(t, rng, 0.001, 0.67) + air(t, rng, 0.020, 0.13, 0.095, 0.83) + leather(t, rng, 0.024, 0.37)
        else:
            out = foot(t, rng, 0.001, 1.00, True) + foot(t, rng, rng.uniform(0.012, 0.026), 0.56, True)
            out += body(t, rng, 54, 0.083, 0.36, 0.003) + burst(t, rng, 530, 5200, 0.036, 0.003, 0.08)
            out += leather(t, rng, 0.056, 0.20)
    elif kind == "charge":
        p = np.clip(t / 0.300, 0, 1)
        out = band_noise(len(t), rng, 400, 3800) * p**2.5 * np.exp(-np.maximum(t - 0.28, 0) / 0.023) * 0.17
        out += metal(t, rng, 520, 0.14, 0.09, 0.030) + leather(t, rng, 0.02, 0.30)
        out += metal(t, rng, 1100, 0.07, 0.045, 0.245)
    elif kind == "draw_strike":
        out = air(t, rng, 0.001, 0.156, 0.64, 1.30) + metal(t, rng, 1560, 0.098, 0.22, 0.001)
        out += burst(t, rng, 1700, 11000, 0.007, 0.001, 0.17) + body(t, rng, 59, 0.055, 0.26, 0.004)
        out += leather(t, rng, 0.009, 0.29)
    elif kind in ("rage", "rage_strike"):
        out = burst(t, rng, 100, 620, 0.185, 0.002, 0.19) + crackle(t, rng, 0.62)
        out += body(t, rng, 44, 0.108, 0.24, 0.007)
        if kind == "rage_strike":
            out += air(t, rng, 0.002, 0.180, 0.66, 0.8) + air(t, rng, 0.021, 0.156, 0.29, 1.1)
            out += metal(t, rng, 540, 0.12, 0.085, 0.036)
        else:
            out += burst(t, rng, 420, 3300, 0.16, 0.055, 0.11) + metal(t, rng, 410, 0.22, 0.12, 0.015)
    elif kind == "death":
        breath = band_noise(len(t), rng, 125, 1350)
        out = breath * exp_env(t, 0.120, 0.005, 0.011) * (0.18 + 0.09 * np.sin(2 * np.pi * 34 * t))
        out += body(t, rng, 76, 0.071, 0.34, 0.008) + foot(t, rng, 0.135, 0.76) + leather(t, rng, 0.10, 0.42)
        out += burst(t, rng, 500, 3600, 0.050, 0.172, 0.08)
    elif kind in ("wave", "victory"):
        notes = (174.61, 220.0, 261.63) if kind == "wave" else (261.63, 329.63, 392, 523.25)
        step = 0.145 if kind == "wave" else 0.175
        for index, frequency in enumerate(notes):
            onset = 0.003 + index * step
            dt = np.maximum(t - onset, 0)
            env = exp_env(t, 0.175 if kind == "wave" else 0.245, onset, 0.004)
            out += (np.sin(2 * np.pi * frequency * dt) * 0.24 + np.sin(2 * np.pi * frequency * 2.76 * dt) * 0.035) * env
            out += burst(t, rng, 1300, 5700, 0.004, onset, 0.008)
        if kind == "wave":
            out += body(t, rng, 55, 0.082, 0.17, 0.004)
    else:
        out = leather(t, rng, 0.001, 0.30) + metal(t, rng, 1280, 0.027, 0.14) + body(t, rng, 185, 0.02, 0.18)

    # Small stone-room early reflections, lower and duller than the direct attack.
    dry = out.copy()
    for delay, gain in ((0.011, 0.065), (0.023, 0.035), (0.039, 0.020)):
        shift = round(delay * RATE)
        out[shift:] += dry[:-shift] * gain
    out -= np.mean(out)
    out = np.tanh(out * 1.12) / 1.12  # Gentle analogue saturation, no hard-clipped PCM.
    edge = min(round(0.003 * RATE), len(t) // 4)
    window = np.ones(len(out))
    window[:edge] = np.linspace(0, 1, edge)**1.5
    window[-edge:] = np.linspace(1, 0, edge)**1.5
    out *= window
    # Saturation/fades can reintroduce DC. Remove it with the same zero-edge window.
    out -= window * (np.sum(out) / np.sum(window))
    target_peak = PEAK * rng.uniform(0.90, 1.0)
    out *= target_peak / max(np.max(np.abs(out)), 1e-9)
    return out


def write_wav(path: Path, data: np.ndarray) -> None:
    pcm = np.rint(np.clip(data, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as stream:
        stream.setnchannels(1 if data.ndim == 1 else data.shape[1])
        stream.setsampwidth(2)
        stream.setframerate(RATE)
        stream.writeframes(pcm.tobytes())


def inspect(path: Path) -> dict:
    with wave.open(str(path), "rb") as stream:
        count = stream.getnframes()
        pcm = np.frombuffer(stream.readframes(count), dtype="<i2").astype(float) / 32767
    rms = math.sqrt(float(np.mean(pcm**2)))
    peak = float(np.max(np.abs(pcm)))
    return {
        "file": path.relative_to(ROOT).as_posix(), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "frames": count, "duration": round(count / RATE, 4), "sample_rate": RATE,
        "peak": round(peak, 6), "rms_dbfs": round(20 * math.log10(max(rms, 1e-9)), 3),
        "dc_mean": round(float(np.mean(pcm)), 7), "clipped_samples": int(np.sum(np.abs(pcm) >= 0.999)),
        "first_sample": float(pcm[0]), "last_sample": float(pcm[-1]),
    }


def main() -> None:
    DEST.mkdir(parents=True, exist_ok=True)
    REPORT.mkdir(parents=True, exist_ok=True)
    results, sounds = [], {}
    for kind in SPECS:
        sounds[kind] = []
        for variant in range(VARIANTS):
            audio = render(kind, variant)
            path = DEST / f"{kind}_{variant + 1}.wav"
            write_wav(path, audio)
            results.append(inspect(path))
            sounds[kind].append(audio)
    # Structured audition: three slashes then three hits, movement, guard, skill profiles.
    order = ["swing_light", "swing_back", "swing_heavy", "light", "heavy", "metal_hit",
             "step", "run_step", "jump", "land", "run_stop", "guard", "charge", "draw_strike",
             "rage", "rage_strike", "thrust", "thrust", "thrust", "death", "wave", "victory"]
    snippets = []
    for index, kind in enumerate(order):
        audio = sounds[kind][index % VARIANTS] * 0.75
        pan = (index % 3 - 1) * 0.28
        stereo = np.stack((audio * math.sqrt((1 - pan) / 2), audio * math.sqrt((1 + pan) / 2)), axis=1)
        snippets.extend((stereo, np.zeros((round(0.32 * RATE), 2))))
    write_wav(REPORT / "audition_combat_v3.wav", np.concatenate(snippets))
    manifest = {"format": "48 kHz mono PCM16", "variants": VARIANTS, "seed_scheme": "SHA256 combat-v3:kind:variant",
                "source": "Original procedural foley model; no downloaded or recorded material", "recipes": {k: v[1] for k, v in SPECS.items()}}
    (REPORT / "source_spec.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    validation = {"asset_count": len(results), "categories": len(SPECS), "max_peak": max(r["peak"] for r in results),
                  "clipped_samples": sum(r["clipped_samples"] for r in results),
                  "all_edges_silent": all(r["first_sample"] == r["last_sample"] == 0 for r in results),
                  "assets": results}
    (REPORT / "validation.json").write_text(json.dumps(validation, indent=2) + "\n", encoding="utf-8")
    assert validation["clipped_samples"] == 0 and validation["max_peak"] <= PEAK + 1 / 32767
    assert validation["all_edges_silent"]
    print(json.dumps({k: v for k, v in validation.items() if k != "assets"}, indent=2))
    print("Audition:", REPORT / "audition_combat_v3.wav")


if __name__ == "__main__":
    main()
