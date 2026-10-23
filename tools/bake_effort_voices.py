#!/usr/bin/env python3
"""出招人声（真实录音，CC0）：从男性发力/嘶吼素材里挑短句，做成四档起手声。

为什么不用合成：先做过一版共振峰合成的"用力"人声，负责人实机反馈"不像人"。
人声这类音必须用真实录音（见 19 文档 3.8 的判断表）。

素材：OpenGameArt《Male Grunt/Yelling sounds》（HaelDB，CC0 + OGA-BY 3.0 双许可，
本工程取 CC0），4 位男声、每人 10~12 段嘶吼，共 9.7 MB WAV。

挑选逻辑（不靠听也能自动分档）：按"有声段长度"排序取四组——
  最短 3 段 -> voice_light（轻击）
  次短 3 段 -> voice_mid（中击）
  再次 3 段 -> voice_heavy（重击）
  最长 3 段 -> voice_rage（血怒火吼）
再各自裁剪、重采样到 48 kHz 单声道、归一化到峰值 0.72。

用法：
    python tools/bake_effort_voices.py --src <解压出来的目录>
"""

from __future__ import annotations

import argparse
import hashlib
import json
import wave
from pathlib import Path

import numpy as np

SR = 48000
PEAK = 0.72
FADE_MS = 3.0
ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "game/assets/audio_v3"
META_DIR = ROOT / "audio/effort_voice"

TIERS = ["voice_light", "voice_mid", "voice_heavy", "voice_rage"]
PER_TIER = 3
# 每档的时长上限（秒）。2026-10-23 修订：负责人反馈"人声不行"，主要问题是
# 0.22~0.58s 太长、和挥剑声重叠成一团。起手声应该只是"一下子"，
# 所以整体砍到 0.16~0.30s（取每段发声最靠前的一段，砍掉后面的拖音）。
TIER_MAX = {"voice_light": 0.16, "voice_mid": 0.20, "voice_heavy": 0.24, "voice_rage": 0.30}
# 候选池只取较短的一段，避免选到整句长啸
TIER_SPAN = {"voice_light": (0.00, 0.22), "voice_mid": (0.15, 0.40),
             "voice_heavy": (0.35, 0.62), "voice_rage": (0.55, 1.00)}
# 允许的最短/最长有声段（秒）：太短像"啧"，太长是完整惨叫，不适合当起手
MIN_BODY = 0.10
MAX_BODY = 0.85


def load_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as w:
        n = w.getnframes()
        sr = w.getframerate()
        ch = w.getnchannels()
        width = w.getsampwidth()
        raw = w.readframes(n)
    if width == 2:
        x = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    elif width == 3:
        b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
        v = b[:, 0].astype(np.int32) | (b[:, 1].astype(np.int32) << 8) | (b[:, 2].astype(np.int32) << 16)
        v = np.where(v >= 1 << 23, v - (1 << 24), v)
        x = v.astype(np.float32) / float(1 << 23)
    elif width == 4:
        x = np.frombuffer(raw, dtype="<i4").astype(np.float32) / 2147483648.0
    else:
        raise SystemExit(f"{path.name}: 不支持的位深 {width * 8}")
    if ch > 1:
        usable = (x.size // ch) * ch
        x = x[:usable].reshape(-1, ch).mean(axis=1)
    return x, sr


def body_span(x: np.ndarray, sr: int) -> tuple[int, int]:
    """有声段索引：3% 峰值门限，前后各留 8 ms。"""
    peak = float(np.abs(x).max()) if x.size else 0.0
    if peak <= 0.0:
        return 0, x.size
    idx = np.where(np.abs(x) > peak * 0.03)[0]
    if idx.size == 0:
        return 0, x.size
    pad = int(sr * 0.008)
    return max(0, int(idx[0]) - pad), min(x.size, int(idx[-1]) + pad)


def resample(x: np.ndarray, sr_in: int, sr_out: int) -> np.ndarray:
    n_out = max(2, int(round(x.size * sr_out / sr_in)))
    src = np.linspace(0.0, 1.0, x.size, dtype=np.float64)
    dst = np.linspace(0.0, 1.0, n_out, dtype=np.float64)
    return np.interp(dst, src, x).astype(np.float32)


def finish(x: np.ndarray, max_seconds: float = 0.0) -> np.ndarray:
    x = x.astype(np.float32, copy=True)
    if max_seconds > 0.0:
        limit = int(max_seconds * SR)
        if x.size > limit:
            x = x[:limit]
            tail = max(1, min(x.size, int(SR * 0.008)))
            x[-tail:] *= np.linspace(1.0, 0.0, tail, dtype=np.float32)
    x -= float(x.mean())
    peak = float(np.abs(x).max())
    if peak > 1e-6:
        x *= PEAK / peak
    f = max(1, min(int(SR * FADE_MS / 1000.0), x.size // 2))
    x[:f] *= np.linspace(0.0, 1.0, f, dtype=np.float32)
    x[-f:] *= np.linspace(1.0, 0.0, f, dtype=np.float32)
    x[0] = 0.0
    x[-1] = 0.0
    return x


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
    return {
        "seconds": round(len(y) / SR, 4),
        "peak": round(float(np.abs(y).max()), 4),
        "rms": round(float(np.sqrt(np.mean(y ** 2))), 4),
        "centroid": round(float((spec * freqs).sum() / max(1e-9, spec.sum())), 1),
        "first": int(pcm[0]),
        "last": int(pcm[-1]),
        "clipped": int((np.abs(pcm.astype(np.int32)) >= 32767).sum()),
        "sha256": hashlib.sha256(pcm.tobytes()).hexdigest()[:16],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="出招人声（真实录音）")
    ap.add_argument("--src", required=True, help="Male Grunt/Yelling sounds 解压目录")
    ap.add_argument("--out", default=str(OUT_DIR))
    args = ap.parse_args()
    src = Path(args.src)
    if not src.is_dir():
        raise SystemExit(f"源目录不存在: {src}")
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    META_DIR.mkdir(parents=True, exist_ok=True)

    candidates: list[dict] = []
    for path in sorted(src.rglob("*.wav")):
        try:
            x, sr = load_wav(path)
        except SystemExit:
            continue
        if x.size < int(0.05 * sr):
            continue
        a, b = body_span(x, sr)
        body = (b - a) / sr
        if not (MIN_BODY <= body <= MAX_BODY):
            continue
        candidates.append({"path": path, "x": x, "sr": sr, "a": a, "b": b, "body": body})

    print(f"候选 {len(candidates)} 段（有声段 {MIN_BODY:.2f}~{MAX_BODY:.2f}s）")
    need = len(TIERS) * PER_TIER
    if len(candidates) < need:
        raise SystemExit(f"素材不足：需要 {need} 段，只有 {len(candidates)} 段")

    candidates.sort(key=lambda c: c["body"])
    report: dict[str, list[dict]] = {}
    ok = True
    for kind in TIERS:
        lo_frac, hi_frac = TIER_SPAN[kind]
        lo = int(lo_frac * len(candidates))
        hi = max(lo + PER_TIER, int(hi_frac * len(candidates)))
        pool = candidates[lo:hi]
        if len(pool) < PER_TIER:
            pool = candidates[:PER_TIER]
        picks = [pool[int(i * (len(pool) - 1) / max(1, PER_TIER - 1))] for i in range(PER_TIER)]
        infos = []
        for index, item in enumerate(picks, start=1):
            x = item["x"][item["a"]:item["b"]]
            x = resample(x, item["sr"], SR)
            x = finish(x, TIER_MAX[kind])
            info = write_wav(out_dir / f"{kind}_{index}.wav", x)
            info["source"] = item["path"].name
            info["source_body"] = round(item["body"], 3)
            infos.append(info)
            if info["clipped"] or info["peak"] >= 0.76 or info["first"] or info["last"]:
                ok = False
        report[kind] = infos
        print(f"  {kind:<12} {infos[0]['seconds']:.3f}s  质心{infos[0]['centroid']:>5.0f}Hz  "
              f"峰 {max(i['peak'] for i in infos):.3f}  源[{', '.join(i['source'] for i in infos)}]")

    (META_DIR / "validation.json").write_text(
        json.dumps({
            "schema": "dnflike/audio-validation/v1",
            "kind": "effort_voice",
            "sample_rate": SR,
            "variants_per_kind": PER_TIER,
            "tier_rule": "按有声段长度均匀分四档，最短=light、最长=rage",
            "entries": report,
        }, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"\n输出: {out_dir}")
    print(f"校验: {META_DIR / 'validation.json'}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
