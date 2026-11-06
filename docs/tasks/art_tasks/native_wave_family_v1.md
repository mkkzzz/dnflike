# 冰刃与爆炎原生施放接入 v1

| 项目 | 规格 |
|---|---|
| task_id | native_wave_family_v1 |
| 范围 | 冰刃/爆炎身体与双武器wave动作、专用施放特效、原生等待/恢复相位；普通冰刃连续冰柱、等级时序、尺寸和销毁 |
| 授权 / 风格 | 用户要求按指定原目录复刻；沿用22第六节原生像素例外，不重绘、不放大 |
| 来源 | 指定客户端内嵌PE、只读library_v1 PVF/IMG；路径/哈希随combat manifest与取证报告登记 |
| 原始规格 | IceWave施放7帧×50ms，锚点[-43,-106]；FireWaveBig-Sword-effect施放8帧×50ms，锚点[-37,-216]；均含原空白首帧，LINEARDODGE |
| 身体 / 武器 | 复用wave身体原9帧及weapon_appearance_v2双层按身体帧同步；不生成新武器图 |
| 生命周期 | FX在原身体帧1挂接，以同一施放时钟推进，替换/结束清理；帧4生成攻击对象 |
| 未完成 | 冰刃碎冰粒子/异常等级修正/特殊地形与权限、EX控制器、爆炎前后层/子对象/独立伤害、爆炎FX武器尺寸、声音和完整取消规则 |
| 状态 | 施放相位和普通冰刃核心冰柱链已实装；整招一致性仍在返修 |

本轮新PNG用独立语义键进入既有combat目录，保留已有PNG不覆盖。原图、裁切偏移、混合、帧时序共用正式导出包。实际绘制通过独立隐藏桌面，不能当作原客户端录像或用户手感验收。

复现：运行技能构建器、战斗资产构建器，再运行技能专项与正式流程。对应入口：

```powershell
python tools/build_dnf_skill_runtime.py
python tools/build_dnf_combat_assets.py
python tools/capture_dnf_native_wave.py --skill icewave --output temp/full_restore/icewave_frames
python tools/capture_dnf_native_wave.py --skill firewave --output temp/full_restore/firewave_frames
```

取证与结果见[波动状态报告](../../reports/ws2/2026-11/2026-11-06_原客户端字符串解码与波动状态取证.md)。未完成项必须保留到各自原生控制器取证和实装后再关闭。

新导出图集尺寸：IceWave施放2048×128、FireWaveBig刀光2048×203、IceWave1对象2048×122；仅按源IMG像素打包裁切，不放大。刀光附着点沿面向偏移59像素，由原附着/绘制调用链确认，跟随和左右镜像使用相同偏移。

实绘证据：[冰刃出波帧](../../screenshots/native_wave_family_v1/ice_right_300.png)、[冰刃左向](../../screenshots/native_wave_family_v1/ice_left_350.png)、[爆炎出波帧](../../screenshots/native_wave_family_v1/fire_right_400.png)。每招左右各9个时间切片；图片来自本工程，不是原客户端。这些先前截图只用于施放相位；冰柱链新增证据见下，爆炎子对象仍未完成。

普通冰柱链新增5份原图集：IceWave2为2048×92，3为2048×123，4为2048×64，5为2048×98，6为2048×119。原生像素打包，不重绘/放大；每份3个原IMG帧加1个空白尾帧。运行时原对象倍率1.5+序号×0.075与ANI自身0.5相乘，同时作用图像和攻击盒。对象固定位置，100ms逐根生成，一级8根，单根380ms结束；图像与碰撞按同一改写时序采样，共享图集不被改写。

新增正式包实绘：[右向冰柱链](../../screenshots/native_wave_family_v1/ice_chain_right_600.png)、[左向冰柱链](../../screenshots/native_wave_family_v1/ice_chain_left_600.png)。人物夹具(350,300)，每1ms推进、150..1380ms左右各9个切片；截图为出招后600ms。完整代码地址、来源哈希、测试与剩余缺口仍统一见上文取证报告。不能以本批通过替代碎冰/EX/声音和用户视觉验收。
