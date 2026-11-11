# ws1 状态

> 只由 ws1 修改。开工、收工或切换任务时更新，最近完成保留 5 条。

| 字段 | 内容 |
|---|---|
| 使用者 | rainmk |
| 状态 | 正在做 |
| 正在做 | 原版全部副本世界内容线：已建立 54 条非 legacy 正式路由（17 个可见固定副本、隐藏阿登、隐藏神殿周边、树精丛林、炼狱、极昼、天帷禁地、GBL女神殿、树精繁殖地、第二脊椎、第一脊椎、蜘蛛洞穴、暗精灵墓地、暗黑城入口、熔岩穴、山脊、斯卡萨之巢、根特周边、根特东门、比尔马克帝国试验场、痛苦之村列瑟芬、诺伊佩拉、迷乱之村哈穆林、悲鸣洞穴、冰心少年、利库天井、白色废墟、布万加、冰雪宫殿、GBL教阿拉德分部、GBL教研究所、GBL教孵化场、堕落的盗贼、月光酒馆、王的遗迹、绿都格罗兹尼、热血八番街与浅栖之地原生迷宫），闭合 17 个可见副本 107 房阵容、63 个怪种攻击路径、18 个领主真实伤害入口和 896/152 个可破坏物/伤害陷阱实例；60 级 DGN 为 53/97 runtime、44 parsed，怪物 runtime 312，继续逐副本补齐来源、特殊 AI、投放、任务、结算和正式入口 |
| 产出位置 | `game_dnf/core/`、`game_dnf/content/api/`、`game_dnf/combat/`（action/hit/resolve/ai/data/api/fields）、`game_dnf/quests/`、`game_dnf/data/`（含 `campaign_1_16.json`、60 级基线 JSON）、`game_dnf/view/`、`game_dnf/ui/combat/`、`game_dnf/ui/flow/`、`game_dnf/town/`、`game_dnf/debug/`、`game_dnf/tests/`（含 `act8/`）、`tools/`、`docs/design/49_单机60级一致基线.md`、`docs/reports/ws1/2026-10/`、`docs/reports/ws1/2026-11/` |

## 最近完成

- 2026-11-11 完成[迷乱之村哈穆林原生迷宫与可破坏雕像](../../reports/ws1/2026-11/2026-11-11_迷乱之村哈穆林原生迷宫与可破坏雕像.md)：把 `villageoftemptation.dgn` 接入隐藏正式 `native_maze` 路线，闭合 5×5 源网格、16 个连通房、3 个 boss 候选、9 个怪种、146 只非 dummy 源怪、295 个对象、27 个可破坏物、16 个开箱载荷和两首原曲。6 个新 bank、46 个动作槽和 group 0 的 1089/1090/3217 投放接入；3 张 fake-boss `[dummy]` MAP、EventMonster 61728、封印门 60019、trap 2211 与任务/结算保持显式边界。专项 158、全部原生迷宫 38 文件 3,695、地图 Python 37、世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 53 runtime、44 parsed，怪物 runtime 312。

- 2026-11-11 完成[悲鸣洞穴原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-11_悲鸣洞穴原生迷宫与对象载荷.md)：把 `screamingcave.dgn` 的 hell 基础 block 0 接入隐藏正式 `native_maze` 路线，闭合 6×1 普通路线、6 个固定房、10 个怪种、58 只路线怪、29 个对象和两首原曲。10 个 bank、53 个多槽动作与 6 组源 AI 规则接入；两套 quest 4358/4378、MAP 6807～6809、AI character、item 3222、trap/dummy 生命周期和源 basis 61→60 E-ADAPT 保持显式边界。专项 149、全部原生迷宫 37 文件 3,537、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 52 runtime、45 parsed，怪物 runtime 306。

- 2026-11-11 完成[诺伊佩拉原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-11_诺伊佩拉原生迷宫与对象载荷.md)：把 `noirpera.dgn` 的 hell 基础布局接入隐藏正式 `native_maze` 路线，闭合 5×2 源网格、7 个连通房、7 条固定 MAP、11 个怪种、47 只全部源怪和两首原曲。11 个 bank、44 个动作槽与 9 组源 AI 规则接入；28 个无 ATK 槽、异次元裂缝召唤、狄瑞吉幻影阶段、三祭司施法、NPC/任务/结算保持显式缺口。专项 110、全部原生迷宫 36 文件 3,388、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 51 runtime、46 parsed，怪物 runtime 294。

- 2026-11-11 完成[痛苦之村列瑟芬原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-11_痛苦之村列瑟芬原生迷宫与对象载荷.md)：把 `leshphon.dgn` 的 hell 基础布局接入隐藏正式 `native_maze` 路线，闭合 2×3 源网格、6 个固定房、7 个怪种、28 只全部源怪、113 个 action-object 和两首原曲。7 个 bank、30 个动作槽与 5 个源 AI 规则接入；11 个无 ATK 槽、proc/come-in/etc action、狄瑞吉 HP 阈值霸体、雨层、碰撞、事件怪位置与 boss NPC 保持显式缺口。专项 108、全部原生迷宫 35 文件 3,278、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 50 runtime、47 parsed，怪物 runtime 保持 283 并登记目标清单差异。

- 2026-11-11 完成[比尔马克帝国试验场原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-11_比尔马克帝国试验场原生迷宫与对象载荷.md)：把 `vilmark.dgn` 的 hell 基础布局接入隐藏正式 `native_maze` 路线，闭合 6×1 源网格、6 个连通房、6 条固定 MAP、6 个怪种、37 只全部源怪、209 个全部源对象和两首原曲。6 个 bank、25 个动作槽与 `bloodlugaru 0,1` 源选招规则接入；189 个可破坏候选中 77 个可执行，19 条源箱行、26 个已知 jar 对象和 11 个未解 trap ID 已按证据分档。专项 94、全部原生迷宫 34 文件 3,170、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 49 runtime、48 parsed，怪物 runtime 283。

- 2026-11-11 完成[根特周边原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-11_根特周边原生迷宫与对象载荷.md)：把 `outergent.dgn` 的 hell 基础布局接入隐藏正式 `native_maze` 路线，闭合 5×5 源网格、15 个连通房、双 boss 分支、6 个怪种、149 只全部源怪、186 个全部源对象和两首原曲。6 个新 bank、22 个动作槽与源 AI 优先级接入；西/东 boss run 分别 131 怪与 160/153 对象，未选中 boss 格切换为 boss_not 普通图。73/72 个灯柱/APC/果袋候选与 43/37 个 drum tongue 保持显式缺口。专项 112、全部原生迷宫 32 文件 2,934、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 47 runtime、50 parsed，怪物 runtime 272。

- 2026-11-11 完成[斯卡萨之巢原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-11_斯卡萨之巢原生迷宫与对象载荷.md)：把 `scasalair.dgn` 的 hell 基础布局接入隐藏正式 `native_maze` 路线，闭合 3×4 源网格、10 个连通房、12 张候选 MAP、双起点、76 只基础候选怪/8 种、Scasa 领主、273 个基础对象和两首原曲。8 个新 bank、64 个动作槽与源 AI 优先级接入；107 个 crystal/tree/tomb 可执行，27 个 scasa egg、item pocket trap 2211 与 blizzard factory 保持显式缺口。专项 135、全部原生迷宫 31 文件 2,822、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 46 runtime、51 parsed，怪物 runtime 266。

- 2026-11-11 完成[暗黑城入口原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-11_暗黑城入口原生迷宫与对象载荷.md)：把 `underfoot.dgn` 的 hell 基础 block 接入隐藏正式 `native_maze` 路线，闭合 6×3 源网格、15 个连通房、15 张固定 MAP、120 只怪/7 种、Headless Knight 领主、222 个对象和两首原曲。7 个新 bank、18 个多招槽与 2 条单招 base attack 接入；3 个 coffin 与 10 个 sphere 可执行，20 个 brazier/60 个 torch 和 27 个 trap/行为对象保持显式缺口。专项 93、全部原生迷宫 30 文件 2,687、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 45 runtime、52 parsed，怪物 runtime 260。

- 2026-11-11 完成[热血八番街原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-11_热血八番街原生迷宫与对象载荷.md)：把 `odesa.dgn` 的 hell 基础 block 4 接入隐藏正式 `native_maze` 路线，闭合 7×4 源网格、13 个连通房、13 张固定 MAP、114 只路线怪/8 种、RocketMan 领主、43 个对象和两首原曲。修正多 block 选择为“普通图优先、无普通图时只接受无任务/无逃脱的 hell 基础图”；全库 325 个可解析 DGN 扫描后只改变奥德萨与 `genteastgate`。8 个新 bank、42 个动作槽和源 AI 优先级接入；29 个 trashcan/odesabox 保持 breakable source 缺口，新增 `items_original_v11` 聚合 37 个定义/55 张原帧和 item 3230。专项 110、全部原生迷宫 29 文件 2,594、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 44 runtime、53 parsed，怪物 runtime 253。

- 2026-11-11 完成[绿都格罗兹尼原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-11_绿都格罗兹尼原生迷宫与对象载荷.md)：从 `grozni.dgn` 10 套 block 中选中唯一无 quest/escape/hell 的 block 8，接入隐藏正式 `native_maze` 路线，闭合 8×3 源网格、15 个连通房、13 张唯一 MAP、129 只普通路线怪/10 种、67 个对象和两首原曲。10 个新怪 bank、Cypher 6 招与 `4,5,0` AI 优先级接入；30 个 stone/odesabox/cover 候选保持显式契约缺口。专项 90、全部原生迷宫 28 文件 2,484、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 43 runtime、54 parsed，怪物 runtime 245。

- 2026-11-11 完成[王的遗迹原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-11_王的遗迹原生迷宫与对象载荷.md)：把 `kingsruins.dgn` 接入隐藏正式 `native_maze` 路线，闭合 6×1 源网格、6 个连通格、6 条固定 MAP specification、18 个共享-mask placement、6 只/6 种怪、31 个可执行可破坏物和两首原曲。五守卫与锤王分别编译 2/2/2/2/3/5 个运行招式；通用箱组改按源 group 0/1/2 分派，新增 `items_original_v10` 聚合 21 个物品定义与 29 张唯一原帧。专项 72、全部原生迷宫 27 文件 2,394、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 42 runtime、55 parsed，怪物 runtime 235。

- 2026-11-11 完成[月光酒馆原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-11_月光酒馆原生迷宫与对象载荷.md)：把 `aganzo.dgn` 接入隐藏正式 `native_maze` 路线，新增通用 6 个 maze block 保留与 selected block 选择；从 quest 4102～4106 和最终 hell 中只选 block 4 普通 5×4 图，闭合 10 连通格、7 条 specification、21 个 placement、62 只普通路线怪/5 种、106 个普通路线对象和两首同源 cue。5 个新 bank 接入；135 个 chair/siktak/namutong 家具仅登记来源契约缺口，2211 不执行。专项 64、全部原生迷宫 26 文件 2,322、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 41 runtime、56 parsed，怪物 runtime 229。

- 2026-11-11 完成[堕落的盗贼原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-11_堕落的盗贼原生迷宫与对象载荷.md)：把 `astraythief.dgn` 接入隐藏正式 `native_maze` 路线，闭合 5×4 源网格、12 连通格、7 条普通 MAP specification、两个首领格、19 个 placement、141 只/9 种怪、118 个对象与两首原曲。两个合法起始变体、`q6220` 无布局剧情图、9 个可破坏物、5 个狗柱 trap、`act6box` 2211 gap 与 `myojin` 双 Boss 行均已登记。新增 `items_original_v9`，聚合 18 个箱掉物品定义与 26 张唯一原帧；3 个普通偶像 draw 与 1 个剧情 podium draw 走 group 0，合法空抽约 70%。专项 89、全部原生迷宫 2,258、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 40 runtime、57 parsed，怪物 runtime 224。

- 2026-11-11 完成[GBL教孵化场原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-11_GBL教孵化场原生迷宫与对象载荷.md)：把 `gbl_hatchery.dgn` 接入隐藏正式 `native_maze` 路线，闭合 4×4 源网格、13 连通格、11 条普通 MAP specification、19 个 placement、114 只/7 种怪、150 个对象与两首原曲。7 个新 bank 接入，57 个可破坏物可执行，两个普通特殊罐的已验证 `2210` payload 改走 `prepare_candidate()` 后实际进入运行 prop。8 个 altar2/altar3、27 个 `gblhelipad`、56 个倒地障碍、`bossaltar`、hell、事件怪 62502、封印门 60042、任务/城镇/奖励与用户验收保留 gap。专项 111、全部原生迷宫 2,169、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 39 runtime、58 parsed，怪物 runtime 215。

- 2026-11-11 完成[GBL教研究所原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-11_GBL教研究所原生迷宫与对象载荷.md)：把 `gbl_laboratory.dgn` 接入隐藏正式 `native_maze` 路线，闭合 4×4 源网格、12 连通格、12 张源 MAP、20 个 placement、94 只/6 种怪、778 个对象与两首原曲。普通局 33 个可破坏物可执行，6 个新怪 bank 与 hydracle 8 槽动作表接入。`jilef` group 1 的 5 个物品已编译并进入 `items_original_v8`，但 special/action/visual 生命周期仍是缺口，不能宣称实际开箱发奖。413 个 trap/行为对象、243 个可破坏物候选、hell、事件怪 62502、封印门 60041、任务/城镇/奖励与用户验收保留 gap。专项 55、全部原生迷宫 2,058、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 38 runtime、59 parsed，怪物 runtime 208。

- 2026-11-11 完成[GBL教阿拉德分部原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-11_GBL教阿拉德分部原生迷宫与对象载荷.md)：把 `gbl_branchofarad.dgn` 接入隐藏正式 `native_maze` 路线，闭合 4×4 源网格、13 连通格、17 张源 MAP、27 个 placement、104 只/6 种怪、178 个对象与两首原曲。普通局 96 个可破坏物可执行，伊莎杜拉 13 槽动作表接入；quest-only `ladyzealot_characterteam` 与 `isadora2` 保持编译但隔离。quest 3802/3803、hell、事件怪 62502、封印门 60040、54 个 action-object、trap 2000/2100 保留 raw/gap。专项 57、全部原生迷宫 2,003、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 37 runtime、60 parsed，怪物 runtime 202。

- 2026-11-10 完成[冰雪宫殿原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-10_冰雪宫殿原生迷宫与对象载荷.md)：把 `icepalace.dgn` 接入隐藏正式 `native_maze` 路线，闭合 3×3 全连通网格、9 张源 MAP、11 个 placement、53 只/12 种怪、176 个对象与两首原曲。女王洛丝按源 4 槽动作表接入，26 水晶与 24 冻结树共 50 个可执行可破坏物；新增 8 个运行 bank。事件怪 61728、封印门 60029、hell、AICharacter `crux.aic`、女王 `proc.act` 召唤莫哈妮、54 个 action/special 可破坏候选与 9 个 trap 保留 raw/gap。专项 69、全部原生迷宫 1,946、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 36 runtime、61 parsed，怪物 runtime 194。

- 2026-11-10 完成[布万加原生迷宫与攻击动作](../../reports/ws1/2026-11/2026-11-10_布万加原生迷宫与攻击动作.md)：把 `bwanga.dgn` 接入隐藏正式 `native_maze` 路线，闭合 10×1 源网格、10 连通格、15 张源 MAP、116 个 placement、普通首局 10 图、57 只/10 种怪和 93 个对象。新增 9 个怪 bank；布万加首领按 `[action list]`、`[attack info]`、`[cooltime]` 的 12 槽同长度关系接入 E-PARSE 动作表，并修复土耳其重击 10→12 招与冰波巨人第二招错误复用。quest 4002～4007、`16020..16024`、事件怪 61728、封印门 60020/60031、hell、图腾/item pocket、6 份缺失图腾粒子 ANI 与 AI character 20607 保留 raw/gap。专项 64、全部原生迷宫 1,877、旧世界 573/9,286/6,302/966/90 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 35 runtime、62 parsed，怪物 runtime 186。

- 2026-11-10 完成[白色废墟原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-10_白色废墟原生迷宫与对象载荷.md)：把 `whiteland.dgn` 接入隐藏正式 `native_maze` 路线，保留 4×4 源网格、10 连通格、12 张源 MAP、20 个 placement、双首领格和两首原曲；93 只直接怪覆盖 7 个怪种，新增兔子班图、路易、Sasquatch、雪人与高阶火精灵 5 个 bank。93 个可破坏物、6 个 item pocket、5 个 ice field 与 12 个 blizzard factory 显式登记；事件怪 61728、封印门 60029、hell、冰场/暴雪、Boss/雪人阶段、城镇/任务/结算留缺口。专项 56、全部原生迷宫 1,813、旧世界 573/9,286/6,302/966/90、地图 Python 17、编译 22 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 34 runtime、63 parsed，怪物 runtime 177。

- 2026-11-10 完成[利库天井原生迷宫与攻击动作](../../reports/ws1/2026-11/2026-11-10_利库天井原生迷宫与攻击动作.md)：把 `ricuceiling.dgn` 接入隐藏正式 `native_maze` 路线，保留 5×4 源网格、10 连通格、12 张源 MAP、15 个 placement、双首领格与两首原曲；68 只直接怪覆盖 12 个怪种，新增塔班图精英、雷电班图、投掷哥布林、冰巨人、冰波巨人、利库、风暴巨人与雪原蜘蛛 8 个 bank。63 个可破坏物、2 个 item pocket 与 35 个行为 trigger 显式登记；事件怪 61728、封印门 60029、hell、boss/AI 阶段、逐房混合曲与城镇/任务/结算留缺口。按同名 ATK/ACT 推断恢复 newmonsters 攻击动作，并修复 `../` ANI 规范化。专项 77、全部原生迷宫 1,757、旧世界 573/9,286/6,302/966/90、地图 Python 16、编译 22 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 33 runtime、64 parsed，怪物 runtime 172。

- 2026-11-10 完成[冰心少年原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-10_冰心少年原生迷宫与对象载荷.md)：把 `theboywithcoldheart.dgn` 接入隐藏正式 `native_maze` 路线，保留 2×1 源网格、2 连通格、3 张源 MAP/placement、1×1 起终点和原曲 `M_COLD_BOY`；16 只直接怪覆盖 7 个怪种，冷心少年、冷心、四个玩具怪与冰奈斯进入运行包，冷心少年火箭拳和玩具 C 波投射 PTL 闭合。27 个水晶可破坏物与 3 个冻结 Luna trigger gap 显式登记；事件怪 61728、事件位置、首领阶段/选招、标题/过场、城镇/任务/结算留缺口。专项 54、全部原生迷宫 1,680、旧世界 573/9,286/6,302/966/90、地图 Python 15 项及七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 32 runtime、65 parsed，怪物 runtime 164。

- 2026-11-10 完成[山脊原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-10_山脊原生迷宫与对象载荷.md)：把 `charnakridge.dgn` 接入隐藏正式 `native_maze` 路线，保留 4×4 源网格、10 连通格、11 张源 MAP、16 个 MapGreed placement、1×1 起终点和两首原曲；90 只直接怪覆盖 11 个怪种，Shavante 与 Beastmaster Looger 两条 Boss 行和全部新 bank 进入运行包。16 个可破坏物、冰导弹八段 PTL 与 34 个静态/粒子对象闭合；hell、封印门 60029、雪崩/blizzard、`itempocket`、双 Boss 阶段与城镇/任务/结算显式留缺口。修复空 tile 全阻挡归一化、多帧同盒破坏物校验、缺失 breakable 契约降级和 `monster/` 根路径 PTL 解析。专项 117、全部原生迷宫 1,520+106、旧世界 573/9,286/6,302/966/90 项及怪物全链/七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 31 runtime、66 parsed，怪物 runtime 158。

- 2026-11-10 完成[熔岩穴原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-10_熔岩穴原生迷宫与对象载荷.md)：把 `magmacave.dgn` 接入隐藏正式 `native_maze` 路线，保留 3×8 源网格、14 连通格、15 张源 MAP、48 个 MapGreed placement、1×1 起终点和两首原曲；113 只直接怪覆盖 15 个怪种，新增 10 个 bank 并保留 Atlas/Goliath/Titan 三条 Boss 行。68 个可破坏物、37 个 item draw、8 条特殊怪 payload 可执行；quest 4417、hell、封印门 60020、24 个混合 trap、25 个岩浆地面 trigger、`boom1` 与城镇/任务/结算显式留缺口。专项 116、全部原生迷宫 1,403+106、旧世界 573/9,286/6,302/966/90 项及怪物全链/七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 30 runtime、67 parsed，怪物 runtime 147。

- 2026-11-10 完成[暗精灵墓地原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-10_暗精灵墓地原生迷宫与对象载荷.md)：把 `darkelfcemetary.dgn` 接入隐藏正式 `native_maze` 路线，保留 5×3 源网格、13 连通格、24 张源 MAP、68 个 MapGreed placement、1×1 起终点和两首原曲；200 只直接怪覆盖 7 个怪种，新增普通骷髅、石骷髅、灵魂吞噬者、莉莉丝与 Drake 五个 bank。260 个可破坏物、111 个 item draw、14 条特殊怪 payload 可执行；Boss 猎杀 `50073..50076`、封印门 60020、hell、8 个混合 trap 与城镇/任务/结算显式留缺口。修复 pathgate `010/011/012` 通用模板展开、显式破坏粒子 OBJ 编译和 `original_3210` 缺失，并新增 v7 物品原帧包。专项 78、全部原生迷宫 1,287+106、旧世界 573/9,286/6,302/966/90 项及怪物全链/七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 29 runtime、68 parsed，怪物 runtime 137。

- 2026-11-10 完成[蜘蛛洞穴原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-10_蜘蛛洞穴原生迷宫与对象载荷.md)：把 `marpissalair.dgn` 接入隐藏正式 `native_maze` 路线，保留 6×5 源网格、17 连通格、30 张源 MAP、77 个 MapGreed placement、1×3 起终点和两首原曲；266 只直接怪覆盖 7 个怪种，新增普通蜘蛛、毒蜘蛛、Spider Boss、无怜悯盗尸者与幽灵女怪五个 bank。151 个可破坏物、125 个 item draw、43 条特殊怪 payload 可执行；quests 4408/4421、hell 第三布局、12 个混合 trap、骷髅堆/蜘蛛 spawn trigger 与城镇/任务/结算显式留缺口。专项 66、第一脊椎 53、浅栖 35、第二脊椎 65、树精繁殖地 74、GBL女神殿 195、天帷 112、极昼 111、炼狱 174、树精 30、神殿 273、通用迷宫 106、小地图 21、旧世界 573/9,286/6,302/966 项及怪物全链/七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 28 runtime、69 parsed，怪物 runtime 132。

- 2026-11-10 完成[第一脊椎原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-10_第一脊椎原生迷宫与对象载荷.md)：把 `1stbackbone.dgn` 接入隐藏正式 `native_maze` 路线，保留 4×4 源网格、10 连通格、20 张源 MAP、28 个 MapGreed placement、1×2 起终点和两首原曲；176 只直接怪覆盖 8 个怪种，新增 Starfish King 图集与 6 个攻击槽。118 个可破坏物、42 个 item draw、20 条特殊怪 payload 可执行；第二套 quest 4329/hell 布局、21 个混合 trap、海星卵/扫臂/重力 trigger 与城镇/任务/结算显式留缺口。修复第一脊椎 MapGreed 白名单与原生迷宫候选过滤。专项 53、浅栖 35、第二脊椎 65、树精繁殖地 74、GBL女神殿 195、天帷 112、极昼 111、炼狱 174、树精 30、神殿 273、通用迷宫 106、小地图 21、旧世界 573/9,286/6,302/966 项及怪物全链/七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 27 runtime、70 parsed，怪物 runtime 127。

- 2026-11-10 完成[浅栖之地原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-10_浅栖之地原生迷宫与对象载荷.md)：把 `shallowkeep.dgn` 接入隐藏正式 `native_maze` 路线，保留 4×5 源网格、18 连通格、38 张源 MAP、88 个 placement、2×2 起终点和两首原曲；344 只直接怪覆盖 6 个怪种，新增憎恶、投掷憎恶、幽灵、摩根与特殊棺/罐载荷 `ghoulstand` 等运行 bank。322 个可破坏物、138 个 item draw、9 个 v6 box-loot 定义可执行；第二套 quest/hell 布局、2 个 freezing Luna、21 个未知混合 trap 与城镇/任务/结算显式留缺口。修复原生迷宫双 `[maze info]` 普通布局选择、特殊对象 loot 父 ID 过滤、BGM 环境音/`RANDOM` 组与图集缺导入误报。专项 35、第二脊椎 65、树精繁殖地 74、GBL女神殿 195、天帷 112、极昼 111、炼狱 174、树精 30、神殿 273、通用迷宫 106、小地图 21、旧世界 573/9,286/6,302/966 项及怪物全链/七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 26 runtime、71 parsed，怪物 runtime 126。

- 2026-11-10 完成[第二脊椎原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-10_第二脊椎原生迷宫与对象载荷.md)：把 `2ndbackbone.dgn` 接入隐藏正式 `native_maze` 路线，保留 5×4 源网格、13 连通格、37 张源 MAP、62 个 placement、1×1 起终点、8 条固定映射和两首原曲；343 只直接怪覆盖 12 个怪种，新增蓝章鱼、雷射龙头炮、GBL教祭司与长脚罗特斯四个 bank。178 个可破坏物、19 个源箱组可执行；12 个祭坛钟、72 个地形/重力 trigger、11 个未知混合 trap 和 hell 封印门显式留缺口。修复莲花空等待帧导致图集烘焙中断，并让特殊对象优先保留未知 trap ID。专项 65、树精繁殖地 74、GBL女神殿 195、天帷 112、极昼 111、炼狱 174、树精 30、神殿 273、通用迷宫 106、小地图 21、旧世界 573/9,286/6,302/966 项及怪物全链/七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 25 runtime、72 parsed，怪物 runtime 120。

- 2026-11-10 完成[树精繁殖地原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-10_树精繁殖地原生迷宫与对象载荷.md)：把 `breeding.dgn` 接入隐藏正式 `native_maze` 路线，保留 4×4 源网格、10 连通格、12 张源 MAP、20 个 placement、1×2 起终点、11 条固定映射和两首原曲；102 只直接怪覆盖 8 个怪种，闪耀乌恩、树精、伪装郭里丹、逃亡男女信徒、乌迪普兰特、闪耀斯普恩与长老树精全部进入内容包与图集。144 个普通 action object、6 个特殊莲箱与 25 个幻花 trigger 显式留行为和触发缺口；混合 trap 保留未知 `2201/2501`。缺口登记改为按路径合并，避免同类对象互相覆盖。专项 74、GBL女神殿 195、天帷 112、极昼 111、炼狱 174、树精 30、神殿 273、通用迷宫 106、小地图 21、旧世界 573/9,286/6,302/966 项及怪物全链/七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 24 runtime、73 parsed，怪物 runtime 116。

- 2026-11-10 完成[GBL女神殿原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-10_GBL女神殿原生迷宫与对象载荷.md)：把 `goddesstemple.dgn` 接入隐藏正式 `native_maze` 路线，保留 4×5 源网格、11 连通格、13 张源 MAP、19 个 placement、1×2 起终点、12 条固定映射和两首原曲；93 只直接怪覆盖 9 个怪种，新增堕落的阿尔索尔、堕落信徒、GBL 女信徒、驯兽师与堕落的教主五个 bank。142 个可破坏物可执行；42 个无动作 `gblhelipad`、4 个含未知 `2211` 的混合 trap 与无直接 ATK 的特殊施法显式留缺口。修正无箱副本的全局箱掉落误拦，并让无 sprite action object 进入缺口登记。专项 195、天帷 112、极昼 111、炼狱 174、树精 30、神殿 273、通用迷宫 106、小地图 21、旧世界 573/9,286/6,302/966 项及怪物全链/七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 23 runtime、74 parsed，怪物 runtime 108。

- 2026-11-10 完成[天帷禁地原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-10_天帷禁地原生迷宫与对象载荷.md)：把 `bloodhell.dgn` 接入隐藏正式 `native_maze` 路线，保留 5×4 源网格、10 连通格、13 张源 MAP、16 个 placement、1×2 起终点、7 条固定映射和两首原曲；6 个 GBL 复活教徒怪种全部进入内容包与图集。77 个可破坏物、已知 `2210/48003` trap 可执行；`48021`、25 个 VEHemos trigger 和 hellparty 封印门显式留缺口。修复 `rebirthgblleader` 多 PTL 字段被强转字符串导致首领运行定义中断的问题，保留 3 个 PTL 依赖，但完整三组件投掷仍待多投影内核。专项 112、极昼 111、炼狱 174、神殿 273、通用迷宫 106、小地图 21、旧世界 573/9,286/6,302/966 项及怪物全链/七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 22 runtime、75 parsed，怪物 runtime 103。

- 2026-11-10 完成[极昼原生迷宫与对象载荷](../../reports/ws1/2026-11/2026-11-10_极昼原生迷宫与对象载荷.md)：把 `whitenight.dgn` 接入隐藏正式 `native_maze` 路线，保留 3×7 源网格、12 连通格、14 张源 MAP、48 个 placement、1×2 起终点、9 条固定映射和两首原曲；8 个直接怪物种全部进入内容包与图集，新增 `vehicle_battlingram`、`vehicle_catapultflame`、`zealot_craxy`、`zealot_pope`、`zepplin_zepplin`、`zepplin_zepplinmachinegun` 六个 bank。75 个可破坏物、21 个宝箱 item draw 物件、3 个召怪罐与已知 `2210/40002` trap 可执行；18 类未知 trap 和钟/左右幻花/VEHemoswen 行为 trigger 显式留缺口。专项 111、炼狱 174、神殿 273、通用迷宫 106、小地图 21、旧世界 573/9,286/6,302/966 项及怪物全链/七道内容闸门通过；依赖门禁 0 违规。60 级 DGN 更新为 21 runtime、76 parsed，怪物 runtime 97。

## 接续时的未完成工作

- 神殿周边、树精丛林、炼狱、极昼、天帷禁地、GBL女神殿、树精繁殖地、第二脊椎、第一脊椎、蜘蛛洞穴与浅栖之地都只完成隐藏正式路线接线。城镇入口/公开选择、特殊状态、原服务端随机序列、正式任务奖励和完整结算仍未闭合；不能把 `runtime` 写成原版副本已完成。
- 树精丛林 8 类 trap 仍待原状态/生命周期取证：`2001`、`2011`、`2111`、`2211`、`2501`、`2601`、`48020`、`48021`。当前只记录 `native_object_gaps`，不执行猜测效果。
- 炼狱 9 类 trap 仍待原状态/生命周期取证：`2000`、`2010`、`2100`、`2211`、`2510`、`2601`、`2610`、`48019`、`48022`。`droppingrocktrigger` 仅引用无伤害的 `GravityChanger.atk`，`entanglevinetrigger` 没有 `[attack info]`；二者均只记录行为 trigger gap，禁止当接触伤害执行。
- 极昼 18 类 trap 仍待原状态/生命周期取证：`2000`、`2001`、`2010`、`2011`、`2100`、`2101`、`2111`、`2211`、`2301`、`2311`、`2401`、`2411`、`2501`、`2511`、`2601`、`2602`、`2611`、`48020`。钟、左右幻花和 VEHemoswen 仅记录行为 trigger gap；钟的特殊 item 行未执行。
- 天帷禁地的 `48021`、25 个 VEHemos trigger 与 hellparty 封印门仍待行为取证。`rebirthgblleader` 的 3 个投掷 PTL 和重复投掷记录已编译，但运行时只用首个分量作为单投射物时钟，多组件同帧轨迹未闭合。
- GBL女神殿的 42 个 `gblhelipad` 无可见基本动作，4 个莲箱混合 `2210/2211` trap 因未知分支整体不执行；阿尔索尔啼叫、驯兽师三段施法、教主啼叫与 GBL 女信徒投掷均没有直接 ATK，召唤/增益/抓取/投放语义待逐招取证。
- 树精繁殖地的 144 个普通 action object 与 6 个特殊莲箱都只有行为或数据，没有可执行生命周期；25 个幻花 trigger、`2201/2501` trap 与多招无直接 ATK 的施法/投放仍需逐项取证。
- 第二脊椎的 67 个海星卵、5 个重力转换器、12 个祭坛钟和 11 个混合未知 trap 未执行；hell 封印门、33 条特殊 AI 与长脚罗特斯 dummy/空 ATK 动作仍需逐项取证。
- 第一脊椎的第二套 quest 4329/hell 布局只保留 raw，21 个混合未知 trap、34 个海星卵、8 个扫臂 trigger、6 个重力转换器与封印门 60012 未执行；20 条特殊 monster payload 和 Starfish King 6 招的阶段/生命周期仍需逐项取证。
- 蜘蛛洞穴的 quests 4408/4421 与 hell 第三布局只保留 raw，12 个混合未知 trap、43 个骷髅堆 special object、16 个蜘蛛 spawn trigger 与封印门 60020 未执行；43 条特殊 monster payload 和 5 个新怪 bank 的阶段/生命周期仍需逐项取证。
- 暗精灵墓地的 Boss 猎杀 `50073..50076`、封印门 60020、命中次数/出现率、`[hell dungeon]` 与 8 个混合未知 trap 只保留 raw；14 条特殊 monster payload 和 Drake 5 招的阶段/生命周期仍需逐项取证。
- 熔岩穴的 quest 4417、hell、封印门 60020、事件怪 61728 与 24 个混合未知 trap 只保留 raw；25 个岩浆地面 trigger、`boom1`、8 条特殊 monster payload 和 Atlas/Goliath/Titan 三行 Boss 的阶段/关系仍需逐项取证。
- 山脊的 hell、封印门 60029、事件怪 61728、雪崩/blizzard 与 `itempocket`/2211 只保留 raw/gap；Shavante、Beastmaster Looger、Bash/Emre/Labina 的阶段与选招仍需逐项取证。
- 冰心少年的事件怪 61728、MAP 事件位置、冻结 Luna trigger、冷心少年 6 招选招、冷心与四个玩具怪的出现/阶段关系、标题/过场和城镇/任务/结算只保留 raw/gap。
- 利库天井的事件怪 61728、封印门 60029、hell、2 个 item pocket/2211、12 barrier、6 snow catapult、8 ricuniddle、9 snowfall manager、利库 9 招阶段/召唤与雷电班图 10 招选招只保留 raw/gap；普通段 4 张山脊曲 MAP 的逐房切曲未接入。
- 白色废墟的事件怪 61728、封印门 60029、hell、6 个 item pocket/2211、5 个 ice field、12 个 blizzard factory、Sasquatch 6 招阶段/召唤、兔子班图/路易/雪人/高阶火精灵选招与 17 个无 sprite 对象只保留 raw/gap。
- 布万加的 quest 4002～4007、`16020..16024`、事件怪 61728、封印门 60020/60031、hell、3 个图腾、3 个 item pocket/2211、6 份缺失 `totem_pltcle0..5.ani` 与 AI character 20607 只保留 raw/gap；布万加 12 招和其余 Bantu 怪阶段/选招仍需同条件取证。
- 冰雪宫殿的事件怪 61728、封印门 60029、hell、AICharacter 609 `crux.aic`、女王 `proc.act` 召唤莫哈妮、54 个 action/special 可破坏候选、trap 2211 与 9 个 trap 行为触发只保留 raw/gap；女王 4 招阶段/命令关系仍待同条件取证。
- GBL教阿拉德分部的 quest 3802/3803、hell、事件怪 62502、封印门 60040、5 只 quest-only 淑女信徒、Isadora2、54 个 action-object、14 个 bookcase trap 与未知 trap 2000/2100 只保留 raw/gap；伊莎杜拉 13 招与 GBL Colossus 混合 ATK 槽仍待同条件取证。
- GBL教研究所的 hell、事件怪 62502、封印门 60041、413 个 trap/行为对象、243 个可破坏物候选、`jilef` special/action/visual 生命周期和六种普通怪阶段/选招只保留 raw/gap；`jilef` group 1 物品与原图已准备，但实际开箱、掉落与奖励事务未验证。
- GBL教孵化场的 hell、事件怪 62502、封印门 60042、8 个 altar2/altar3、27 个 `gblhelipad`、56 个倒地障碍、`bossaltar`、champion/hit count 和七种怪的阶段/选招只保留 raw/gap；两个 `2210` 罐 payload 已进入运行 prop，但无箱组与 Vangelis 两个召唤槽仍按缺口记录。
- 堕落的盗贼的 hell、事件怪 61728、封印门 60018、`q6220` 剧情 cage/podium、5 个狗柱 trigger、`act6box` 2211、champion 阈值和 `myojin` 双 Boss 行只保留 raw/gap；`statue` 与 `cityhallgate` runtime `moves=0`，v9 group 0 的合法空抽保持原概率。
- 月光酒馆的 quest 4102～4106、最终 hell、5 套非普通 block、135 个 chair/siktak/namutong 家具契约、2211 payload、Sinead 阶段/选招和逐房 `M_TAVERN_01` 切换只保留 raw/gap；selected block 元数据与普通/首领 BGM 选择已接入。
- 王的遗迹的 hell、封印门 60026、trap 2010/2011/2110/2111/2211、守卫格挡/破防、锤王阶段/冷却/EarthQuake、邀请物、Borodin 任务、`alphraira` 城镇与奖励/结算只保留 raw/gap；2210 与未知 2211 同对象时整体不执行，group 1/2 的源空组不被 group 0 顶替。
- 绿都格罗兹尼的 4 个缺失 Cartel 墙门帧、Tree Thrower 空 `shootTree.act`、stone/odesabox/cover 破坏契约、cover trap 2000/2010、封印门 60043、事件怪 61728、quest 3907～3921、九套 quest/hell 布局、Cypher 阶段/冷却和多招实际选择、`westcoast` 城镇入口与奖励/结算只保留 raw/gap。
- 热血八番街的 4 个缺失 Cartel 墙门帧、20 个 trashcan 与 9 个 odesabox 的 breakable source、odesabox trap 2010/2110、封印门 60044、事件怪 61728、quest 3901/3903/3904/3906、四套 quest/escape 布局、hell 标记、`M_TEMP_MCGEE` 缺失 cue、RocketMan 17 槽选招、`westcoast` 城镇入口与奖励/结算只保留 raw/gap。
- 暗黑城入口的 20 个 brazier/60 个 torch breakable source、coffin trap 2211、19 个 lightning-bug/7 个 neckless-knight/1 个 underfoot-gate 行为、封印门 60020、事件怪 61728、hell、Headless Knight 7 槽阶段与 `noierfera` 城镇入口/奖励/结算只保留 raw/gap。
- 斯卡萨之巢的 27 个 scasa egg、item pocket trap 2211、blizzard factory、bull totem/静态冰冻障碍行为、封印门 60031、事件怪 61728、quest 4571/escape block、quest boss 9311、Scasa 27 招阶段与 `snowmt` 城镇入口/奖励/结算只保留 raw/gap。
- 根特周边的 73/72 个灯柱/APC/果袋 breakable source、果袋 trap 2200/2201/2210、43/37 个 drum tongue 行为、封印门 60034、事件怪 61728、hell、Bentinck 12 招阶段与 `gent` 城镇入口/奖励/结算只保留 raw/gap。
- 根特东门的 55/56 个灯柱/果袋 breakable source、trap 2200/2201/2210/2211、6/12 个 spider mine、quest 4212/escape block、封印门 60034、事件怪 61728、hell、Captain Shured 10 招阶段与 `gent` 城镇入口/奖励/结算只保留 raw/gap。
- 浅栖之地的第二套 quest/hell 布局只保留 raw，2 个 `shallowkeepfreezingluna` 与 21 个混合未知 trap 未执行；特殊棺/罐 `ghoulstand` 的生成/位置/生命周期、箱组随机和首领阶段仍需逐项取证。
- 60 级目标 DGN 仍有 49 个 `parsed`。下一批须按现有地图导出、城镇/区域、任务依赖和怪物覆盖选择普通路线；任务专用 `dungeon/quest/` 路线先单独核对生命周期与单机语义。
- 通用可破坏物标准七项布局的 HP/阶段与音效槽位按 E-PARSE 字段和既有外壁固定对象适配推定；逐 OBJ 的原客户端同条件受击、损伤阶段动作和更多 `/trap/` 联动仍待取证。
- 1,176 条静态 MAP 对象仍只由地图渲染；开关、吊灯联动、地刺/毒沼地形、`goblinbunker` 多部件、可破坏 `/trap/` 与地图事件触发需继续分包。
- 石像 OBJ 请求的 `HEXA_BREAK` 在当前唯一 `audio.xml` 中无精确条目；manifest 保留 unresolved，禁止用相近音效顶替。
- Mirkius 空 `[attack motion]` 槽已按 E-INFER 复用前一动作并保留独立 `attackheart.atk`；需原客户端同条件确认第三招的动作与选招表现。
- 阿登原档最低 68、basis 71，当前运行仍为 58 的隔离测试适配并标记 `future_above_60`；未纳入 60 级可玩基线。
- 暗影迷宫已调查但暂不接入：4 套 3×3 布局的 Boss 使用 `[ai character] 1301 → swordman/Sayoung/Sayoung.aic`，当前缺少敌方 AICharacter/APC 战斗内核；临时导出只留在本机 `temp/shadowmaze_v1_blocked_20261110/`，禁止以零怪 Boss 房冒充完成。
- 正式全套停在既有 `build_dnf_quest_rules.py --check` stale；按分工不由 ws1 擅自重建。前置已完成的新世界审计、龙人契约、Zealot、GBL教阿拉德分部/GBL教研究所/GBL教孵化场/堕落的盗贼/月光酒馆/王的遗迹/绿都格罗兹尼/热血八番街/暗黑城入口/斯卡萨之巢/根特周边/根特东门/冰雪宫殿/布万加/白色废墟/利库天井/冰心少年/山脊/熔岩穴/暗精灵墓地/蜘蛛洞穴/第一脊椎/浅栖之地/第二脊椎/树精繁殖地/GBL女神殿/天帷禁地/极昼/炼狱/树精/神殿原生迷宫、世界机关与战斗流程均通过。
- 正式 `loop.tscn --loop-test` 当前为 494 checks / 40 failures：35 条 `native_maze` 被既有断言要求非空 `rooms`，另有 5 条既有可见副本战斗/门/任务推进/存档失败；不计入本批通过。
- 战斗进场同步 mount 仍约 4.27 秒，尚未改造成显式 loading/异步加载；逐武器普攻盒、技能判定义项和小地图/结算覆盖层仍待原版证据与后续 UI 资源闭环。
- 战斗响应、跳攻、拾取、原版字体、BGM 加载和音效声池仅完成自动化与 profiler 验证；真实手感、混音和 UI 观感等待 rainmk 实机复核。
- `7a00f659` 已提交族级 AI 目录索引、运行时回退查询和拾取下蹲帧计数；接续时“未提交”的记载已纠正，未将提交视作回归或试玩通过。
- 175 条剑士 SKL 与 78 个树节点均有运行定义（52 主动 / 26 被动），但原版一致性未完成；ws2 继续逐招校准，ws1 本批只做独立输入、快捷栏与性能回归，不把运行入口计为完成。
- 鬼剑士首批：输入专项 27 项、快捷栏专项 72 项已发布，均 failures=0；ws2 仍持有生产文件并负责集成正式回归入口。格挡、三段斩的取消窗口等 ws2 发布后补断言。
- 技能面板独立契约已完成；本轮没有修改面板生产代码，后续面板缺陷需先用 `test_ws1_panel_contract.gd` 复现再改。
- 并行计划中 ws1 的任务日志/追踪/NPC 对话、装备 NPC 服务、仓库、角色属性与装备管理、角色存档与档位、死亡/复活规则与界面、窗口与全屏适配均已完成并发布。只读素材浏览工具作为储备；角色删除、多职业、正式转职和角色字段/版本迁移仍不在本区范围。
- `python tools/check_dnf_deps.py` 已恢复 0 违规：战斗 API 不再直接依赖 loot，原生宝箱准备改由游戏节点提供。
- 当前主线独立战斗套 576 项仍有 5 个失败，集中在 battle feedback widget draw order、draw-slash object/timeline 和剑魂太刀五段三段斩选择；本批未改这些 HUD/draw 业务路径，未计入本批通过。
- 标准 `run_dnf_loop.ps1 -Test` 预检停在既有 `build_dnf_quest_rules.py --check` stale；本轮未擅自重建 ws2 任务产物，直接运行同一 `loop.tscn --loop-test`，完整流程 470 项通过。
- [ws2 多招式接收诊断](../../reports/ws2/2026-10/2026-10-29_ws1多招式接收回归差异.md)：ws1 已完成修复并从独立场景复跑通过；等待 ws2 在当前主线保留原断言接收复核。
- content 模块迁移等待 ws2 接收；新代码一律使用 `res://content/api/…`，`Numbers.shared_config()` 返回值不可修改。
- 最新正式入口 `loop.tscn --loop-test` 已通过；本批新增隔离契约、真实复活入口与显示契约同时在各自入口通过。项数与质量基线见[进度看板](../01_进度看板.md)。
- 1～16 主线仍待 rainmk 从建角开始用真实输入玩到 16 级并反馈节奏/画面/经济卡点；自动化验证按任务等级抬级，不算真人通关。
- act8 仅作怪物逻辑测试床：验证攻击/受击/选招/移动/死亡和内容包/图集即可，不做城镇入口、主线接入或内容验收。
- act8 逻辑测试床已跑通；9 种 haze IMG 缺失，待 ws2 补同来源原图后再烘焙图集和做画面验收。
- 复活提示布局、原版币旋转/粒子/音效、3 秒保护与复活手感待 rainmk 实机确认；复活币获取节奏仍为 E-ADAPT。
