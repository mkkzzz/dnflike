# goblin_hurt 素材包

本目录记录 `game/assets/audio_v3/goblin_hurt_*.wav` 的来源与派生过程。

## 为什么单独记录

工程其余音频（27 类 × 3 变体 = 81 个 WAV）都是**原创离线程序化拟音**，由 `tools/bake_combat_audio.py` 生成，出处声明见 [../combat_v3/source_spec.json](../combat_v3/source_spec.json)。

**`goblin_hurt` 是工程中唯一使用外部素材的音频**，因此单独记录来源、许可与派生链，避免出处声明与实际不符。

## 来源

| 文件 | 许可 | 作者 | 页面 |
|---|---|---|---|
| `Monster growls.ogg` | **Public domain** | stilgar | [Commons](https://commons.wikimedia.org/wiki/File:Monster_growls.ogg) |
| `Monster growls 2.ogg` | **Public domain** | stilgar | [Commons](https://commons.wikimedia.org/wiki/File:Monster_growls_2.ogg) |

两者均为**公有领域**，可自由使用、修改与再分发，**无需署名**。选择公有领域而非 CC BY，是为了不给项目留下署名义务。

原始文件的 SHA256、直链与完整元数据见 [source.json](source.json)。

## 派生链

1. 源文件是**多流 Ogg**：同时含 Ogg Skeleton（`fishead` / `fisbone` / `index`）与 Vorbis 两条复用流。`stb_vorbis` 不支持多流，故先**按 serial 解复用**出 Vorbis 单流。
2. 用 `stb-vorbis`（WASM，Apache-2.0，纯 JS 无原生依赖）同步解码为 44100 Hz 单声道 f32。
3. 用 20 ms 窗 RMS 找叫声段，按平顶长度与时长排序选取，首尾留 8 ms / 45 ms 余量截取，避免切进发声中间。
4. 重采样到 48000 Hz。
5. **变调：升 16 个半音（倍率 2.5198）**。变调用重采样实现，因此时长同比缩短——这是物理必然，不是缺陷。
6. 去直流、归一化到峰值 0.72（低于工程上限 0.76）、首尾各 3 ms 渐变。
7. 输出 48 kHz / 单声道 / 16 bit PCM。

## 三个变体

| 输出 | 时长 | 来源段 | 说明 |
|---|---|---|---|
| `goblin_hurt_1.wav` | 0.426 s | `Monster_growls_2__0` | 负责人试听选定（原 B 段） |
| `goblin_hurt_2.wav` | 0.362 s | `Monster_growls__2` | 同批素材，音高一致、音色有区分 |
| `goblin_hurt_3.wav` | 0.339 s | `Monster_growls_2__4` | 同上 |

三个变体共同入库，供运行时随机选择，避免连击时产生机械重复感。

每个文件的时长、峰值、RMS、首尾采样、削波数与 SHA256 见 [validation.json](validation.json)。

## 运行时

| 项 | 值 |
|---|---|
| 混音基准 | **−12 dB**（低于合成撞击的 −4.5~−6 dB） |
| 节流 | **320 ms**（叫声长达 0.34~0.43 s，更短的节流会让连击糊成一片） |
| 强度 | 重击 1.10 / 轻击 0.90 |
| 触发点 | `battle_fx.gd` `on_hit()`，位于 V6 与 legacy 两条分支**之前** |
| 与撞击拟音的关系 | **分层并存，不替换**（A 方案）：保留 `light`/`heavy`/`launch`/`metal_hit` 的打击实感，再叠一层生物叫声 |

### 混音余量的代价（实测）

`combat_audio.gd` 有 0.86 的硬预算，超出时所有活跃声道按比例降低增益。加入本层后：

| 场景 | 峰值和 | 余量系数 | 影响 |
|---|---|---|---|
| 轻击 | 0.57 | 1.00 | 无 |
| 重击 | 0.64 | 1.00 | 无 |
| 上挑（挥砍+launch+叫） | 0.93 | 0.92 | 轻微压低 8% |
| 三段普攻命中 | 1.02 | **0.82** | 所有声道压低约 18% |

这是既有混音架构的必然结果，不是本层引入的缺陷。

## 复现

派生脚本不在仓库内（属一次性素材加工）。原始 Ogg 与解码产物保存在仓库外的 `D:/dnflike_local/audio_src/`。若需重做，按上面「派生链」步骤，或直接使用已入库的 WAV（SHA256 见 validation.json 可校验完整性）。

## 未采用的候选

Commons 另有以下可用素材，因效用或授权原因未采用：

| 文件 | 许可 | 未采用原因 |
|---|---|---|
| `439280 schots angry-tiger.wav` | CC0 | 虎吼，生物感与哥布林不符 |
| `Swipe / Stab Damage (Monster)` ×3 | CC BY 4.0 | 需署名；且已有公有领域素材够用 |
| `Beast laughter.ogg` | Public domain | 源峰值仅 0.05~0.50，归一化到 0.72 会把底噪一起放大 |
| `Male pain grunts.ogg` / `Grunt of pain.ogg` | Public domain | 人声痛呼，非怪物 |
