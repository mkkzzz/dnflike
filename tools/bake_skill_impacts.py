#!/usr/bin/env python3
"""技能命中声：每个技能一记自己的"打中"（路线 A 原创合成）。

为什么需要：出招声本来就分技能（rage / draw_strike / rage_strike / thrust），
但**命中声是通用的** —— battle_fx._impact_sound 只对普攻三分支特化，
其余全部落到 light / heavy / launch / metal_hit。四个技能打在同一只怪身上
听感没有区别，技能就没有"自己的声音"。

四个技能各做一记，气质要与出招一致：

  impact_thrust      连突刺   极短（~0.14s）穿刺"噗"+ 金属尖鸣，可连三下
  impact_quick_draw  拔刀斩   锐利切入 + 长金属余响 + 气流尾（~0.38s）
  impact_rage_slash  怒斩     低频钝击 + 破音碎屑 + 湿闷的撕肉感（~0.45s）
  impact_upper       上挑     上扫气流 + 脆响 + 上浮的低频（~0.26s）

交付规范同工程：48 kHz / 单声道 / 16 bit、峰值 0.72、首尾为 0、无削波、3 变体。
用法：python tools/bake_skill_impacts.py [--out DIR]
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


# ---------------------------------------------------------------- 基础件


def _rng(seed: int) -> np.random.Generator:
    return np.random.default_rng(seed)


def _noise(n: int, rng: np.random.Generator) -> np.ndarray:
    return rng.standard_normal(n).astype(np.float32)


def _onepole(x: np.ndarray, cutoff: float, high: bool = False) -> np.ndarray:
    a = float(np.clip(1.0 - np.exp(-2.0 * np.pi * cutoff / SR), 1e-4, 0.9999))
    y = np.empty_like(x)
    acc = 0.0
    for i in range(x.size):
        acc += a * (x[i] - acc)
        y[i] = acc
    return (x - y) if high else y


def _decay(n: int, tau_ms: float, attack_ms: float = 0.8) -> np.ndarray:
    a = max(1, int(SR * attack_ms / 1000.0))
    a = min(a, n)
    env = np.zeros(n, dtype=np.float32)
    env[:a] = np.linspace(0.0, 1.0, a, dtype=np.float32)
    t = np.arange(n - a, dtype=np.float32) / SR
    env[a:] = np.exp(-t / max(1e-4, tau_ms / 1000.0))
    return env


def _ring(n: int, freq: float, tau_ms: float, gain: float) -> np.ndarray:
    t = np.arange(n, dtype=np.float32) / SR
    return (np.sin(2.0 * np.pi * freq * t) * np.exp(-t / max(1e-4, tau_ms / 1000.0)) * gain).astype(np.float32)


def _finish(x: np.ndarray, lowpass_hz: float = 0.0) -> np.ndarray:
    x = x.astype(np.float32, copy=True)
    if lowpass_hz > 0.0:
        # 收一点高频，避免混成"嘶声"而不是"打中"（现有命中声质心 1.2~4.9 kHz）。
        # 一阶低通只有 6 dB/oct，级联三次才够看。
        for _ in range(3):
            x = _onepole(x, lowpass_hz)
    x -= float(x.mean())
    peak = float(np.abs(x).max())
    if peak > 1e-6:
        x *= PEAK / peak
    f = max(1, int(SR * FADE_MS / 1000.0))
    x[:f] *= np.linspace(0.0, 1.0, f, dtype=np.float32)
    x[-f:] *= np.linspace(1.0, 0.0, f, dtype=np.float32)
    x[0] = 0.0
    x[-1] = 0.0
    return x


# ---------------------------------------------------------------- 四种命中


def bake_thrust(rng: np.random.Generator) -> np.ndarray:
    n = int(SR * 0.14)
    body = _onepole(_noise(n, rng), 5200.0, high=True) * _decay(n, 26.0) * 0.42
    body += _onepole(_noise(n, rng), 900.0) * _decay(n, 40.0) * 0.55
    body += _ring(n, 2410.0 * float(rng.uniform(0.96, 1.04)), 42.0, 0.26)
    body += _ring(n, 3630.0 * float(rng.uniform(0.97, 1.03)), 26.0, 0.14)
    body += _ring(n, 138.0, 48.0, 0.95)
    return _finish(body, lowpass_hz=6200.0)


def bake_quick_draw(rng: np.random.Generator) -> np.ndarray:
    n = int(SR * 0.38)
    hit = _onepole(_noise(n, rng), 6000.0, high=True) * _decay(n, 18.0, 0.4) * 0.52
    air = _onepole(_noise(n, rng), 2600.0, high=True) * _decay(n, 130.0, 6.0) * 0.20
    body = hit + air
    body += _ring(n, 1490.0 * float(rng.uniform(0.97, 1.03)), 190.0, 0.34)
    body += _ring(n, 2910.0 * float(rng.uniform(0.96, 1.04)), 150.0, 0.18)
    body += _ring(n, 4020.0 * float(rng.uniform(0.97, 1.03)), 90.0, 0.10)
    body += _ring(n, 92.0, 120.0, 0.85)
    return _finish(body, lowpass_hz=6800.0)


def bake_rage_slash(rng: np.random.Generator) -> np.ndarray:
    n = int(SR * 0.45)
    thump = _ring(n, 68.0 * float(rng.uniform(0.95, 1.05)), 170.0, 1.15)
    crunch = np.tanh(_onepole(_noise(n, rng), 1300.0) * 6.0) * _decay(n, 110.0, 1.2) * 0.40
    # 湿闷的撕肉：中频带噪声 + 快速幅度抖动
    flesh = _onepole(_onepole(_noise(n, rng), 950.0, high=True), 320.0) * _decay(n, 200.0, 3.0) * 0.45
    am = 1.0 + 0.55 * np.sin(2.0 * np.pi * 47.0 * np.arange(n, dtype=np.float32) / SR)
    edge = _ring(n, 2180.0 * float(rng.uniform(0.96, 1.04)), 70.0, 0.12)
    return _finish(thump + crunch + flesh * am.astype(np.float32) + edge, lowpass_hz=4200.0)


def bake_upper(rng: np.random.Generator) -> np.ndarray:
    n = int(SR * 0.26)
    # 上扫气流：低频噪声渐弱 + 高频噪声渐强，做出"从下往上"的感觉
    low = _onepole(_noise(n, rng), 1500.0) * np.linspace(1.0, 0.15, n, dtype=np.float32) * 0.72
    high = _onepole(_noise(n, rng), 3400.0, high=True) * np.linspace(0.05, 1.0, n, dtype=np.float32) * 0.30
    crack = _onepole(_noise(n, rng), 6500.0, high=True) * _decay(n, 12.0, 0.3) * 0.45
    body = low + high + crack
    body += _ring(n, 1180.0 * float(rng.uniform(0.97, 1.03)), 90.0, 0.22)
    body += _ring(n, 112.0, 130.0, 0.85)
    return _finish(body, lowpass_hz=7000.0)


KINDS = {
    "impact_thrust": bake_thrust,
    "impact_quick_draw": bake_quick_draw,
    "impact_rage_slash": bake_rage_slash,
    "impact_upper": bake_upper,
}


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
    ap = argparse.ArgumentParser(description="技能命中声（原创合成）")
    ap.add_argument("--out", default=str(OUT_DIR))
    args = ap.parse_args()
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    ok = True
    for kind, maker in KINDS.items():
        line = []
        # 种子必须确定性：内置 hash() 每个进程随机化，会让每次产出不同
        base = sum(ord(c) * (i + 1) for i, c in enumerate(kind))
        for v in range(1, VARIANTS + 1):
            rng = _rng(0x51E1 + v * 97 + base)
            info = write_wav(out_dir / f"{kind}_{v}.wav", maker(rng))
            line.append(info)
            if info["clipped"] or info["peak"] >= 0.76 or info["first"] or info["last"]:
                ok = False
        print(f"  {kind:<20} {line[0]['seconds']:.3f}s  质心{line[0]['centroid']:>6.0f}Hz  "
              f"峰值{max(i['peak'] for i in line):.3f}  RMS{line[0]['rms']:.3f}  "
              f"削波{sum(i['clipped'] for i in line)}")
    print(f"\n输出目录: {out_dir}")
    print("下一步：确认 .import 的 compress/mode=0，并把技能命中映射接进 battle_fx._impact_sound")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
