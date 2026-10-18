#!/usr/bin/env python3
"""草丛（植被可破坏物）破坏音效：原创程序合成。

按 docs/design/19_音效生产工作流.md 的**路线 A**：不使用任何外部素材，
配方为「脆断木质 + 叶片摩擦 + 落地闷响」三层，输出符合工程规范：

    48 kHz / 单声道 / 16 bit PCM / 峰值 0.72（< 0.76 上限）/ 首尾采样 0 / 无削波

用法：
    python tools/bake_foliage_audio.py            # 生成 3 个变体到 game/assets/audio_v3/
    python tools/bake_foliage_audio.py --out DIR  # 输出到指定目录（试听/对比用）

生成的 kind 名为 `foliage_break`，运行时在 combat_audio.gd 的 SOUND_SPECS 里登记。
"""

from __future__ import annotations

import argparse
import wave
from pathlib import Path

import numpy as np

SR = 48000
KIND = "foliage_break"
VARIANTS = 3
PEAK = 0.72
FADE_MS = 3.0

# 每个变体一个固定种子 -> 同环境下可复现
SEEDS = [0x5F0B1E01, 0x5F0B1E02, 0x5F0B1E03]


def _rng(seed: int) -> np.random.Generator:
    return np.random.default_rng(seed)


def _noise(n: int, rng: np.random.Generator) -> np.ndarray:
    return rng.standard_normal(n).astype(np.float32)


def _lowpass(x: np.ndarray, cutoff: float) -> np.ndarray:
    """一阶低通（时域递归），用于把白噪声压成叶片/木头的粗糙感。"""
    alpha = float(np.clip(1.0 - np.exp(-2.0 * np.pi * cutoff / SR), 1e-4, 0.9999))
    y = np.empty_like(x)
    acc = 0.0
    for i in range(x.size):
        acc += alpha * (x[i] - acc)
        y[i] = acc
    return y


def _highpass(x: np.ndarray, cutoff: float) -> np.ndarray:
    return x - _lowpass(x, cutoff)


def _envelope(n: int, attack_ms: float, decay_ms: float) -> np.ndarray:
    a = max(1, int(SR * attack_ms / 1000.0))
    d = max(1, int(SR * decay_ms / 1000.0))
    env = np.zeros(n, dtype=np.float32)
    a = min(a, n)
    env[:a] = np.linspace(0.0, 1.0, a, dtype=np.float32)
    rest = n - a
    if rest > 0:
        d = min(d, rest)
        env[a:a + d] = np.exp(-np.linspace(0.0, 3.2, d, dtype=np.float32))
        if a + d < n:
            env[a + d:] = 0.0
    return env


def _grains(n: int, rng: np.random.Generator, count: int, spread_ms: float) -> np.ndarray:
    """随机分布的小颗粒包络：模拟叶片被扯碎的密集碎响。"""
    env = np.zeros(n, dtype=np.float32)
    spread = max(1, int(SR * spread_ms / 1000.0))
    for _ in range(count):
        start = int(rng.integers(0, max(1, n - spread)))
        length = int(rng.integers(spread // 6 + 2, spread // 2 + 3))
        length = min(length, n - start)
        seg = rng.random(length).astype(np.float32)
        seg = np.exp(-np.linspace(0.0, 4.0, length, dtype=np.float32)) * seg
        env[start:start + length] += seg * float(rng.uniform(0.25, 0.8))
    return env


def bake_variant(seed: int, index: int) -> np.ndarray:
    rng = _rng(seed)
    length = int(SR * (0.42 + 0.06 * index))
    n = length
    out = np.zeros(n, dtype=np.float32)

    # ① 木质脆断：宽频瞬态 + 两次短共振（像是枝干被劈开）
    crack = _noise(n, rng) * _envelope(n, 0.6, 55.0) * 0.9
    out += _lowpass(crack, 5200.0)
    for offset_ms, freq, gain in ((0.0, 1150.0, 0.35), (7.0, 760.0, 0.22)):
        start = int(SR * offset_ms / 1000.0)
        tail = n - start
        if tail <= 0:
            continue
        t = np.arange(tail, dtype=np.float32) / SR
        ring = np.sin(2.0 * np.pi * freq * t) * np.exp(-t * 46.0) * gain
        out[start:] += ring.astype(np.float32)

    # ② 叶片摩擦：中高频噪声 + 密集颗粒，比脆断长一些
    leaf = _highpass(_noise(n, rng), 1800.0) * _envelope(n, 6.0, 260.0) * 0.55
    leaf *= (0.55 + _grains(n, rng, count=26, spread_ms=300.0))
    out += leaf * 0.8

    # ③ 落地闷响：低频一点，给重量感
    t = np.arange(n, dtype=np.float32) / SR
    thud = np.sin(2.0 * np.pi * 88.0 * t) * np.exp(-t * 26.0) * 0.5
    out += thud.astype(np.float32)

    # 归一化 + 首尾渐变 + 去直流
    out -= float(out.mean())
    peak = float(np.abs(out).max())
    if peak > 1e-6:
        out *= PEAK / peak
    f = max(1, int(SR * FADE_MS / 1000.0))
    out[:f] *= np.linspace(0.0, 1.0, f, dtype=np.float32)
    out[-f:] *= np.linspace(1.0, 0.0, f, dtype=np.float32)
    return out


def write_wav(path: Path, x: np.ndarray) -> dict:
    pcm = np.clip(x, -1.0, 1.0)
    pcm = (pcm * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(SR)
        fh.writeframes(pcm.tobytes())
    y = pcm.astype(np.float32) / 32767.0
    return {
        "seconds": round(len(y) / SR, 4),
        "peak": round(float(np.abs(y).max()), 4),
        "rms": round(float(np.sqrt(np.mean(y ** 2))), 4),
        "first_sample": int(pcm[0]),
        "last_sample": int(pcm[-1]),
        "clipped": int((np.abs(pcm.astype(np.int32)) >= 32767).sum()),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=KIND + " 破坏音效（原创合成）")
    ap.add_argument("--out", default=str(Path(__file__).resolve().parents[1] / "game/assets/audio_v3"))
    args = ap.parse_args()
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"配方: 木质脆断 + 叶片摩擦 + 落地闷响   {SR} Hz / 单声道 / 16 bit")
    for index, seed in enumerate(SEEDS, start=1):
        data = bake_variant(seed, index)
        name = f"{KIND}_{index}.wav"
        info = write_wav(out_dir / name, data)
        warn = ""
        if info["clipped"]:
            warn += " [警告] 削波"
        if info["peak"] >= 0.76:
            warn += " [警告] 峰值超 0.76"
        print(f"  {name:<22} {info['seconds']:.3f}s 峰值{info['peak']:.3f} "
              f"RMS{info['rms']:.3f} 削波{info['clipped']}{warn}")
    print(f"\n输出目录: {out_dir}")
    print("下一步：确认 .import 的 compress/mode=0，并在 combat_audio.gd 的 SOUND_SPECS 登记")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
