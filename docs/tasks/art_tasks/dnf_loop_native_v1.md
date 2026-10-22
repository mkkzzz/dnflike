# 原生素材循环界面 v1

## 身份与范围

| 字段 | 内容 |
|---|---|
| task_id / revision | dnf_loop_native_v1 / 02；中文文字修订，保留独立战斗入口 |
| asset_id | scene.town.elvengard、actor.npc.linus、actor.npc.danjin、ui.loop.hud/inventory/shop/quest/departure/result |
| asset_type / workflow | 原资源只读提取、原UI组件拼装；14文档H/F路线，不调用生图 |
| style_profile / theme_pack | 原版DNF像素资源；用户本轮明确要求使用原图，禁用临时色块 |
| owner / integration_owner | ws2；其它区自行接收，不代填其状态 |
| lifecycle | 已发布；本区已跑通，画面与原版一致性待用户验收 |
| gameplay_purpose | 走动城镇、NPC委托/购买、背包/装备、出征、胜负结算、回城与成长 |

本轮沿用用户已指定的原素材路线，不生成或补画新人物。原图复用不等于完整还原原版布局、规则和数值。

## 来源与依赖

| 依赖 | 用途 | 变更影响 |
|---|---|---|
| [asset_store.json](../../../game_dnf/asset_store.json) | 原始IMG/ANI/PVF、索引与现有玩家动作/战斗运行包 | 构建器校验源IMG/字体SHA256；换版须重导出和复验 |
| [T2导出器](../../../tools/export_dnf_map.py)与原地图加载器 | 复用MAP/TIL/ANI解释与排序、卷轴 | 影响城镇层级/锚点；解释仍为E-INFER |
| [flow_store.json](../../../game_dnf/flow_store.json) | 本轮原图导出包、独立安装戳及实机证据锁 | 新版本另发不可变Release，不覆盖已发布字节 |
| [分工契约](../../design/28_工作区分工与原版资料共享.md) | 战斗归ws1，循环归ws2 | 保留独立入口和临时桥；后续切F0 API时复验整流程 |

实际读取共享库，未向图像生成模型传参考图；不存在prompt、模型种子或AI透明底能力声明。
原素材来自用户提供的本地归档，仅按项目已授权范围在既有私库共享，不声明取得原作所有权。

## 像素、布局与动画规格

| 对象 | 来源及规格 | 实装方式 |
|---|---|---|
| 城镇 | map/elvengard/elvengard.map，7列224×480原TIL，共1568×480 | 640×480逻辑视口水平卷轴；地面y映射沿T2偏移120 |
| NPC | npc/linus.npc、npc/danjin.npc的field animation与MAP原坐标 | 原IMG裁切偏移＋ANI时长，循环采样，不用静态色块代替 |
| HUD | Interface/MainHud.img；底图640×88，红蓝球各56×56 | 血蓝比例真实更新；原球覆盖底图内盘，文字独立 |
| 背包 / 商店 | ItemInventoryWindow.img 291×410 / StackableShopWindow.img 291×380 | 原面板和原格子；点击原图标装备/购买，中文提示 |
| 通用面板 | WindowCommon原边框＋商店无文字纹理40×35裁切 | 1:1组合，NinePatch平铺；没有新画纯色背景 |
| 出征 | Map/CutScene/Lorien.img 800×600，中文难度文字 | 插画仅缩小到264×198；普通难度使用中文文字层 |
| 结算 | 中文结算标题与NewResult/Result.img原S/A/B图 | 显示实际统计与适配评价；评价公式不是原版取证结论 |
| 物品 | 原katana图标、ptn_hplowest.stk指向的药剂图标 | 语义ID固定；两把试炼刀复用同一katana角色外观，尚无逐装备外观 |
| 字体 | 原Fonts/msjh.ttf | 原字体动态中文；原图韩文标题/负重字区先清理，再放中文 |

本入口是640×480原生像素循环，1280×960整数倍窗口；独立战斗验证仍为640×360，不改工程全局配置。
RGBA原像素保留，不插值放大、不量化重绘。PNG每帧记录IMG SHA256、原NPK、帧号、尺寸与偏移。
地面范围、卷轴和层序是适配/推定，未拿原版同条件录像逐项认可。
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
