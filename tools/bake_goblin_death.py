#!/usr/bin/env python3
"""哥布林死亡音效：从既有受击音效派生（路线 B「素材加工」的同源变体手法）。

需求（负责人）：比受击音效**音调高 3 个八度**、时长**长 2 倍**。

口径说明（见 docs/design/19_音效生产工作流.md 3.3 节）：
本工程把中文「N 个八度」按 **N x 8 个半音** 换算（不是 2 的 N 次方）。
所以 3 个八度 = 24 半音 = 频率 x4。若确实要"真八度"（x8），
用 --semitones 36 重跑即可。

为什么不能简单重采样：重采样升调必缩时（x4 升调会把 0.43s 压到 0.11s）。
需求同时要"更高"和"更长"，所以用相位声码器做保音高时长拉伸：
    先拉伸 S 倍（S = 时长倍数 x 音高倍数），再重采样 1/倍数 缩回
    结果：时长 = 原 x2，音高 = 原 x4
8 倍拉伸分 3 次 2 倍做，避免一次拉伸时合成跳距超过窗长而出现空档。

用法：
    python tools/bake_goblin_death.py                 # 默认 24 半音 / 2 倍时长
    python tools/bake_goblin_death.py --semitones 36   # 真八度 x8
    python tools/bake_goblin_death.py --dry-run        # 只打印换算，不写文件
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
SRC_DIR = ROOT / "game/assets/audio_v3"
OUT_DIR = SRC_DIR
KIND_IN = "goblin_hurt"
KIND_OUT = "goblin_death"


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as w:
        ch = w.getnchannels()
        width = w.getsampwidth()
        sr = w.getframerate()
        raw = w.readframes(w.getnframes())
    if width != 2:
        raise SystemExit(f"{path.name}: 只处理 16 bit PCM")
    x = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, sr


def write_wav(path: Path, x: np.ndarray) -> dict:
    pcm = np.clip(x, -1.0, 1.0)
    pcm = (pcm * 32767.0).astype("<i2")
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


def _stretch_once(x: np.ndarray, factor: float, n_fft: int = 1024) -> np.ndarray:
    """相位声码器：时长 x factor，音高不变（单次比例别太大）。"""
    hop_a = n_fft // 4
    hop_s = int(round(hop_a * factor))
    window = np.hanning(n_fft).astype(np.float32)
    pad = np.concatenate([np.zeros(n_fft, np.float32), x, np.zeros(n_fft * 2, np.float32)])
    frames = max(1, (len(pad) - n_fft) // hop_a + 1)
    out_len = hop_s * (frames - 1) + n_fft
    out = np.zeros(out_len, np.float32)
    norm = np.zeros(out_len, np.float32)
    bins = n_fft // 2 + 1
    expected = 2.0 * np.pi * hop_a * np.arange(bins) / n_fft
    acc = np.zeros(bins)
    prev_phase = None
    for i in range(frames):
        start = i * hop_a
        spec = np.fft.rfft(pad[start:start + n_fft] * window)
        mag = np.abs(spec)
        phase = np.angle(spec)
        if prev_phase is None:
            acc = phase.copy()
        else:
            delta = phase - prev_phase - expected
            delta = np.mod(delta + np.pi, 2.0 * np.pi) - np.pi
            acc = acc + (expected + delta) * (hop_s / hop_a)
        prev_phase = phase
        frame = np.fft.irfft(mag * np.exp(1j * acc), n=n_fft) * window
        s = i * hop_s
        out[s:s + n_fft] += frame.astype(np.float32)
        norm[s:s + n_fft] += window ** 2
    mask = norm > 1e-6
    out[mask] /= norm[mask]
    # 输入两侧补了 n_fft / 2*n_fft 的零，直接返回会把补零也拉伸进来（长度虚长）。
    # 真实信号在补后坐标的 [n_fft, n_fft+len(x))，映射到输出就按同一比例裁掉两端。
    start = int(round(n_fft * factor))
    stop = int(round((n_fft + len(x)) * factor))
    return out[start:stop]


def stretch(x: np.ndarray, factor: float, passes: int = 3) -> np.ndarray:
    """把 factor 拆成若干次小比例拉伸，避免单次跳距过大。"""
    if factor <= 0:
        return x
    step = factor ** (1.0 / passes)
    y = x
    for _ in range(passes):
        y = _stretch_once(y, step)
    return y


def resample_by(x: np.ndarray, ratio: float) -> np.ndarray:
    """ratio>1 为加速（升调缩时）。线性插值足够——本来就只剩几个周期。"""
    n_out = max(2, int(round(len(x) / ratio)))
    src = np.linspace(0.0, 1.0, len(x), dtype=np.float64)
    dst = np.linspace(0.0, 1.0, n_out, dtype=np.float64)
    return np.interp(dst, src, x).astype(np.float32)


def finish(x: np.ndarray) -> np.ndarray:
    x = x.astype(np.float32, copy=True)
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


def centroid(x: np.ndarray) -> float:
    """频谱质心，用来客观核对音高比例。"""
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    freqs = np.fft.rfftfreq(len(x), 1.0 / SR)
    total = float(spec.sum())
    return float((spec * freqs).sum() / total) if total > 1e-9 else 0.0


def peak_freq(x: np.ndarray) -> float:
    """最强谱峰频率：比质心更接近"音高"，用来核对升调倍数。"""
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    freqs = np.fft.rfftfreq(len(x), 1.0 / SR)
    spec[0] = 0.0  # 忽略直流
    if len(spec) < 2:
        return 0.0
    return float(freqs[int(np.argmax(spec))])


def main() -> int:
    ap = argparse.ArgumentParser(description="goblin_death 音效（由 goblin_hurt 派生）")
    ap.add_argument("--semitones", type=float, default=24.0,
                    help="音高提升的半音数；本工程口径 8 半音=1 个「八度」，默认 24（3 个）")
    ap.add_argument("--duration-scale", type=float, default=2.0, help="时长倍数，默认 2")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    ratio = 2.0 ** (args.semitones / 12.0)
    stretch_factor = args.duration_scale * ratio
    print(f"音高 +{args.semitones:g} 半音 = x{ratio:.3f}    时长 x{args.duration_scale:g}")
    print(f"做法: 相位声码器拉伸 x{stretch_factor:.2f}（分 3 次），再重采样 x{ratio:.3f} 缩时")
    if args.dry_run:
        return 0

    ok = True
    for i in range(1, VARIANTS + 1):
        src = SRC_DIR / f"{KIND_IN}_{i}.wav"
        if not src.exists():
            raise SystemExit(f"缺少源音效: {src}")
        x, sr = read_wav(src)
        if sr != SR:
            raise SystemExit(f"{src.name}: 采样率 {sr} != {SR}")
        y = stretch(x, stretch_factor)
        y = resample_by(y, ratio)
        y = finish(y)
        info = write_wav(OUT_DIR / f"{KIND_OUT}_{i}.wav", y)
        c_in, c_out = peak_freq(x), peak_freq(y)
        g_in, g_out = centroid(x), centroid(y)
        dur_ratio = info["seconds"] / (len(x) / SR)
        print(f"  {KIND_OUT}_{i}.wav  {info['seconds']:.3f}s (时长 x{dur_ratio:.3f})  "
              f"主峰 {c_in:.0f}->{c_out:.0f} Hz (x{c_out / max(1.0, c_in):.2f})  "
              f"质心 x{g_out / max(1.0, g_in):.2f}  "
              f"峰值{info['peak']:.3f} RMS{info['rms']:.3f} 削波{info['clipped']}")
        if info["clipped"] or info["peak"] >= 0.76 or abs(dur_ratio - args.duration_scale) > 0.05:
            ok = False
            print("    [警告] 违反交付规范或时长不符")
    print(f"\n输出目录: {OUT_DIR}")
    print("下一步：确认 .import 的 compress/mode=0，并在 combat_audio.gd 登记 goblin_death")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
