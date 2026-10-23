# 赫顿原素材街区任务包

## 1. 身份与需求

| 字段 | 约定 |
|---|---|
| task_id / asset_id | dnf_hendon_native_v1；scene.town.hendon.city/main/auction、npc.pungjin/sinda/gsd等 |
| revision / replaces | r1，新增；不覆盖旧不可变包 |
| 类型 / 路线 | 原场景装配G、原NPC/大立绘A、原UI复用G/H；无AI生图 |
| 风格 / 题材 | 用户已选择原DNF像素路线，按22第六节例外保留源像素；原版街景 |
| owner / integration | ws2制作/接入；其它区从Git与资源锁同步 |
| 生命周期 | 已发布，本区实跑；用户视觉认可与其它区接收分别确认 |

用途为艾尔文↔赫顿三街区实际往返、NPC原脚点/身份、任务引荐与服务入口。沿用用户对原素材、中文、布局的要求，不要求重新选择画风。完整城市/新副本/转职不在本批。

## 2. 依赖与来源

- 共享原库dnf-native-assets-v1-20261022；只读PVF/IMG/ANI，无原文件写回。
- [34联通规格](../../design/34_城镇联通与赫顿首批.md)、现有原皮肤/中文字体、NativeMapLoader与城镇休闲动作。
- 三张源MAP为Hendon_City、(r)Hendon、Hendon_Auction；通用Hendon.map缺失，变体选择显式标E-ADAPT。
- NPC白名单8人；primary为风振/辛达/G.S.D，三张原大立绘分别194×219、184×220、194×242。各PNG实际尺寸/SHA/源容器/帧号均在导出manifest.images逐项登记。
- 复用原素材按用户此前允许提取/项目内使用及私库共享的范围；不声称资源所有权转移，不引入外部图或新音效。
- 工具输入是已验证源库路径与源文件索引，真实读取源字节。无prompt、模型、随机种子或假参考图输入。

## 3. 规格与实际加工

| 类别 | 实际约定 |
|---|---|
| 场景 | City3808、Main2464、Auction2016像素宽；基础地面到480；Main另接11块224×120原扩展地砖到600 |
| 图像 | 原IMG解码RGBA，不缩放、不量化、不AI放大；透明度与原ANI混合字段保留 |
| NPC | 世界形象用对应field animation；坐标/朝向/帧延时来自原MAP/NPC/ANI；原图锚点不按外接框重吸脚底 |
| 大立绘 | npc_dialog_face家族指定原帧；保持原像素，底边贴底部718×165对白板；其余居民按manifest逐项记录 |
| 空间 | screen_y=ground_y+120-z；分层按原MAP；地面、出口、镜头与装饰分别建模，不把出口矩形当碰撞面 |
| 输出 | flow_v1/hendon_v1/manifest.json＋img；schema=dnf_native_map/1、hendon_art_schema=dnf_hendon_art/1 |
| 展示 | 既有800×600逻辑画面→固定1920×1080居中呈现，nearest；放大显示不冒称2K新原画 |

制作配方为tools/build_dnf_hendon_assets.py；完整库制作端可通过tools/run_dnf_loop.ps1 -BuildAssets复现。它逐项记录原MAP/NPC/IMG哈希、原六值出口诊断；非副本缺pathgate_pos按用途显式记为info。

## 4. 预览与验收

本批新增PNG逐帧与源IMG的大小/RGBA字节相同；源NPC脚点/出口组/独立扩展地砖也有工具检查。原像素正确不证明整个目标版的覆盖优先级、随机动态或原始碰撞都已恢复。

组合预览直接消费发布导出包，实机图见[本轮记录](../../reports/ws2/2026-10/2026-10-23_赫顿街区任务与城镇联通.md)。用户尚未对本批逐场景作视觉验收；不能用回归通过代替认可。

## 5. 发布与接入

交付为[不可变v12包](https://github.com/mkkzzz/dnflike-assets/releases/tag/dnf-loop-v12-hendon-20261023)；锁为game_dnf/flow_store.json，源配方/图查询工具/设计与证据入口在Git。各区不需要完整源库即可运行。

- 本区已接入：原三街区、NPC/大立绘、共享房间返回路由与任务；技术与真实渲染检查见本轮记录。
- 其它区同步/验收由接收区确认，当前不代勾。
- 原版同条件画面、复杂碰撞、其它城市/服务待后续；新版本继续保留语义ID与原源指纹。

## 6. 复盘

主街的下出口位于原基础480像素地面下，必须读取extended tile并配合纵向镜头，不能仅扩大走区造成踩黑底。赛丽亚房间要保存入口所属街区；角色演员/姓名节点重挂载、过渡输入锁、按键松开重启和安全落点应作为所有后续城镇的共同契约。
