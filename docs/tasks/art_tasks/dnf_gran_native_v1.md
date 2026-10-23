# dnf_gran_native_v1 原资源任务

按[17模板](../../design/17_美术资源任务模板.md)记录。用户授权继续任务/副本/城镇，沿用原版美术与全中文；不生成新画，不以数值回归代替美术验收。

## 身份与需求

| 字段 | 内容 |
|---|---|
| task_id / revision | dnf_gran_native_v1 / 1 |
| asset_id | town.hendon.forest_gate、town.hendon.alley、npc.shylock、dungeon.mirkwood、dungeon.mirkwood_deep及必需原怪物/投射物 |
| workflow / style | 14原素材只读提取路线；22原生像素例外 |
| owner / integration | ws2制作并接入game_dnf；其它区自行登记接收 |
| scope | 源城镇两区、夏洛克、选图卡、两张原DGN/MAP/门/怪物依赖；不重画，复杂AI另交战斗侧 |
| lifecycle | 实机技术验证与发布交接；用户视觉/原版一致性复核另记 |

## 依赖与来源

- 沿用已授权dnf-native-assets-v1-20261022只读库、既有v12循环/战斗输入；源版权归原权利人，限既有私库共享范围，不扩大受众。
- 新城镇/副本配方tools/build_dnf_gran_assets.py；原怪物内容与图集依赖沿用compile_dnf_content/build_dnf_combat_assets，明确新增MOB白名单。没有使用图像生成器、提示词或第三方图库。
- 源D_Hendon/Hendon_Ura及原NPC9/动画/Interface肖像，原MirkWood/MirkWoodDeep的DGN/MAP/TIL/ANI/OBJ/MOB，原granfloris选图卡。源SHA与容器随manifest/内容包保存。
- downstream：NativeTown/世界配置、原选图、公开战斗API、任务目标、UI怪物名与图标；语义ID不因目录/主题变动而改。

## 画面规格与加工

| 项目 | 实际规格 |
|---|---|
| 森林入口区 / 小巷 | 原896 / 1120像素宽，224×480地砖与原背景/前后层；原地面坐标+120到屏幕，门与可走区独立定义 |
| 副本 | 原各房间896～2240宽源图与224×480地砖；不拉伸补地，保留原通行网格/门锚点 |
| 夏洛克肖像 | 原175×203 RGBA，源Interface/npc_dialog_face.img帧7；底部大立绘对话框 |
| 选图卡 | 原granfloris.img帧0/1，实际尺寸见manifest；在既有800×600逻辑选图窗口呈现 |
| 新怪物图集 | 按原IMG/ANI使用帧裁透明边，以原canvas offset与trim offset还原；不把运行放大冒充2K新画 |
| 混合 / 时钟 | 原normal/add、RGBA与帧delay保留；怪物动作/命中沿用现行战斗时钟契约 |
| 语言 | 实际文字层与源卡片中文核查；按键/HP等现行允许缩写保留 |

堡垒采用原etc motion组成初始外观，组合状态为明确适配；缺失的装备分层和复杂怪物/堡垒脚本在36契约保留，不用替代画或假动画掩盖。

## 验证与交接

- 从同一导出包实际渲染城镇入口、原两副本、夏洛克大立绘与任务交付，原IMG像素/图集trim坐标和源结构由tools/test_dnf_gran.py审计。
- 运行素材与实机证据进入不可变dnf-loop-v13-granfloris-20261023私库Release；精确成员/哈希见flow_store锁与版本表。
- 其它工作区用正式入口同步，不依赖ws2完整库。后续新增/替换需更新版本与依赖并重验对应场景。
- 实机证据/命令、已知适配与人工复核边界见[本批交付](../../reports/ws2/2026-10/2026-10-23_格兰之森首段原副本与夏洛克.md)。
