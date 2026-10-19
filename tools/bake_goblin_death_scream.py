#!/usr/bin/env python3
"""哥布林死亡音效 v2：原创程序合成的「啊~~」嘶吼（路线 A）。

为什么换路线：v1 是把受击声变调/拉长（路线 B 派生），音高对了但**音色不对**——
变调改变不了发声方式，听起来还是同一只小怪物在被掐，不是临死嘶吼。
负责人要的听感是「啊~~、嘶哑且尖锐」，所以直接合成：

    声带脉冲激励（带抖动与次谐波 → 嘶哑）
  + 「啊」元音共振峰 F1/F2/F3（→ 是人声而不是蜂鸣）
  + 高频噪声层（→ 尖锐）
  + tanh 过载（→ 破音的粗糙感）
  + 音高下滑包络（→ 「啊~~」的叹气式收尾）

三个变体用不同基频/抖动种子/过载量区分，音高一致、音色有差异。

用法：
    python tools/bake_goblin_death_scream.py
    python tools/bake_goblin_death_scream.py --seconds 0.85 --dry-run
"""

from __future__ import annotations

import argparse
import wave
from pathlib import Path

import numpy as np

SR = 48000
PEAK = 0.72
FADE_MS = 3.0
KIND = "goblin_death"
ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "game/assets/audio_v3"
HURT_DIR = OUT_DIR

# 每个变体：起始基频、结束基频、抖动强度、次谐波量、过载量、噪声音量
VARIANTS = [
    dict(seed=11, f_start=660.0, f_end=395.0, jitter=0.055, sub=0.34, drive=2.6, noise=0.30),
    dict(seed=22, f_start=720.0, f_end=430.0, jitter=0.048, sub=0.28, drive=2.9, noise=0.26),
    dict(seed=33, f_start=600.0, f_end=360.0, jitter=0.062, sub=0.40, drive=2.3, noise=0.34),
]

# 「啊」元音共振峰：小体型生物整体上移（中心频率 Hz, 带宽 Hz, 增益）
FORMANTS = [
    (900.0, 140.0, 1.00),
    (1520.0, 200.0, 0.72),
    (2760.0, 300.0, 0.45),
    (3800.0, 420.0, 0.26),
]


def _smooth(x: np.ndarray, width: int) -> np.ndarray:
    if width <= 1:
        return x
    k = np.hanning(width).astype(np.float32)
    k /= k.sum()
    return np.convolve(x, k, mode="same").astype(np.float32)


def _formant_gain(freqs: np.ndarray) -> np.ndarray:
    gain = np.zeros_like(freqs, dtype=np.float32)
    for center, bandwidth, level in FORMANTS:
        gain += level / (1.0 + ((freqs - center) / bandwidth) ** 2)
    # 极低频收敛，避免轰隆声压过共振峰
    gain *= 1.0 / (1.0 + (120.0 / np.maximum(freqs, 1.0)) ** 2)
    return gain


def bake_variant(cfg: dict, seconds: float) -> tuple[np.ndarray, dict]:
    rng = np.random.default_rng(cfg["seed"])
    n = int(round(seconds * SR))
    t = np.arange(n, dtype=np.float32) / SR
    u = t / max(1e-6, seconds)

    # ① 音高曲线：「啊~~」起音偏高、持续略降、尾部下沉；叠颤音与随机抖动
    glide = cfg["f_start"] * (cfg["f_end"] / cfg["f_start"]) ** (u ** 0.85)
    vibrato = 1.0 + 0.022 * np.sin(2.0 * np.pi * 5.2 * t + cfg["seed"]).astype(np.float32)
    jitter = 1.0 + cfg["jitter"] * _smooth(rng.standard_normal(n).astype(np.float32), 96)
    f_inst = glide * vibrato * jitter

    # ② 声带激励：锯齿 + 脉冲偏斜，再叠次谐波（声带不稳 → 嘶哑的粗颗粒）
    phase = 2.0 * np.pi * np.cumsum(f_inst) / SR
    saw = 2.0 * (np.mod(phase / (2.0 * np.pi), 1.0)) - 1.0
    glottal = (saw - 0.5 * saw * saw).astype(np.float32)
    sub = np.sin(0.5 * phase).astype(np.float32)
    excitation = glottal + cfg["sub"] * sub

    # ③ 噪声层：宽带噪声给「尖锐」的嘶嘶边缘（后面同样过共振峰，才不像吹气）
    noise = rng.standard_normal(n).astype(np.float32)
    noise = np.diff(noise, prepend=noise[:1]).astype(np.float32)  # 提亮
    excitation = excitation + cfg["noise"] * noise

    # ④ 共振峰塑形（频域加权），让它成为「啊」而不是蜂鸣
    spec = np.fft.rfft(excitation)
    freqs = np.fft.rfftfreq(n, 1.0 / SR).astype(np.float32)
    shaped = np.fft.irfft(spec * _formant_gain(freqs), n=n).astype(np.float32)

    # ⑤ 过载破音 + 幅度抖动：嘶哑的关键，纯正弦永远做不出"破"
    am = 1.0 + 0.28 * _smooth(rng.standard_normal(n).astype(np.float32), 240)
    driven = np.tanh(cfg["drive"] * shaped * am).astype(np.float32)

    # ⑥ 包络：快起音、长持续、自然衰减（「啊~~」的收尾）
    env = np.ones(n, dtype=np.float32)
    attack = int(0.035 * SR)
    env[:attack] = np.linspace(0.0, 1.0, attack, dtype=np.float32) ** 1.5
    release = int(0.42 * n)
    env[n - release:] *= np.linspace(1.0, 0.0, release, dtype=np.float32) ** 1.4
    out = driven * env

    # ⑦ 归一到 0.72、去直流、首尾淡出到 0
    out -= float(out.mean())
    peak = float(np.abs(out).max())
    if peak > 1e-6:
        out *= PEAK / peak
    f = max(1, int(SR * FADE_MS / 1000.0))
    out[:f] *= np.linspace(0.0, 1.0, f, dtype=np.float32)
    out[-f:] *= np.linspace(1.0, 0.0, f, dtype=np.float32)
    out[0] = 0.0
    out[-1] = 0.0
    return out, {"centroid": _centroid(out), "flatness": _flatness(out)}


def _centroid(x: np.ndarray) -> float:
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    freqs = np.fft.rfftfreq(len(x), 1.0 / SR)
    total = float(spec.sum())
    return float((spec * freqs).sum() / total) if total > 1e-9 else 0.0


def _flatness(x: np.ndarray) -> float:
    """谱平坦度：噪声性越高越接近 1。嘶哑但仍是人声，目标 0.05~0.25。"""
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x)))) + 1e-9
    return float(np.exp(np.mean(np.log(spec))) / np.mean(spec))


def write_wav(path: Path, x: np.ndarray) -> dict:
    pcm = (np.clip(x, -1.0, 1.0) * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    y = pcm.astype(np.float32) / 32767.0
    return {
        "seconds": round(len(y) / SR, 4),
        "peak": round(float(np.abs(y).max()), 4),
        "rms": round(float(np.sqrt(np.mean(y ** 2))), 4),
        "first": int(pcm[0]),
        "last": int(pcm[-1]),
        "clipped": int((np.abs(pcm.astype(np.int32)) >= 32767).sum()),
    }


def hurt_seconds() -> list[float]:
    out: list[float] = []
    for i in (1, 2, 3):
        p = HURT_DIR / f"goblin_hurt_{i}.wav"
        if p.exists():
            with wave.open(str(p), "rb") as w:
                out.append(w.getnframes() / w.getframerate())
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="goblin_death 嘶吼（原创合成）")
    ap.add_argument("--seconds", type=float, default=0.0,
                    help="目标时长；0 = 按受击音效的 2 倍自动定")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    hurt = hurt_seconds()
    targets = [args.seconds] * len(VARIANTS) if args.seconds > 0 else [round(s * 2.0, 4) for s in hurt]
    if len(targets) < len(VARIANTS):
        targets = (targets * len(VARIANTS))[: len(VARIANTS)]
    print(f"目标时长: {['%.3fs' % v for v in targets]}（受击 x2）")
    print(f"共振峰: {[(c, b) for c, b, _ in FORMANTS]}")
    if args.dry_run:
        return 0

    for i, cfg in enumerate(VARIANTS, start=1):
        seconds = targets[i - 1]
        x, metrics = bake_variant(cfg, seconds)
        info = write_wav(OUT_DIR / f"{KIND}_{i}.wav", x)
        print(f"  {KIND}_{i}.wav  {info['seconds']:.3f}s  f0 {cfg['f_start']:.0f}->{cfg['f_end']:.0f}Hz  "
              f"质心 {metrics['centroid']:.0f}Hz  平坦度 {metrics['flatness']:.3f}  "
              f"峰值{info['peak']:.3f} RMS{info['rms']:.3f} 削波{info['clipped']}")
        if info["clipped"] or info["peak"] >= 0.76 or info["first"] or info["last"]:
            print("    [警告] 违反交付规范")
    print(f"\n输出目录: {OUT_DIR}")
    print("下一步：确认 .import 的 compress/mode=0（已有文件会保留设置），然后在游戏里试听")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
