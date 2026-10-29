# 原版整库物品图集 v1

用户要求原版全部任务/物品迁移，本包是通用编译器当前可执行子集的原帧交付；不是全部原物品功能已完成。沿用用户已选择的DNF原资源路线，不新增绘画或音效。

## 规格与依赖

- 工作流：14文档原素材加工路线；适用22文档第六节原生像素例外。
- 正式目录：`game_dnf/assets_local/items_native_v1/`；入口为manifest。编译依赖`game_dnf/data/native_runtime.json`，不改此前items_original_v1/v2/v3。
- 语义：同一原ID的icon/field_image分别映射，重复源帧去重；图标与地面贴图可共享同一图集页，不冒充不同原画。
- 具体尺寸：两页图集各1024×1024；单帧实际宽高逐项记录在manifest的images/size与region，尺寸分布在sizes。大部分28×28，其他帧保留源尺寸。
- 加工：源RGBA原尺寸1:1拷贝，帧间留两像素透明间隙；不重画、不调色、不裁边、不平滑缩放，canvas_offset保留。
- 源路径、NPK、IMG SHA256、帧号、多版本候选与选择、原RGBA SHA256均在manifest；候选优先sprite_包，仍不宣称已证明原客户端加载优先级。
- 原始包字节与源本地化在`game_dnf/assets_local/native_data_v1/`保留，运行工程不依赖本机原客户端。

## 导出与复核

```powershell
python tools/bake_dnf_native_item_atlas.py
python tools/bake_dnf_native_item_atlas.py --check
```

已存在正式manifest时导出器拒绝覆盖；追加/修订须新版本。源图缺失、越界在编译阶段记录为不可执行，不用样板图替代后计为已接入。

运行时以AtlasTexture区域读取，实际背包与地面显示共用导出包。技术复核逐帧比较原RGBA与图集裁区，并校验整页文件哈希。界面文字扫描不证明所有烘焙字形；本批查看两页图集及实际装备/材料/恢复品界面，未将此写成用户审美验收。

完整数量、实机快验、截图与适配边界见[整库迁移报告](../../reports/ws2/2026-10/2026-10-29_原任务物品全量迁移与批量实装.md)。
