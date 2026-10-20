#!/usr/bin/env python3
"""出招人声：短促的"用力"发声（路线 A 原创合成）。

需求（负责人）：出招时先出一声短促人声代表人物用力，然后才是招式音。
原因：招式音本身不弱，但**缺少"人"的起手**，听感上出招是空的。

设计：四种强度，按招式轻重分配（映射在 battle_fx.VOICE_EFFORT）

  voice_light  0.11s  f0 150->118  轻击（attack1 / 连突刺 / 空斩）
  voice_mid    0.15s  f0 172->128  中击（attack2 / 上挑 / 拔刀斩 / 冲斩）
  voice_heavy  0.22s  f0 148->96   重击（attack3 / 怒斩）
  voice_rage   0.30s  f0 120->88   低吼（血怒）

做法同 3.6 节的人声配方，但更短更闷：声带脉冲 + 抖动（用力感）+ 「呃/啊」
共振峰（男声偏低）+ 短促气流噪声 + tanh 过载 + 快速衰减。

交付规范：48 kHz / 单声道 / 16 bit、峰值 0.72、首尾为 0、无削波、3 变体。
用法：python tools/bake_voice_efforts.py
"""

from __future__ import annotations

import argparse
import wave
from pathlib import Path

import numpy as np

SR = 48000
PEAK = 0.72
FADE_MS = 3.0
VARIANTS = 3
ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "game/assets/audio_v3"

# kind -> (时长, 起始 f0, 结束 f0, 抖动, 次谐波, 过载, 气流, 共振峰)
KINDS = {
    "voice_light": dict(seconds=0.11, f0_a=150.0, f0_b=118.0, jitter=0.040, sub=0.22, drive=2.0, breath=0.26,
                        formants=[(620.0, 130.0, 1.00), (1150.0, 190.0, 0.60), (2500.0, 320.0, 0.28)]),
    "voice_mid": dict(seconds=0.15, f0_a=172.0, f0_b=128.0, jitter=0.048, sub=0.28, drive=2.4, breath=0.30,
                      formants=[(680.0, 130.0, 1.00), (1240.0, 190.0, 0.66), (2600.0, 320.0, 0.30)]),
    "voice_heavy": dict(seconds=0.22, f0_a=148.0, f0_b=96.0, jitter=0.058, sub=0.36, drive=3.0, breath=0.34,
                        formants=[(600.0, 140.0, 1.00), (1080.0, 200.0, 0.70), (2400.0, 340.0, 0.26)]),
    "voice_rage": dict(seconds=0.30, f0_a=120.0, f0_b=88.0, jitter=0.066, sub=0.44, drive=3.4, breath=0.38,
                       formants=[(500.0, 130.0, 1.00), (900.0, 190.0, 0.72), (2200.0, 360.0, 0.24)]),
}


def _smooth(x: np.ndarray, width: int) -> np.ndarray:
    if width <= 1:
        return x
    k = np.hanning(width).astype(np.float32)
    k /= k.sum()
    return np.convolve(x, k, mode="same").astype(np.float32)


def _onepole(x: np.ndarray, cutoff: float, high: bool = False) -> np.ndarray:
    a = float(np.clip(1.0 - np.exp(-2.0 * np.pi * cutoff / SR), 1e-4, 0.9999))
    y = np.empty_like(x)
    acc = 0.0
    for i in range(x.size):
        acc += a * (x[i] - acc)
        y[i] = acc
    return (x - y) if high else y


def _formant_gain(freqs: np.ndarray, formants) -> np.ndarray:
    gain = np.zeros_like(freqs, dtype=np.float32)
    for center, bandwidth, level in formants:
        gain += level / (1.0 + ((freqs - center) / bandwidth) ** 2)
    gain *= 1.0 / (1.0 + (150.0 / np.maximum(freqs, 1.0)) ** 2)
    return gain


def bake(cfg: dict, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    n = int(round(cfg["seconds"] * SR))
    t = np.arange(n, dtype=np.float32) / SR
    u = t / max(1e-6, cfg["seconds"])

    # 音高：用力的短促下滑（起音高、迅速垮下来）
    glide = cfg["f0_a"] * (cfg["f0_b"] / cfg["f0_a"]) ** (u ** 0.7)
    jitter = 1.0 + cfg["jitter"] * _smooth(rng.standard_normal(n).astype(np.float32), 64)
    f_inst = glide * jitter

    phase = 2.0 * np.pi * np.cumsum(f_inst) / SR
    saw = 2.0 * np.mod(phase / (2.0 * np.pi), 1.0) - 1.0
    glottal = (saw - 0.5 * saw * saw).astype(np.float32)
    excitation = glottal + cfg["sub"] * np.sin(0.5 * phase).astype(np.float32)

    # 气流噪声（"哈"的那口气），压低避免变成嘶声
    breath = _onepole(rng.standard_normal(n).astype(np.float32), 3200.0, high=True)
    breath *= np.linspace(1.0, 0.2, n, dtype=np.float32) * cfg["breath"]
    excitation = excitation + breath

    spec = np.fft.rfft(excitation)
    freqs = np.fft.rfftfreq(n, 1.0 / SR).astype(np.float32)
    shaped = np.fft.irfft(spec * _formant_gain(freqs, cfg["formants"]), n=n).astype(np.float32)

    driven = np.tanh(cfg["drive"] * shaped).astype(np.float32)

    # 包络：极快起音 + 指数衰减（用力声是"一下"，不是持续音）
    env = np.ones(n, dtype=np.float32)
    attack = max(2, int(0.010 * SR))
    env[:attack] = np.linspace(0.0, 1.0, attack, dtype=np.float32)
    env[attack:] *= np.exp(-np.arange(n - attack, dtype=np.float32) / (0.42 * n))

    out = driven * env
    out -= float(out.mean())
    peak = float(np.abs(out).max())
    if peak > 1e-6:
        out *= PEAK / peak
    f = max(1, int(SR * FADE_MS / 1000.0))
    out[:f] *= np.linspace(0.0, 1.0, f, dtype=np.float32)
    out[-f:] *= np.linspace(1.0, 0.0, f, dtype=np.float32)
    out[0] = 0.0
    out[-1] = 0.0
    return out


def write_wav(path: Path, x: np.ndarray) -> dict:
    pcm = (np.clip(x, -1.0, 1.0) * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    y = pcm.astype(np.float32) / 32767.0
    spec = np.abs(np.fft.rfft(y * np.hanning(len(y))))
    freqs = np.fft.rfftfreq(len(y), 1.0 / SR)
    cen = float((spec * freqs).sum() / max(1e-9, spec.sum()))
    return {
        "seconds": round(len(y) / SR, 4),
        "peak": round(float(np.abs(y).max()), 4),
        "rms": round(float(np.sqrt(np.mean(y ** 2))), 4),
        "centroid": round(cen, 1),
        "first": int(pcm[0]),
        "last": int(pcm[-1]),
        "clipped": int((np.abs(pcm.astype(np.int32)) >= 32767).sum()),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="出招人声（原创合成）")
    ap.add_argument("--out", default=str(OUT_DIR))
    args = ap.parse_args()
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    ok = True
    for kind, cfg in KINDS.items():
        base = sum(ord(c) * (i + 1) for i, c in enumerate(kind))
        infos = []
        for v in range(1, VARIANTS + 1):
            info = write_wav(out_dir / f"{kind}_{v}.wav", bake(cfg, 0x7A31 + v * 131 + base))
            infos.append(info)
            if info["clipped"] or info["peak"] >= 0.76 or info["first"] or info["last"]:
                ok = False
        print(f"  {kind:<13} {cfg['seconds']:.2f}s  f0 {cfg['f0_a']:.0f}->{cfg['f0_b']:.0f}Hz  "
              f"质心{infos[0]['centroid']:>5.0f}Hz  峰值{max(i['peak'] for i in infos):.3f}  "
              f"RMS{infos[0]['rms']:.3f}  削波{sum(i['clipped'] for i in infos)}")
    print(f"\n输出目录: {out_dir}")
    print("下一步：确认 .import 的 compress/mode=0，并在 battle_fx.VOICE_EFFORT 里分配强度")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
