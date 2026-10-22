# 原生素材循环界面 v1

## 身份与范围

| 字段 | 内容 |
|---|---|
| task_id / revision | dnf_loop_native_v1 / 05；续修背包/商店格子裁切、32px步距、物品内框和悬停底板 |
| asset_id | scene.town.elvengard、actor.npc.linus、actor.npc.danjin、ui.loop.hud/inventory/shop/quest/departure/result |
| asset_type / workflow | 原资源只读提取、原UI组件拼装；14文档H/F路线，不调用生图 |
| style_profile / theme_pack | 原版DNF像素资源；用户本轮明确要求使用原图，禁用临时色块 |
| owner / integration_owner | ws2；其它区自行接收，不代填其状态 |
| lifecycle | 已发布；首版已被用户退回，本轮定位修正见[格子返修](../../reports/ws2/2026-10/2026-10-22_背包商店格子与图标定位.md)，前轮说明框/大立绘等保持，原版一致性待用户复核 |
| gameplay_purpose | 走动城镇、NPC委托/购买、背包/装备、出征、胜负结算、回城与成长 |

本轮沿用用户已指定的原素材路线，不生成或补画新人物。原图复用不等于完整还原原版布局、规则和数值。

## 来源与依赖

| 依赖 | 用途 | 变更影响 |
|---|---|---|
| [asset_store.json](../../../game_dnf/asset_store.json) | 原始IMG/ANI/PVF、索引与现有玩家动作/战斗运行包 | 构建器校验源IMG/字体SHA256；换版须重导出和复验 |
| [T2导出器](../../../tools/export_dnf_map.py)与原地图加载器 | 复用MAP/TIL/ANI解释与排序、卷轴 | 影响城镇层级/锚点；解释仍为E-INFER |
| [flow_store.json](../../../game_dnf/flow_store.json) | 本轮原图导出包、独立安装戳及实机证据锁 | 新版本另发不可变Release，不覆盖已发布字节 |
| [分工契约](../../design/28_工作区分工与原版资料共享.md) | 战斗归ws1，循环归ws2 | 保留独立入口；UI返修已与ws1公开API接入合并、删除旧桥并复验整流程 |

实际读取共享库，未向图像生成模型传参考图；不存在prompt、模型种子或AI透明底能力声明。
原素材来自用户提供的本地归档，仅按项目已授权范围在既有私库共享，不声明取得原作所有权。

## 像素、布局与动画规格

| 对象 | 来源及规格 | 实装方式 |
|---|---|---|
| 城镇 | map/elvengard/elvengard.map，7列224×480原TIL，共1568×480 | 800×600循环视口水平卷轴，场景整体下移28，地面y映射沿T2偏移120；末48px草地1:1延续至HUD透明区 |
| NPC | npc/linus.npc、npc/danjin.npc的field animation与MAP原坐标 | 原IMG裁切偏移＋ANI时长，循环采样，不用静态色块代替 |
| HUD | Interface2/HUD/HUD.img 800×92，血蓝56×56；ui/hud/hud.ui控件坐标 | 移除常驻说明/六个大按钮；原菜单图标、两侧快捷槽、真实血蓝/经验/冷却；技能ASDFGH，ZXC不显示、药剂1 |
| 底部对白 | Interface2/npc_dialogue_ui.img 718×165；npc_dialog_face.img第0帧186×226 | 原尺寸底部板，林纳斯透明上半身大立绘浮在左侧；中文对白/任务/商店入口 |
| 任务列表 | newstyle/windows/quest.img、quest/reformquestwindow.img、WindowCommon组件 | 分类、左列表/右详情、目标/奖励与接取/交付；外窗位置仍为E-INFER |
| 背包 | newstyle/windows/inventory/fuck_1.img 313×578（含透明留边），源图自带中文页签 | 删48px空白后保持组件1:1，避开HUD；八列四行，源网格起点(16,174)/步距32/图标28内缩2；分类/实际负重/金币与原说明框 |
| 商店 | 原WindowCommon边框/纹理、StackableShopWindow原滚动组件及原商品格 | 七列六行32px网格，与背包同源行带/2px收边，图标28居中；购买/悬停价格；整体拼装为E-INFER |
| 说明板/物品详情 | 普通窗WindowCommon＋商店纹理40×35；物品专用Global九片24×25 | 外窗连续边缘；详情细金边半透明黑底，不混用组件家族 |
| 出征 | WorldMap/granfloris.img 800×600、SelectDungeonSlot/granfloris原图卡、SelectDungeon02_cn中文组件 | 全屏羊皮地图、卡片选中框、普通级、原冒险按钮；未开放卡片明示不可进入 |
| 结算 | Interface2/reward_ver2.0/reward_ver2.img原底图800×600、卡牌153×97与确认按钮；NewResult原评级 | 实际统计、四张卡片/鼠标翻开/确认回城；奖励仅展示已结算收益，不冒充原版随机翻牌规则 |
| 物品 | 原katana图标、ptn_hplowest.stk指向的药剂图标 | 语义ID固定；两把试炼刀复用同一katana角色外观，尚无逐装备外观 |
| 字体 | 原Fonts/msjh.ttf | 原字体动态中文；原图韩文标题/负重字区先清理，再放中文 |

本入口逻辑800×600、CANVAS_ITEMS按窗口分辨率绘制文字；场景原像素nearest/整数缩放。菜单选800×600或1600×1200，默认按可用屏幕选择；独立战斗全局配置不改。
RGBA原像素保留，不插值放大、不量化重绘。PNG每帧记录IMG SHA256、原NPK、帧号、尺寸与偏移。
地面范围、卷轴、外窗锚点与层序是适配/推定，未拿原版同条件录像逐项认可。原包攻略可验证HUD/背包/选图家族，不能替代实际生效客户端的逐状态对照。
用户后续明确禁止游戏中出现韩文；[语言规范](../../design/15_统一风格与题材规范.md#游戏语言所有工作区)覆盖贴图内文字。背包字区与招牌用原无字材质做表现层修补，不修改存档、物品ID、PNG源字节或动作时钟。

## 可复现构建与预览

```powershell
# 直接拉小运行包后开游戏；无需完整原版安装
tools/run_dnf_loop.ps1
# 有完整共享库时可从来源重建
python tools/build_dnf_flow_assets.py
# 同一个入口做真实渲染与连续流程检查
tools/run_dnf_loop.ps1 -Test -Capture
# 取得共享实机证据到工程外缓存
python tools/sync_dnf_flow.py --evidence
```

导出为game_dnf/assets_local/flow_v1/manifest.json；正式字节在锁定的资源Release，临时本机截图在temp/loop_review。
各区通过同步命令获取同一份导出和证据，不把本机temp当唯一交付。
源帧逐像素核对、实际画面修正与验收边界见[实装记录](../../reports/ws2/2026-10/2026-10-22_原生素材城镇循环首轮实装.md)。

## 验收与后续

- 技术：源像素/字体、原图加载、真实鼠标按钮、正常战斗输入、跨Run装备成长、保存恢复和幂等结算已验证；当前项数见[看板](../../project/01_进度看板.md)。
- 组合：城镇/NPC/任务/商店/背包/出征/实际战斗/结果/奖励装备/回城均保存实际帧缓冲。
- 实机视觉：已自行查看并修复球体遮挡、插画溢出、弹窗文字底纹和提示遮挡；用户尚未验收。
- 原版运行版本、城镇碰撞/层序、原版任务对白和逐装备外观继续补证；新增内容仍须中文检查，不将技术通过写成原版水准已达成。
