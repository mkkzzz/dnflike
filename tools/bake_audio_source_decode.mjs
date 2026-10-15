// 音效素材解码辅助脚本，由 tools/bake_audio_source.py 调用。
//
// 职责：把 <rawDir> 下的音频解码成 <outDir>/<name>.f32（单声道 Float32 LE）+ <name>.json（元数据）。
//
// 关键技术（见 docs/design/19_音效生产工作流.md 3.2）：
//   1. Commons 等来源的 Ogg 常是「多流 Ogg」：同时含 Ogg Skeleton(fishead/fisbone/index)
//      与 Vorbis 两条复用流。stb_vorbis 不支持多流，必须先按 serial 解复用。
//   2. 本机常无 ffmpeg，故用 stb-vorbis（纯 WASM、无原生编译）同步解码。
//
// 用法：node bake_audio_source_decode.mjs <rawDir> <outDir>
// 依赖：在脚本所在目录（或其上层）能解析到 stb-vorbis。

import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

// node 的 import 按**脚本所在目录**向上解析模块，不按当前工作目录。
// 而本脚本位于仓库内 tools/，stb-vorbis 通常装在仓库外，因此要显式按
// DSH_AUDIO_NODE_DIR / 第三个参数指向的目录解析，否则必然找不到。
async function loadStb() {
  try {
    return await import('stb-vorbis');
  } catch { /* 继续尝试显式路径 */ }
  const probeDir = process.env.DSH_AUDIO_NODE_DIR || process.argv[4];
  if (!probeDir) return null;
  const candidate = path.join(probeDir, 'node_modules', 'stb-vorbis', 'dist', 'index.js');
  if (!fs.existsSync(candidate)) return null;
  try {
    return await import(pathToFileURL(candidate).href);
  } catch {
    return null;
  }
}

const stb = await loadStb();
if (!stb) {
  console.error('[错误] 无法加载 stb-vorbis。');
  console.error('       方式一：在装了 stb-vorbis 的 node 工程目录下执行本脚本');
  console.error('       方式二：设置环境变量 DSH_AUDIO_NODE_DIR 指向该目录，或用第 3 个参数传入');
  process.exit(2);
}
await stb.StbVorbis.ready;

const [rawDir, outDir] = process.argv.slice(2);
if (!rawDir || !outDir) {
  console.error('用法：node bake_audio_source_decode.mjs <rawDir> <outDir> [nodeProjectDir]');
  process.exit(2);
}
fs.mkdirSync(outDir, { recursive: true });

/** 列出 Ogg 页：[{start, end, serial}] */
function readPages(buf) {
  const pages = [];
  let off = 0;
  while (off + 27 <= buf.length && buf.toString('latin1', off, off + 4) === 'OggS') {
    const segCount = buf[off + 26];
    let payload = 0;
    for (let i = 0; i < segCount; i++) payload += buf[off + 27 + i];
    const end = off + 27 + segCount + payload;
    pages.push({ start: off, end, serial: buf.readUInt32LE(off + 14) });
    off = end;
  }
  return pages;
}

/** 按 serial 抽出单条逻辑流，重建为可独立解码的 Ogg */
function demux(buf, serial) {
  const keep = readPages(buf).filter((p) => p.serial === serial);
  return Buffer.concat(keep.map((p) => buf.subarray(p.start, p.end)));
}

/** 找 Vorbis 流的 serial：其首页 payload 以 0x01 'vorbis' 开头 */
function findVorbisSerial(buf) {
  for (const p of readPages(buf)) {
    const payloadStart = p.start + 27 + buf[p.start + 26];
    const head = buf.toString('latin1', payloadStart, payloadStart + 7);
    if (head.startsWith('\x01vorbis')) return p.serial;
  }
  return null;
}

function decodeWav(buf) {
  // 极简 WAV 解析：只处理 16 bit PCM（素材加工常见形态）
  if (buf.toString('latin1', 0, 4) !== 'RIFF' || buf.toString('latin1', 8, 12) !== 'WAVE') return null;
  let off = 12, fmt = null, data = null;
  while (off + 8 <= buf.length) {
    const id = buf.toString('latin1', off, off + 4);
    const size = buf.readUInt32LE(off + 4);
    const body = off + 8;
    if (id === 'fmt ') {
      fmt = {
        channels: buf.readUInt16LE(body + 2),
        sampleRate: buf.readUInt32LE(body + 4),
        bits: buf.readUInt16LE(body + 14),
      };
    } else if (id === 'data') {
      data = buf.subarray(body, body + size);
    }
    off = body + size + (size % 2);
  }
  if (!fmt || !data || fmt.bits !== 16) return null;
  const frames = Math.floor(data.length / 2 / fmt.channels);
  const channels = [];
  for (let c = 0; c < fmt.channels; c++) channels.push(new Float32Array(frames));
  for (let i = 0; i < frames; i++) {
    for (let c = 0; c < fmt.channels; c++) {
      channels[c][i] = data.readInt16LE((i * fmt.channels + c) * 2) / 32768;
    }
  }
  return { sampleRate: fmt.sampleRate, channels };
}

const files = fs.readdirSync(rawDir).filter((f) => /\.(ogg|oga|wav)$/i.test(f));
if (files.length === 0) {
  console.error('[错误] 目录内没有 .ogg/.oga/.wav：' + rawDir);
  process.exit(2);
}

let ok = 0;
for (const f of files) {
  const src = path.join(rawDir, f);
  const buf = fs.readFileSync(src);
  const base = path.basename(f).replace(/\.[^.]+$/, '');
  try {
    let audio = null;
    let how = '';

    if (buf.toString('latin1', 0, 4) === 'OggS') {
      const vSerial = findVorbisSerial(buf);
      if (vSerial === null) {
        console.log(`  [跳过] ${f}  找不到 Vorbis 流（可能是 Opus/Speex）`);
        continue;
      }
      const pages = readPages(buf);
      const multiplexed = new Set(pages.map((p) => p.serial)).size > 1;
      const single = multiplexed ? demux(buf, vSerial) : buf;
      audio = stb.StbVorbis.decode(new Uint8Array(single));
      how = multiplexed
        ? `多流解复用（serial=${vSerial}，共 ${new Set(pages.map((p) => p.serial)).size} 条流）`
        : '单流直接解码';
    } else {
      audio = decodeWav(buf);
      how = 'WAV 直接解析';
    }

    if (!audio) {
      console.log(`  [跳过] ${f}  不支持的容器/位深`);
      continue;
    }

    const { sampleRate, channels } = audio;
    const frames = channels[0].length;
    // 单声道化
    const mono = new Float32Array(frames);
    for (let i = 0; i < frames; i++) {
      let s = 0;
      for (let c = 0; c < channels.length; c++) s += channels[c][i];
      mono[i] = s / channels.length;
    }

    fs.writeFileSync(path.join(outDir, base + '.f32'), Buffer.from(mono.buffer));
    fs.writeFileSync(
      path.join(outDir, base + '.json'),
      JSON.stringify({ name: f, sampleRate, channels: channels.length, frames }, null, 1),
    );
    console.log(`  [解码] ${f.padEnd(32)} ${sampleRate} Hz ${channels.length}ch `
      + `${(frames / sampleRate).toFixed(2)}s  ${how}`);
    ok++;
  } catch (e) {
    console.log(`  [失败] ${f}  ${e.message}`);
  }
}

console.log(`\n解码完成：成功 ${ok} / 共 ${files.length}，产物在 ${outDir}`);
process.exit(ok > 0 ? 0 : 1);
