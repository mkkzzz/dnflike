# 地裂原生动作与武器相位接入 v1

## 身份与需求

| 字段 | 本轮内容 |
|---|---|
| task_id / asset_id | native_wave_v1；actor.player.normalwave、fx.skill.normalwave.slash |
| revision / replaces | v1；替代summon2通用施放姿势和340ms猜测触发 |
| 类型 / 流程 | 原技能动作与配套特效；14流程B/C/D/G |
| 风格 / 题材 | 用户指定“纯60复古”原生像素；沿用22第六节例外 |
| 范围 | 鬼剑士地裂身体9帧、当前155件武器的前后层wave动作、专用挥剑5帧；支持已有换装 |
| 负责人 / 接入 | ws2，按用户全游戏复刻授权执行 |
| 状态 | 已实装、已发布；用户视觉验收尚未完成 |

用户要求按本机原代码、配置、资源复刻；本轮不生成新画风、不重绘或放大原图。来源选择已有明确授权，无新增设计方向需要确认。这里登记的是动作接入，不代表整招或所有技能已还原。

## 依赖与来源

| 原始依赖 | 用途与接入 |
|---|---|
| CHR etc_motions[9]、wave.ani | 原生状态24身体动作；原9帧保留10000ms首帧，运行时根据原代码退出等待 |
| skill/swordman/normalwave.skl | 施放时间与静态恢复时间；等级列保留上批独立百分比/固定/大小修复 |
| common.nut技能20槽0、NormalWaveSlash.ani | 专用挥剑特效，随演员动作时钟与朝向 |
| 原装备EQU/LAY/武器wave.ani与IMG | 前后层保持650/2790顺序、各件原variation；按身体帧号绑定 |
| weapon_appearance_v1 | 已验证PNG与现有24动作复用；v2只追加原wave元数据及基包哈希依赖 |

原文件来自用户提供目录及已登记只读提取库；不主张原创或额外授权范围。逐文件SHA保存在combat/weapon manifests，原生客户端哈希、函数地址与证据等级见[取证报告](../../reports/ws2/2026-11/2026-11-06_原客户端字符串解码与波动状态取证.md)。没有使用AI生图、提示词或随机种子。

## 类别规格与适配

- 原800×600逻辑画面与原像素，最近邻显示；没有2K重绘或插值放大。
- 身体源帧42～50，位置[-232,-333]；武器保留各自ANI、IMG锚点、帧和颜色控制，前后层与身体共同翻转。
- 身体首帧10000ms，武器首帧50ms；v2显式标记按身体帧同步，保留原时间字段，不把短武器动画错误采样到末帧。
- 专用刀光五帧各50ms，位置[-108,-234]，原LINEARDODGE混合；新图集2048×165像素，逐帧裁切偏移由manifest登记。
- 武器前两帧原MONOCHROME颜色控制由独立材质读取，保持透明度，不把武器颜色控制传播给身体。
- 等待采用施放速度；挥剑采用攻击速度；刀光通过动作实例与源时钟定位，停帧时冻结，替换/结束时清理。被动地裂对象独立325ms生命周期。
- UI、图标、头像、场景和命中素材本轮复用；原HADOUKEN声音尚未接入，施放位移和取消条件待继续取证。

## 加工与复现

```powershell
python tools/build_dnf_skill_runtime.py
python tools/build_dnf_combat_assets.py
python tools/build_dnf_weapon_appearance.py --version weapon_appearance_v2 --extend-from game_dnf/assets_local/weapon_appearance_v1 --pose wave
python tools/build_dnf_weapon_appearance.py --version weapon_appearance_v2 --check
python tools/capture_dnf_native_wave.py --output temp/full_restore/wave_frames
```

武器生成命令只用于尚未存在的不可变v2目录，已有包使用check；不删除已有版本以重跑。新刀光PNG进入combat既有资产入口，已有PNG未覆盖。v2引用v1原图，发布与安装必须同时保留依赖基包。正式入口是两个manifest与运行时绑定，不依赖temp里的截图。

## 校验、预览与交接

证据为Godot 4.7.2在Windows私有桌面实际绘制的18个时间切片，左右各0/49/50/100/150/250/300/449/450ms。不是原客户端录像，也不是连续实速手感验收。

- [起手裸动作](../../screenshots/native_wave_v1/wave_right_000.png)
- [右向第3帧出波](../../screenshots/native_wave_v1/wave_right_150.png)
- [左向第3帧出波](../../screenshots/native_wave_v1/wave_left_150.png)

源图、锚点、身体/武器帧、速度组合、一次出波、停帧、恢复及替换清理有自动回归；实际执行结果见取证报告和项目看板。其他区同步后自行确认接收；不代填用户视觉验收。后续继续追角色位移、原声音、取消/特殊职业分支以及其他技能和系统，不将本批批准范围扩展到全部游戏。

## 施放位移规则续修

本资产v1不重绘、不变更源图。后续已按原生SetStaticMoveInfo调用接入角色向前减速，修正此前施放者不动的适配，并按SKL明文限制阿修罗普通攻击强制取消。对象仍在释放锚点独立播放，不跟随人物余势。原位置积分精度和完整取消状态尚未验收，依据见取证报告的后续修正节。

新版规则实绘：[释放帧](../../screenshots/native_wave_motion_v1/wave_right_150.png)、[恢复前](../../screenshots/native_wave_motion_v1/wave_right_449.png)。上方截图保留为动作接入阶段的历史证据，当前规则以此续修为准；原声音仍待接入。


## 扩展规格：冰刃粒子 v1

沿用户指定原版资源授权新增fx.skill.icewave.smoke/shard/star，ws2执行；使用原生像素例外，不重绘、重着色或AI放大。来源为已验证三个PTL、九个ANI及其IMG；保护代码绑定依据见上方取证报告。当前目标为原图导出及普通冰柱初生烟雾接入；碎冰/星光后续触发条件另核，不以导出完成代替运行完成。

| 原ANI主名 | 帧数/原时长ms | 透明裁边后图集规格 |
|---|---|---|
| IceWaveParticleSmoke1 / 2 | 各2 / 1500 | 2048×59 / 2048×27 |
| IceWaveParticle1 / 2 / 3 / 4 | 各17 / 890 | 2048×74 / 2048×60 / 2048×65 / 2048×46 |
| IceWaveParticleStar1 / 2 / 3 | 各2 / 1000 | 2048×11 / 2048×15 / 2048×16 |

保留RGBA、ANI位置/颜色/缩放/旋转/插值/循环及PTL对象列表重复权重。烟雾用原加法混合，星光循环；粒子运动和ANI时钟独立。源PTL/ANI/IMG哈希进入combat manifest，运行只加载三个必要定义，不在每次施放读取完整粒子档案。烟雾生成位置为冰柱原XYZ，图像大小按冰柱DD8缩放，运动半径不随图像一起扩大；新图集沿既有combat入口新增，旧图不覆盖。原随机算术沿既有内核，进程随机初值/时钟与全局质量属于待复原的集成输入。

用户已指定原版方向，本批没有额外画风决策；原图样张、实绘、实际导出命令与验证结果随后回写取证报告。源图与成品沿同一导出包回放；数值通过不代替真人视觉认可。
