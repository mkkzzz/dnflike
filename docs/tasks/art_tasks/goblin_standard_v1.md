# 普通哥布林标准原画 v1（采用原版）

## 1. 现行决定与范围

| 字段 | 内容 |
|---|---|
| task_id / asset_id | `goblin_standard_v1` / `concept.enemy.goblin.standard` |
| revision / replaces | `standard_v1_original`；整理现行原版，旧资源不替换；新候选 `c1` 已弃用 |
| asset_type / workflow | 怪物标准原画；14 文档 E 路线，静态设定参考 A |
| style_profile / theme_pack | `handpainted_action_v1` / `dark_fantasy_v1` |
| owner / integration_owner | ws1 / 后续接入待分配 |
| scope | 原版正式源图、原生细节裁切、缺口与补充规划；不生成新造型/动作或改游戏 |
| lifecycle | 原版主体 `source_approved`；完整设定包待补；`c1` 为 `rejected` |

2026-10-16 用户评审：“这版新的哥布林不如原版的，原版的更像怪物”，决定继续用原版。保留原版头身、矮壮体态、夸张面部、皮肤/装备细节和怪物气质；停止瘦长、小头与面部克制方向。此前 4.5 头身和 70% 身高只是被否决候选的目标，不是现行规格。

原图 1024×1024 的已有细节足够，不必重画更精细的全身。真正缺口是不可见视角、武器/握法规格及比例/颜色标定。

2026-10-16 用户进一步确认“就这样就行”：保留现行原版与武器，不再补画或调整。下列侧/背视图、武器与色板等只保留为未来动作制作按需补充的规划，不属于当前待办。

## 2. 正式原画路径与补充路线

| 用途 | 正式位置 | 当前范围 |
|---|---|---|
| 正式原画资产入口 | [manifest](../../../art/concepts/characters/monsters/goblin/standard_v1/manifest.json) | 源图、批准范围、裁切参数、待补项 |
| 原版主源图 | [goblin_original.png](../../../art/concepts/characters/monsters/goblin/standard_v1/source/goblin_original.png) | 字节一致复制，无重绘/镜像/缩放 |
| 细节与材质参考 | [details](../../../art/concepts/characters/monsters/goblin/standard_v1/details) | 脸、服装、握持、原武器、脚部的原生裁切；非新原画 |
| 历史生成候选 | [原候选目录](../../../art/concepts/characters/monsters/goblin/rejected_v1) | `c1` 弃用，保留追溯，不作为正式母版 |
| 评审媒体 | [旧新对比](../../previews/goblin_standard_v1/c1_compare.png) | 仅历史对比，不是正式资源入口 |
| 引擎消费资源 | `game/assets/demo/` | 保留现行动作，不引用 previews 作为源资产 |

| 阶段 | 产物/通过门 | 状态 |
|---|---|---|
| P1 原版身份锁定 | 原图原样归档、manifest、已有细节整理；不再重画全身 | 本轮完成，批准仅主体造型 |
| P2 缺口补齐 | 优先纯侧/背视图；武器选定后出单体尺寸与握点；原图/实机抽取比例和色板 | 待制作；不能用旧姿势或裁切假装新视图 |
| P3 标准设定完整化 | 复核跨视图身份，按需补手部遮挡、透明主体/部件与组合标定 | 待 P2，原画包齐备才记完整 |
| P4 动作交接 | 另立动作任务，真实参考输入、相位/root/方向/接触/受击链明确 | 本轮不做 |

正式源图/细节放角色原画分类，动作源与导出归动作分类，运行资源放 `game/assets/`；`docs/previews/` 只放评审媒体。2026-10-16 全仓 art 分类已整理，具体规则见 [21](../../design/21_美术目录与资产归档.md)。

## 3. 参考、来源与能力边界

| 文件 | 用途/批准依据 | 是否作为图片传入生成器 |
|---|---|---|
| [原版立绘](../../../art/concepts/characters/monsters/goblin/legacy/goblin.png) | 2026-10-16 用户选回原版主体；原武器是否也保留待确认 | 本轮只原样归档，不调用生成器 |
| [旧动作审查板](../../../art/animations/shared/demo_v2/sources/monster_demo_v2_review.png) | 看现行小图轮廓与攻击路线；不是新动作批准 | 否 |
| [风格规范](../../design/15_统一风格与题材规范.md) | 高清手绘、深描边、主明暗加柔和渐变、微弱像素感 | 文本规格 |
| [全流程](../../design/14_美术资源全流程.md) | 原画与动作、技术通过与美术认可分开 | 文本流程 |

本轮加工为原样复制及 Pillow 原生像素裁切，无新生图、重绘、增细节、放大或去背景。原图最初生成模型/种子未核实，不编造来源记录。

历史 `c1` 的完整请求/首次取消见 [generation.json](../../../art/concepts/characters/monsters/goblin/rejected_v1/generation.json)，成功生成及用户否决见 [generation_c1_retry1.json](../../../art/concepts/characters/monsters/goblin/rejected_v1/generation_c1_retry1.json)。本会话工具没有参考图片输入接口；后续补新视角时仍须解决身份保持，不能用另一只哥布林拼设定。

## 4. 静态规格与后续动作意图

- 正式源图 1024×1024 PNG、RGB，无 alpha；保留原灰底与地面投影。细节裁切同样有背景，不是透明部件。
- 保留原图三分之四朝向与比例，不镜像、不重新画脸；纯侧/背视图目前没有。
- 保留原图绿皮、黑乱发、尖耳、黄眼、獠牙、粗糙皮肤与简陋皮革布装。色板后续从原图采样并区分高光/阴影，不凭文字重定颜色。
- 不重复旧后处理、不调游戏 `model_scale`/hurtbox；人物大小后续按现行实机与玩家同场标定，不把静态源图像素当真实身高。
- 普通攻击意图仍为举棒蓄势 → 过顶 → 向前下砸 → 余势 → 待机；本轮不生成动作。
- 武器方案确认后才标定尺寸/握点；原图含武器，裁切握持仅为参考，不声称已支持独立换武器。
- 后续动作仍需 root/画布/60 Hz 相位和方向契约；缺手背/指遮挡视角时再定向补，不先批量做表情集。

## 5. 依赖与替换边界

| 现行文件/映射 | 后续需检查 | 本轮处理 |
|---|---|---|
| `art/concepts/characters/monsters/goblin/legacy/goblin.png` | 与正式复制源保持一致；后续以 manifest 找正式包 | 保留旧文件，不破坏旧引用 |
| `art/animations/shared/demo_v2/sources/monster_demo_v2.png` / monster 动作组 | 若只保留原版不强制重做；换小棒槌才重验持械姿势/接触 | 保留现行映射 |
| `game/data/monsters.json` 中 goblin | 改武器时复核范围；原版继续使用不因此改碰撞 | 不修改数值 |
| 受击/倒地/起身/死亡 | 新动作需要时另列；已有姿势不是纯侧/背标准设定 | 不新增帧 |
| 现有音效 | 换武器后再判断接触材质是否需变 | 不制作或改音频 |

正式路径整理不等于游戏重新接入；本轮没有切换运行资源、删除旧版或实现新资源 resolver。

## 6. 选择记录与当前校验

| 对象 | 文件 | 用户结论 |
|---|---|---|
| 原版 | [正式主源图](../../../art/concepts/characters/monsters/goblin/standard_v1/source/goblin_original.png) | 2026-10-16 采用原版主体；保留怪物气质 |
| 新候选 `c1` | [历史源图](../../../art/concepts/characters/monsters/goblin/rejected_v1/candidates/c1/Original_enemy_character_conce_2026-10-16T03-30-13.png) | `rejected`：不如原版像怪物，停止迭代，不删除历史 |

- [x] 正式源图与旧原图字节一致，未修改旧文件；五张细节都是原图裁切。
- [x] 原图、脸部和握持细节已查看：现有纹理/五官/手指细节足够，无需再重画更精细全身。
- [x] 现行原版与历史候选/评审媒体分离，正式入口不在 previews。
- [ ] 纯侧/背视图、武器选择/尺寸/握点、比例与色板标定。
- [ ] 透明主体/独立部件及后续动作；没有把原图裁切当新视角或动作完成。

批准只覆盖原版主体造型；完整设定包和动作/实机不视为已完成。

## 7. 交接与后续

本轮实际交付是 `art/concepts/characters/monsters/goblin/standard_v1/` 中的原版主源图、五张原生细节参考、manifest 及本文。已确认主体采用原版，尚缺新视角/武器规格/色板等完整设定，也没有透明成品或动作帧；不因为已有正式路径就记为全套完成。

当前不继续补画。将来动作工作需要时再补不可见视角 → 标定比例/色板/握点 → 按需透明加工 → 另立动作任务；不批量重画已清晰的脸/服装。接收区按最新提交同步资源，不能从正式目录存在推断已经实装。
