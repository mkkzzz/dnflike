#!/usr/bin/env python3
"""真实挥剑声：把 CC0 录音加工成工程用的招式音（路线 B）。

为什么换：出招音原本是程序合成的 whoosh，负责人听感上觉得"不像游戏里的挥剑"，
要求改成真实录音。于是改用 OpenGameArt 的 CC0 素材
（Swishes Sound Pack, artisticdude, CC0）——13 段真实挥动录音
（木棍/衣架在麦克风前挥动，4 轻 9 重），比合成噪声更接近游戏听感。

加工内容（19 文档 3.3 路线 B 的标准流程）：
  选段（按有声段裁掉静音）-> 重采样到 48 kHz 单声道 -> 变调（部分招式做 ±1~4 半音）
  -> 归一化到 0.72 -> 首尾 3 ms 淡出且首尾采样为 0

映射原则：轻招用短而亮的段，重招用长而沉的段，突刺用最短段并升调，
拔刀斩/怒斩用长段并做音高微调，让同一套录音听出九个不同的招式。

用法：
    python tools/bake_sword_swings.py --src D:\\dnflike_local\\audio_src\\sword_swing\\swishes\\swishes
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
META_DIR = ROOT / "audio/sword_swing"
DEFAULT_SRC = Path(r"D:\dnflike_local\audio_src\sword_swing\swishes\swishes")

# kind -> [(源文件, 变速比, 最长时长秒)]
# 两包混用：Swishes（暖气流，质心 1.4~2.3 kHz）打普通挥砍，
# StarNinjas 剑击（金属锐响，质心 12~14 kHz、主体 0.10~0.28 s）打技能与重击。
# 变速比 >1 升调变短（突刺/空斩），<1 降调变长（重招）。
MAP: dict[str, list[tuple[str, float, float]]] = {
    # 普通挥砍：Swishes（暖气流）——三个变体同包，保证音色一致
    "swing_light": [("swish-12.wav", 1.00, 0.20), ("swish-11.wav", 1.00, 0.20), ("swish-13.wav", 1.00, 0.20)],
    "swing_back": [("swish-2.wav", 1.00, 0.20), ("swish-10.wav", 1.00, 0.20), ("swish-5.wav", 1.00, 0.20)],
    "swing_air": [("swish-13.wav", 1.12, 0.18), ("swish-12.wav", 1.12, 0.18), ("swish-11.wav", 1.12, 0.18)],
    # 技能/重击：StarNinjas 剑击（金属锐响），同为真实录音但更"整刀"
    "swing_heavy": [("sword.8.wav", 0.92, 0.28), ("sword.7.wav", 0.92, 0.28), ("sword.5.wav", 0.92, 0.28)],
    "swing_upper": [("sword.1.wav", 1.05, 0.22), ("sword.4.wav", 1.05, 0.22), ("sword.6.wav", 1.05, 0.22)],
    "thrust": [("sword.3.wav", 1.18, 0.15), ("sword.6.wav", 1.18, 0.15), ("sword.4.wav", 1.18, 0.15)],
    "dash_strike": [("sword.5.wav", 1.00, 0.22), ("sword.1.wav", 1.00, 0.22), ("sword.2.wav", 1.00, 0.22)],
    "draw_strike": [("sword.9.wav", 1.05, 0.28), ("sword.10.wav", 1.05, 0.28), ("sword.8.wav", 1.05, 0.28)],
    "rage_strike": [("sword.7.wav", 0.90, 0.28), ("sword.8.wav", 0.90, 0.28), ("sword.10.wav", 0.90, 0.28)],
}


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
        raise SystemExit(f"{path.name}: 不支持的位深 {width * 8} bit")
    if ch > 1:
        usable = (x.size // ch) * ch
        x = x[:usable].reshape(-1, ch).mean(axis=1)
    return x, sr


def trim(x: np.ndarray, sr: int) -> np.ndarray:
    """按有声段裁剪：1% 峰值门限（保留尾音），前后各留 6 ms。"""
    if x.size == 0:
        return x
    thr = float(np.abs(x).max()) * 0.01
    idx = np.where(np.abs(x) > thr)[0]
    if idx.size == 0:
        return x
    pad = int(sr * 0.006)
    a = max(0, idx[0] - pad)
    b = min(x.size, idx[-1] + pad)
    return x[a:b]


def resample(x: np.ndarray, sr_in: int, sr_out: int, ratio: float = 1.0) -> np.ndarray:
    """先按采样率换算，再按 ratio 变速（ratio>1 = 升调且变短）。"""
    n_out = max(2, int(round(x.size * sr_out / sr_in / ratio)))
    src = np.linspace(0.0, 1.0, x.size, dtype=np.float64)
    dst = np.linspace(0.0, 1.0, n_out, dtype=np.float64)
    return np.interp(dst, src, x).astype(np.float32)


def finish(x: np.ndarray, max_seconds: float) -> np.ndarray:
    limit = int(max_seconds * SR)
    if x.size > limit:
        x = x[:limit]
        # 提前截断会把尾巴切断，补一段 6 ms 收尾
        tail = min(x.size, int(SR * 0.006))
        x[-tail:] *= np.linspace(1.0, 0.0, tail, dtype=np.float32)
    x = x.astype(np.float32, copy=True)
    x -= float(x.mean())
    peak = float(np.abs(x).max())
    if peak > 1e-6:
        x *= PEAK / peak
    f = max(1, int(SR * FADE_MS / 1000.0))
    f = min(f, x.size // 2)
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
    spec = np.abs(np.fft.rfft(y * np.hanning(len(y)))) if len(y) > 4 else np.zeros(1, dtype=np.float32)
    freqs = np.fft.rfftfreq(len(y), 1.0 / SR) if len(y) > 4 else np.zeros(1)
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


def _lowpass(x: np.ndarray, cutoff: float, passes: int = 2) -> np.ndarray:
    """一阶级联低通：压一点金属嘶声，但保留锐利感。"""
    y = x.astype(np.float32, copy=True)
    a = float(np.clip(1.0 - np.exp(-2.0 * np.pi * cutoff / SR), 1e-4, 0.9999))
    for _ in range(passes):
        acc = 0.0
        out = np.empty_like(y)
        for i in range(y.size):
            acc += a * (y[i] - acc)
            out[i] = acc
        y = out
    return y


def convert_decoded(src: Path, out: Path) -> int:
    """把 bake_audio_source_decode.mjs 产出的 <name>.f32 + .json 转成 48k 单声道 WAV。

    源是 StarNinjas 的 CC0 剑击包：主体 0.10~0.28 s、质心 12~14 kHz（金属锐响）。
    直接进游戏会偏刺，所以这里做一次 11 kHz 二级低通，再交给同一套 finish 归一化。
    """
    out.mkdir(parents=True, exist_ok=True)
    count = 0
    for meta_path in sorted(src.glob("*.json")):
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        data = np.fromfile(src / (meta_path.stem + ".f32"), dtype="<f4")
        ch = int(meta.get("channels", 1))
        sr = int(meta.get("sampleRate", 44100))
        if ch > 1:
            data = data[:(data.size // ch) * ch].reshape(-1, ch).mean(axis=1)
        x = trim(data, sr)
        x = resample(x, sr, SR, ratio=1.0)
        x = _lowpass(x, 11000.0)
        x = finish(x, 0.40)
        write_wav(out / (meta_path.stem + ".wav"), x)
        count += 1
    print(f"  转换 {count} 段 -> {out}")
    return count


def main() -> int:
    ap = argparse.ArgumentParser(description="CC0 录音挥剑声加工")
    ap.add_argument("--src", default=str(DEFAULT_SRC))
    ap.add_argument("--out", default=str(OUT_DIR))
    ap.add_argument("--convert", default="", help="解码产物目录（含 .f32/.json），先转成 WAV 再烘焙")
    args = ap.parse_args()
    src_dir = Path(args.src)
    out_dir = Path(args.out)
    if not src_dir.is_dir():
        raise SystemExit(f"源目录不存在: {src_dir}")
    out_dir.mkdir(parents=True, exist_ok=True)
    META_DIR.mkdir(parents=True, exist_ok=True)

    if args.convert:
        convert_decoded(Path(args.convert), src_dir)

    report: dict[str, list[dict]] = {}
    ok = True
    for kind, entries in MAP.items():
        infos = []
        for index, (name, rate_ratio, max_sec) in enumerate(entries, start=1):
            raw, sr = load_wav(src_dir / name)
            piece = trim(raw, sr)
            piece = resample(piece, sr, SR, ratio=rate_ratio)
            piece = finish(piece, max_sec)
            info = write_wav(out_dir / f"{kind}_{index}.wav", piece)
            info["source"] = name
            info["rate_ratio"] = rate_ratio
            infos.append(info)
            if info["clipped"] or info["peak"] >= 0.76 or info["first"] or info["last"]:
                ok = False
        report[kind] = infos
        first = infos[0]
        print(f"  {kind:<13} {first['seconds']:.3f}s  质心{first['centroid']:>5.0f}Hz  "
              f"峰值{max(i['peak'] for i in infos):.3f}  RMS{first['rms']:.3f}  "
              f"源[{', '.join(i['source'] for i in infos)}]")

    (META_DIR / "validation.json").write_text(
        json.dumps({
            "schema": "dnflike/audio-validation/v1",
            "kind": "sword_swing",
            "sample_rate": SR,
            "variants_per_kind": 3,
            "source_pack": "Swishes Sound Pack",
            "entries": report,
        }, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"\n输出: {out_dir}")
    print(f"校验: {META_DIR / 'validation.json'}")
    print("下一步：确认 .import 的 compress/mode=0")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
