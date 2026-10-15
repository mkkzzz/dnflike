#!/usr/bin/env python3
"""音效外部素材加工工具（路线 B）。

把外部素材（多流/单流 Ogg 等）加工成工程规范的 WAV，并写出可校验报告。

规范（与 game/assets/audio_v3 既有文件一致）：
    48 kHz / 单声道 / 16 bit PCM / 峰值 < 0.76 / 首尾采样为 0 / 无削波

流程（对应 docs/design/19_音效生产工作流.md 第三节）：
    1. 预检：读文件头，识别是否为「多流 Ogg」（含 Ogg Skeleton + Vorbis 两条流）
    2. 解复用 + 解码：交给 node 辅助脚本（stb-vorbis，纯 WASM，无原生编译）
    3. 选段：20 ms 窗 RMS，按「平顶长度」排序（避免从发声中间切断）
    4. 加工：重采样 → 变调 → 去直流 → 归一化 → 首尾渐变
    5. 输出规范 WAV + validation 报告

用法：
    # 先看文件结构（不解码，不需要 node）
    python tools/bake_audio_source.py --inspect raw/a.ogg raw/b.ogg

    # 完整加工：每个源截一段，升 16 半音
    python tools/bake_audio_source.py --out-dir temp/sfx --kind goblin_hurt ^
        --semitones 16 --raw raw/a.ogg raw/b.ogg

    # 每个源截多段（用于凑满 3 个变体）
    python tools/bake_audio_source.py --out-dir temp/sfx --kind goblin_hurt ^
        --semitones 16 --per-file 3 --raw raw/*.ogg

依赖：
    - Python: numpy
    - 解码 Ogg 需要 node + stb-vorbis（装在仓库外，见 --node-dir）
      若环境有 ffmpeg，可用它先转成 WAV 再用本工具处理，跳过解码依赖。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

TARGET_SR = 48000
TARGET_PEAK = 0.72          # 低于工程上限 0.76
FADE_MS = 3.0
HEAD_PAD_MS = 8.0
TAIL_PAD_MS = 45.0
MIN_SEG_S = 0.28
MAX_SEG_S = 1.90

# 与 tools/bake_audio_source_decode.mjs 共享的中间产物命名
DECODE_SUFFIX = ".f32"
META_SUFFIX = ".json"


def read_ogg_pages(buf: bytes) -> list[tuple[int, int, int]]:
    """返回 [(start, end, serial), ...]。非 Ogg 返回空列表。"""
    pages: list[tuple[int, int, int]] = []
    off = 0
    while off + 27 <= len(buf) and buf[off:off + 4] == b"OggS":
        seg_count = buf[off + 26]
        payload = sum(buf[off + 27 + i] for i in range(seg_count))
        end = off + 27 + seg_count + payload
        serial = int.from_bytes(buf[off + 14:off + 18], "little")
        pages.append((off, end, serial))
        off = end
    return pages


def inspect(path: Path) -> dict:
    """预检：识别容器结构与流数量。"""
    buf = path.read_bytes()
    info: dict = {"file": path.name, "bytes": len(buf)}
    if buf[:4] == b"OggS":
        info["container"] = "ogg"
        pages = read_ogg_pages(buf)
        serials: dict[int, int] = {}
        codecs: set[str] = set()
        for start, end, serial in pages:
            serials[serial] = serials.get(serial, 0) + 1
            head = buf[start + 27:start + 27 + 64]
            if b"fishead" in head or b"fisbone" in head:
                codecs.add("skeleton")
            elif b"\x01vorbis" in head or b"vorbis" in head:
                codecs.add("vorbis")
            elif b"OpusHead" in head:
                codecs.add("opus")
            elif b"Speex" in head:
                codecs.add("speex")
        info["streams"] = len(serials)
        info["codecs"] = sorted(codecs)
        info["multiplexed"] = len(serials) > 1
        info["decode_note"] = (
            "多流 Ogg，必须先按 serial 解复用（工具会自动处理）"
            if info["multiplexed"] else "单流，可直接解码")
    elif buf[:4] == b"RIFF":
        info["container"] = "wav"
        info["decode_note"] = "WAV，无需解码，可直接处理"
    elif buf[:3] == b"ID3" or buf[:2] in (b"\xff\xfb", b"\xff\xf3"):
        info["container"] = "mp3"
        info["decode_note"] = "MP3 需要 ffmpeg 或额外解码器，本工具暂不支持"
    else:
        info["container"] = "unknown"
        info["decode_note"] = "未识别的容器"
    return info


def run_decoder(raw_dir: Path, out_dir: Path, node_dir: Path, node_exe: str) -> int:
    """调用 node 辅助脚本把 raw/ 解码成 <name>.f32 + <name>.json。"""
    helper = Path(__file__).with_name("bake_audio_source_decode.mjs")
    if not helper.exists():
        print(f"[错误] 找不到解码辅助脚本：{helper}")
        return 2

    node = shutil.which("node") or node_exe
    if not node or not Path(node).exists():
        print(f"[错误] 找不到 node（试过 PATH 与 {node_exe}）。")
        print("       Ogg 解码需要 node + stb-vorbis；若环境有 ffmpeg，也可先转 WAV 再处理。")
        return 2

    stb = node_dir / "node_modules" / "stb-vorbis"
    if not stb.exists():
        print(f"[错误] 未找到 stb-vorbis：{stb}")
        print(f"       请在 {node_dir} 下执行：pnpm add stb-vorbis")
        return 2

    # 第 3 个参数把 node 工程目录传给辅助脚本：node 的 import 按脚本所在目录
    # 解析模块，而 stb-vorbis 装在仓库外，必须显式告知。
    cmd = [node, str(helper), str(raw_dir), str(out_dir), str(node_dir)]
    print(f"[解码] {node} {helper.name}")
    env = dict(os.environ)
    env["DSH_AUDIO_NODE_DIR"] = str(node_dir)
    return subprocess.call(cmd, cwd=str(node_dir), env=env)


def load_f32(path: Path) -> tuple[np.ndarray, int]:
    meta = json.loads(path.with_suffix(META_SUFFIX).read_text(encoding="utf-8"))
    data = np.fromfile(path, dtype="<f4")
    return data, int(meta["sampleRate"])


def pick_segments(x: np.ndarray, sr: int, want: int) -> list[tuple[float, float, float, float]]:
    """按平顶长度挑选叫声段，返回 [(t0, t1, 平顶秒, 段秒), ...]。"""
    win = max(1, int(sr * 0.02))
    n = len(x) // win
    if n == 0:
        return []
    rms = np.sqrt(np.mean(x[:n * win].reshape(n, win) ** 2, axis=1))
    peak = float(rms.max())
    if peak <= 1e-6:
        return []

    cands: list[dict] = []
    # 阈值过严会整段漏选，逐级放宽
    for ratio in (0.30, 0.20, 0.12, 0.06, 0.03):
        cands = []
        i = 0
        while i < n:
            if rms[i] > peak * ratio:
                j = i
                while j < n and rms[j] > peak * ratio:
                    j += 1
                seg = rms[i:j]
                cands.append({
                    "i0": i, "i1": j,
                    "dur": (j - i) * 0.02,
                    "plateau": int((seg > peak * 0.70).sum()) * 0.02,
                    "peak": float(seg.max()),
                })
                i = j
            else:
                i += 1
        if len(cands) >= want:
            break

    cands.sort(key=lambda c: (c["plateau"], c["dur"]), reverse=True)
    out: list[tuple[float, float, float, float]] = []
    used: list[int] = []
    for c in cands:
        if not (MIN_SEG_S <= c["dur"] <= MAX_SEG_S):
            continue
        if any(abs(c["i0"] - u) < 12 for u in used):
            continue
        t0 = max(0.0, c["i0"] * 0.02 - HEAD_PAD_MS / 1000.0)
        t1 = min(len(x) / sr, c["i1"] * 0.02 + TAIL_PAD_MS / 1000.0)
        out.append((t0, t1, c["plateau"], c["dur"]))
        used.append(c["i0"])
        if len(out) >= want:
            break
    return out


def resample(x: np.ndarray, sr_in: int, sr_out: int) -> np.ndarray:
    if sr_in == sr_out:
        return x.astype(np.float32)
    n_out = max(2, int(round(len(x) * sr_out / sr_in)))
    t_out = np.linspace(0, len(x) - 1, n_out)
    return np.interp(t_out, np.arange(len(x), dtype=np.float64), x).astype(np.float32)


def pitch_shift(x: np.ndarray, semitones: float) -> np.ndarray:
    """重采样变调：升调必缩时（见 19 文档 3.3）。"""
    if semitones == 0:
        return x
    return resample(x, 1000, max(2, int(round(1000 / (2 ** (semitones / 12.0))))))


def finish(x: np.ndarray) -> np.ndarray:
    x = x.astype(np.float32)
    x = x - float(x.mean())                       # 去直流
    pk = float(np.abs(x).max())
    if pk > 1e-6:
        x = x * (TARGET_PEAK / pk)                # 归一化
    f = max(1, int(TARGET_SR * FADE_MS / 1000.0))
    if len(x) > 2 * f:
        x = x.copy()
        x[:f] *= np.linspace(0.0, 1.0, f, dtype=np.float32)
        x[-f:] *= np.linspace(1.0, 0.0, f, dtype=np.float32)
    return x


def write_wav(path: Path, x: np.ndarray) -> dict:
    pcm = (np.clip(x, -1.0, 1.0) * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(TARGET_SR)
        w.writeframes(pcm.tobytes())
    y = pcm.astype(np.float32) / 32767.0
    return {
        "seconds": round(len(y) / TARGET_SR, 4),
        "sample_rate": TARGET_SR,
        "channels": 1,
        "bits": 16,
        "peak": round(float(np.abs(y).max()), 4),
        "rms": round(float(np.sqrt(np.mean(y ** 2))), 4),
        "first_sample": int(pcm[0]),
        "last_sample": int(pcm[-1]),
        "clipped_samples": int((np.abs(pcm.astype(np.int32)) >= 32767).sum()),
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(pcm.tobytes()).hexdigest(),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="外部音效素材加工为工程规范 WAV")
    ap.add_argument("--raw", nargs="+", required=True, help="原始素材文件（Ogg/WAV）")
    ap.add_argument("--out-dir", help="输出目录")
    ap.add_argument("--kind", help="音效类别名，输出 <kind>_<n>.wav")
    ap.add_argument("--semitones", type=float, default=0.0, help="变调半音数（正=升高）")
    ap.add_argument("--per-file", type=int, default=1, help="每个源文件截取几段")
    ap.add_argument("--inspect", action="store_true", help="只预检文件结构，不解码不产出")
    ap.add_argument("--decoded-dir", help="已解码 f32 的目录（跳过解码步骤）")
    ap.add_argument("--node-dir", default=os.environ.get("DSH_AUDIO_NODE_DIR", ""),
                    help="装了 stb-vorbis 的 node 工程目录（仓库外）")
    ap.add_argument("--node-exe", default=shutil.which("node") or "node")
    args = ap.parse_args()

    raws = [Path(p) for p in args.raw]
    missing = [str(p) for p in raws if not p.exists()]
    if missing:
        print("[错误] 文件不存在：" + ", ".join(missing))
        return 2

    print("=== 预检 ===")
    inspections = []
    for p in raws:
        info = inspect(p)
        inspections.append(info)
        flag = "  [多流，需解复用]" if info.get("multiplexed") else ""
        print(f"  {info['file']:<34} {info.get('container','?'):<8} "
              f"流={info.get('streams','-')} 编解码={','.join(info.get('codecs',[])) or '-'}{flag}")
    if args.inspect:
        print("\n提示：" + inspections[0].get("decode_note", ""))
        return 0

    if not args.out_dir or not args.kind:
        print("[错误] 产出模式需要 --out-dir 与 --kind")
        return 2

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # 1) 解码
    if args.decoded_dir:
        decoded = Path(args.decoded_dir)
    else:
        if not args.node_dir:
            print("[错误] 需要 --node-dir（装了 stb-vorbis 的目录），或用 --decoded-dir 提供已解码产物")
            return 2
        decoded = out_dir / "_decoded"
        decoded.mkdir(parents=True, exist_ok=True)
        # 只解码本轮指定的文件：辅助脚本按目录扫描，故先收拢到一个临时目录，
        # 否则会把同目录下无关素材一起解码（白费时间，也容易误用）。
        stage = out_dir / "_raw_stage"
        stage.mkdir(parents=True, exist_ok=True)
        for p in raws:
            target = stage / p.name
            if not target.exists() or target.stat().st_mtime < p.stat().st_mtime:
                shutil.copy2(p, target)
        rc = run_decoder(stage, decoded, Path(args.node_dir), args.node_exe)
        if rc != 0:
            print(f"[错误] 解码失败（退出码 {rc}）")
            return rc

    # 2) 加工
    report: dict = {
        "kind": args.kind,
        "semitones": args.semitones,
        "target_peak": TARGET_PEAK,
        "target_sr": TARGET_SR,
        "inputs": inspections,
        "outputs": {},
    }
    index = 1
    for p in raws:
        f32 = decoded / (p.stem + DECODE_SUFFIX)
        if not f32.exists():
            print(f"  [跳过] 无解码产物 {f32.name}")
            continue
        x, sr = load_f32(f32)
        segs = pick_segments(x, sr, want=args.per_file)
        print(f"\n=== {p.name} ({sr} Hz, {len(x)/sr:.2f}s) 选出 {len(segs)} 段 ===")
        for t0, t1, plateau, dur in segs:
            piece = x[int(t0 * sr):int(t1 * sr)]
            piece = pitch_shift(resample(piece, sr, TARGET_SR), args.semitones)
            piece = finish(piece)
            name = f"{args.kind}_{index}.wav"
            info = write_wav(out_dir / name, piece)
            info.update({"source_file": p.name, "source_t0": round(t0, 3),
                         "source_t1": round(t1, 3), "source_plateau_s": round(plateau, 3)})
            report["outputs"][name] = info
            warn = ""
            if info["clipped_samples"]:
                warn = "  [警告] 有削波"
            if info["peak"] >= 0.76:
                warn = "  [警告] 峰值超上限 0.76"
            print(f"  {name:<20} {info['seconds']:.3f}s 峰值{info['peak']:.3f} "
                  f"RMS{info['rms']:.3f} 削波{info['clipped_samples']}{warn}")
            index += 1

    val = out_dir / f"{args.kind}_validation.json"
    val.write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"\n共 {len(report['outputs'])} 个产出 → {out_dir}")
    print(f"校验报告 → {val}")
    print("\n下一步（见 19 文档第四节）：")
    print("  1. 拷进 game/assets/audio_v3/ 后，确认 .import 的 compress/mode=0")
    print("  2. 加进 combat_audio.gd 的 SOUND_SPECS 与 ALIASES")
    print("  3. 跑 tools/run_demo.ps1 -Test 与 python tools/check_docs.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
