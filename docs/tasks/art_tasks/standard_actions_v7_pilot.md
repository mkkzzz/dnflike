# 任务：standard_v1 动作首轮小样 v7

## 1. 身份与需求

| 字段 | 内容 |
|---|---|
| task_id | standard_actions_v7_pilot |
| revision | v7；候选通过并验收前不替代现行资源 |
| asset_type / workflow | 玩家动作；[14](../../design/14_美术资源全流程.md) B |
| style / theme | handpainted_action_v1 / dark_fantasy_v1 |
| owner / integration_owner | ws2；既有可切换试玩授权保留，但 c2 比例失败暂不接入；须先有新的过门候选 |
| lifecycle | 源图制作（source_review）：c2 已退回，c3 直立/准备比例基准已获用户认可；完整动作与武器分层未通过、未实装 |
| 批准范围 | 2026-10-15 使用者同意 attack1 首轮测试，并授权行走、奔跑、跳跃基础动作小样；这不是源图/成品或实机批准 |

本轮逐组制作代表小样，不扩展其它攻击、时装或技能；共用标准原画的脸、比例、服装、色板、游戏机位和右手单手持刀规则。

| 语义 ID | 小样范围 | 成功表现 |
|---|---|---|
| actor.player.base.combo.1 | attack1 蓄势、释放、接触、余势与恢复 | 刀手同方案、髋肩发力；与 V6 同比例对比 |
| actor.player.base.walk | 完整左右腿交替循环 | 接触、压低、经过、抬高清楚；避免只有左右大跨步 |
| actor.player.base.run | 完整左右腿交替循环 | 蹬地、腾空、着地、缓冲清楚，区别于加速行走 |
| actor.player.base.jump | 准备、蹬离、上升、顶点、下落、着地、缓冲、恢复 | 空中收腿、衣摆滞后；虚拟地面 root 保留高度 |

## 2. 依赖与影响

- 身份：standard_v1，按 [D030](../../design/决策清单.md) 与[标准原画任务](char_swordsman_standard_v1.md)文字规格优先；A8 握法与 A5 重出不阻塞本轮。
- 动作路线：[18](../../design/18_角色锚定与动作管线.md) S4，骨架提供姿势约束，参考原画提供身份。
- 现行基线：V3/V4 的移动和跳跃、V6 的 attack1；小样仅发布候选，不修改 game 资源、玩法时长、物理移动或碰撞。
- 下游：代表小样须完成武器/手指层及三武器 G3 验证后才铺量；再按合格动作补刀光/事件与接入映射。带刀设计图不代表可换武器成品，不能先批量一体图再补拆分。
- 回退：现行资源保持原路径与映射；新目录与旧版并存。

## 3. 参考与生成能力

| 参考 | 用途 | 实际输入 |
|---|---|---|
| `art/concepts/characters/players/swordsman/standard_v1/sheet_pose_head_c2.png` | 朝右游戏机位、脸、握刀和服装 | 各次调用的真实路径列表记 generation.json |
| `art/concepts/characters/players/swordsman/standard_v1/sheet_main_c1.png` | 四向身份、材质与比例 | 同上；图的已知瑕疵以文字规格纠正 |
| 本任务各动作骨架引导板 | 格子位置、相位、关节、握点和刀向 | 同上；引导不是最终人物画面 |

使用内置 image_gen，直接传入参考图片并请求真实透明背景；不是在提示词中写路径代替输入。完整提示词、输入列表、工具返回与实际透明度检查保存于 v7 的生成和加工记录。不调用收费 API/CLI，不上传本机 ComfyUI 安装路径。

## 4. 小样与导出规格

以下 190 px 及 c2 帧表是历史试制规格，不用于新制作准入。2026-10-17 后先按 [人工比例表](../../../art/concepts/characters/players/swordsman/standard_v1/measurements/proportion_v1.json) 和本任务末节建立同源直立基准；新角色导出按站立等效 380 px，不放大源像素。

- 生成请求为每组 4 列 × 2 行、8 个真实关键姿势；实际主体数量与布局须看图后显式标定，不能按生成请求假定成功。
- 固定朝右三分之四游戏机位，约 8 头身；统一缩至站立等效身高 190 px，不按每帧外接框分别拉伸，不把下蹲/腾空姿势拉成等高。
- 单手持标准太刀的候选先验证动作设计；不得宣称武器分层或任意换武器已实现。右手为持刀手，左手作平衡；无额外武器、刀光、残影或地面阴影。
- 统一 RGBA、straight alpha、normal 混合；实际输出 alpha 和边缘须检查。
- 用显式 bbox/root/duration_ticks 导出；60 Hz 整数动作时钟，不预烘命中停帧。跳跃以虚拟地面 root 和高度记录，禁止逐帧把最低鞋底吸回地面。
- 预览直接回放同一导出 PNG 和 manifest；GIF 的时长量化与真正时速须如实说明。

## 5. 源图、加工与证据（2026-10-16）

- 源图与完整提示词：`art/animations/players/swordsman/v7/sources/generation.json`；各组 c1 首轮与 c2 定向修图均保留，实际传入身份原图和骨架引导板。
- **行走退回**：c1/c2 都重复同一半步，未形成清楚左右腿交替；没有导入正式候选包。标定草案保留失败依据，不能按格数宣称完整循环。
- **候选**：attack1_c2 补回蓄势缺失的刀身；run_c2 修了后半圈部分腿位，但完整左右交换仍不清楚，只可评跑姿/节奏，不能标完整循环通过；jump_c2 加强蹬离伸展。源图仍有比例/太刀长度、脚滑、横斩轨迹与收势待评审，未获源图或成品批准。
- 加工配置：`art/animations/players/swordsman/v7/sources/pilot_c2.json`；自包含导出入口 `art/animations/players/swordsman/v7/exports/pilot_c2/manifest.json`。v7 JSON 固定 LF 换行，保证跨 clone 的文件哈希一致。
- attack1/run 按显式种子与 alpha 核心连通域隔离跨格主体，mask 随包保存；跳跃使用显式独立裁切、保留低 alpha 噪点，未强行丢弃细碎头发/手指。只做裁切、等比缩放和定锚，没有程序扭曲或伪造姿势。
- 跳跃拆 rise/apex/fall/land，prepare 单独保留；jump_demo 从蹬离开始，外部高度曲线仅为评审演示，不固定实机跳跃时长，不增加输入延迟。
- `preview_report.json` 记录实际帧引用与 GIF 误差；`preview_publication.json` 记录评审目录与包内回放文件逐字节一致；`independent_review.json` 记录独立技术重建及实际看图结论。

复现（Python 环境需已具备 `requirements.txt` 所列对应依赖；引导脚本需 numpy/Pillow，导出只需 Pillow）：

```powershell
python tools/explore/standard_actions_guides.py walk run jump attack1
python tools/explore/standard_actions_pilot.py art/animations/players/swordsman/v7/sources/pilot_c2.json --legacy-rebuild
```

导出目录已存在时，请用新的候选目录，或对同一候选显式加 `--overwrite`；随机生图以已入库源图为准，不能靠再跑提示词保证相同结果。

评审入口（均在仓库 `docs/previews/v7_pilot/`，绝对路径根为当前 clone）：

| 文件 | 用途 |
|---|---|
| `docs/previews/v7_pilot/actions_naked.gif` | 奔跑、跳跃演示、attack1 同场裸动作总览；短招结束后保持末帧，仅为总览复看 |
| `docs/previews/v7_pilot/run_naked.gif` | 奔跑实速循环 |
| `docs/previews/v7_pilot/jump_demo_naked.gif` | 跳跃分段拼接演示，非实机物理固定时长 |
| `docs/previews/v7_pilot/attack1_compare.gif` | 同比例与 V6 裸动作并排，供 G2/G4 评审 |
| `docs/previews/v7_pilot/attack1_contact.png` | 普攻全部关键姿势与 root |
| `docs/previews/v7_pilot/run_contact.png` | 奔跑关键姿势与 root |
| `docs/previews/v7_pilot/jump_demo_contact.png` | 跳跃相位与独立高度 |

GIF 为整数动作 tick 经累计 10 ms 量化，准确时钟以 manifest 为准；本轮没有制作 MP4 或实机录像。

### S4b 后备探针：能运行，画质未过

本机 ComfyUI 的 SDXL + IPAdapter + Union OpenPose 实际上传了身份裁切和标准色骨架，并完成两次单帧推理；首图严重几何化/身份漂移，一次 v_prediction + zsnr 重试近乎全灰，全部拒收。工具可运行不等于美术管线可用，不进入正式回放；服务已停止。

真实工作流、输入上传回执、模型哈希、节点版本、结果与失败评审见 `art/animations/players/swordsman/v7/sources/comfy_probe/review.json`；探针入口 `tools/explore/comfy_pose_probe.py`。本机安装/运行时路径仅存 `.workspace`，不入库。后续须先分别隔离验证 checkpoint、IPAdapter、ControlNet，不继续盲目批量出图。

## 6. 验收门与当前结果

| 检查 | 要求 | 结果 |
|---|---|---|
| 格式与回放 | 引用、RGBA、边界、显式时长、锚点和朝向 | 导出校验及独立重建通过，详见包内报告；握点/护手/刀尖保护点未标定，不宣称自动验证通过 |
| G1 身份 | 各动作与 standard_v1 同角色，跨图同服装和比例 | c2 头部显示尺度抽测失败、站高未经验证，已退回；c3 双姿态头高数值过门，完整身份/细节仍待评 |
| G2 画质 | attack1 与 V6 并排；最多两轮，不达标则按18退回S0 | 并排回放已提供，待用户判断；生图次数与提交均不算通过 |
| G3 武器 | 去刀补握拳/手指层，挂回太刀并换巨剑/短剑 | 已有[结构试验与同包回放](../../reports/ws2/2026-10/2026-10-17_V7普攻三武器分层验证小样.md)；已补骨架刀/刃投影，还原/遮挡待人工评审，不自动铺量 |
| G4 裸动作 | 实速先看步态、重心、跳跃与发力；再看特效 | 裸动作已回放；行走退回，奔跑/跳跃/attack1 待用户评审 |

## 7. 发布与实装待办

- 2026-10-16 使用者已授权“实装看看”；本日收工时仅完成只读接入方案核对，游戏侧尚无 v7 接入改动。下次按[收工续做记录](../../reports/ws2/2026-10/2026-10-16_V7动作小样收工与试玩接入待办.md)直接继续，不把试装授权当成源图或实机验收。

- [x] 源图、真实输入/提示词、骨架、标定、导出包与预览自包含入库；发布结果以交接日志及远程提交核对为准。
- [ ] 用户认可小样身份、画质与裸动作。
- [ ] 完成 G3 武器分层/换武器验证，补真实握点和刀线。
- [ ] 逐动作补过渡与整套资源，明确替换映射并交接。
- [ ] 接收区接入、受影响回归与实机证据。
- [ ] 用户实机验收后升级状态。

## 8. 2026-10-17 比例复核与 c3 基准

用户指出 v7 头偏大。抽测确认旧配置的头部显示尺度不合格，见[最终对照](../../previews/v7_proportions_2026-10-17/measurement_comparison_refined.png)与[审计报告](../../reports/ws2/2026-10/2026-10-17_V7头部比例核查与重做准入.md)。导出器没有局部放大头部；站高估值和源图比例控制未形成闭环，不应直接将 c2 接入试玩。具体源姿态应重标还是重画，要在可靠直立基准下逐一复核，不能仅据 3 个样本宣称全部原画都变形。

- c2 现行 [manifest](../../../art/animations/players/swordsman/v7/exports/pilot_c2/manifest.json) 已标拒收；原 PNG/配置保留，旧 manifest 另存快照。历史重建专用标志不允许新配置借用，也不通过 G1。
- c3 只做一张“直立＋准备”基准：[源图和完整提示词](../../../art/animations/players/swordsman/v7/sources/proportion_reset_c3/pair_c1/generation.json)；[导出包](../../../art/animations/players/swordsman/v7/exports/proportion_reset_c3_pair_c1/manifest.json)；[同包对照](../../previews/v7_proportions_2026-10-17/c3_reference_compare.png)。同图站高实测 855 px、向下导出 380 px；用户随后回复“我觉得这一版没问题”，已将比例认可记录在[批准单](../../../art/animations/players/swordsman/v7/sources/proportion_reset_c3/pair_c1/artwork_approval.json)，不含动作/分层/实机认可。
- 新导出必须给 `proportion_check`，校验参考/源图哈希、全部姿态的可见发顶/下巴与同图站立高度；缺项、超差、放大在写文件前就停止。`tools/test_actor_proportions.py` 覆盖这些拒收条件。
- 这不是完整动作重做。旧行走半步、奔跑腿序、普攻轨迹/收势、跳跃相位与 G3 换武器仍须处理；c3 中立姿态的入鞘刀柄与空鞘要求也尚有差别。
- 后续按[不含技能基础动作任务](swordsman_base_actions_v7.md)先验证一招的完整动作与三种武器分层，过 G1/G2/G3/G4 再铺量；现行 V6 继续使用。
- 用户“开搞”后完成首个 attack1 三武器结构试验，真实媒体和去刀/标点修订记录见[本轮报告](../../reports/ws2/2026-10/2026-10-17_V7普攻三武器分层验证小样.md)；不是将旧c2重新放行，也没有完成全套动作或完整G3。
