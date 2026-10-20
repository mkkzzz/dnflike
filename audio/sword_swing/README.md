# sword_swing —— 招式音（真实录音，CC0）

出招/挥砍音的来源与加工说明。**原始素材不入库**（体积与许可要求都只保留派生结果），
本目录只记录来源、许可与加工参数；派生结果在 `game/assets/audio_v3/<kind>_<1..3>.wav`。

## 来源（均为 CC0，可商用、无需署名，仍记录以便追溯）

| 包 | 作者 | 许可 | 用途 | 链接 |
|---|---|---|---|---|
| Swishes Sound Pack | artisticdude | **CC0** | 普通挥砍（暖气流声，质心 1.4~2.3 kHz） | https://opengameart.org/content/swishes-sound-pack |
| 20 Sword Sound Effects (Attacks and Clashes) | StarNinjas | **CC0**（作者希望署名，非强制） | 技能/重击（金属锐响，质心 12~14 kHz） | https://opengameart.org/content/20-sword-sound-effects-attacks-and-clashes |

- Swishes：13 段真实挥动录音（作者用木棍/衣架在麦克风前挥动录制），44.1 kHz 立体声 WAV
- StarNinjas：10 段剑击，Ogg Vorbis；用 `tools/bake_audio_source_decode.mjs` 解码为 f32

## 为什么换掉原来的合成音

原来的出招音是程序合成 whoosh。负责人实机反馈"不像游戏里的挥剑声"，
要求改成真实录音 —— 这类**质感判断**合成很难做到，真实录制的空气摩擦细节更接近游戏听感。

## 加工（`tools/bake_sword_swings.py`）

1. 按有声段裁剪（1% 峰值门限，前后各留 6 ms）
2. 重采样到 48 kHz 单声道
3. 变速：突刺/空斩升调变短（1.12~1.25），重招降调变长（0.88~0.92）
4. StarNinjas 那包先过 11 kHz 二级低通，压掉金属嘶声
5. 归一化到峰值 0.72、首尾 3 ms 淡出、首尾采样为 0

映射见工具内的 `MAP` 表；每类三个变体，变体之间**同包**以保证音色一致
（早期版本混用两包当变体，结果同一招式的三个变体一个暖一个尖，不成立）。

## 验收

`validation.json` 记录每个文件的时长、峰值、RMS、质心、首尾采样、削波数与哈希。
交付检查同工程规范：48 kHz / 单声道 / 16 bit、峰值 < 0.76、首尾为 0、无削波。
