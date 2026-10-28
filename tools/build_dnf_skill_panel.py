"""生成技能面板的数据与素材：175 条技能目录 + 原版技能图标 + 面板零件。

数据来源（只读原版库，不改原内容包）：
  assets_local/content/combat_content.json 的 swordman_skills 索引与 SKL 记录
  Interface2/UI/SkillShop/Skillshop.img    面板零件（标题条、技能格、按钮、说明框、暗化背景）
  SKL 自带 icon 字段                       每个技能的 未选中/选中 两帧图标

输出：
  game_dnf/data/skill_catalog.json              175 条：名称、类型、等级/职业/前置要求、成本、图标键
  game_dnf/assets_local/skill_panel/icons/*.png 技能图标（原生像素，不缩放）
  game_dnf/assets_local/skill_panel/parts/*.png 面板零件
  game_dnf/assets_local/skill_panel/manifest.json

名称来源：原版本地化文本不在备份库内（name_ref 只解到 name_17730 这类占位键），
中文名按 SKL 文件名语义整理，标注 E-ADAPT；`*ex/*exp` 规则化为“<本体>·强化”。

用法：python tools/build_dnf_skill_panel.py [--library DIR]
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_dnf_combat_assets as B

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'assets_local/skill_panel'
CATALOG = GAME / 'data/skill_catalog.json'
PACK = GAME / 'assets_local/content/combat_content.json'

PANEL_BANK = 'Interface2/UI/SkillShop/Skillshop.img'
# 面板零件（帧号来自 Skillshop.img 实测帧表；用途为看图确认，见报告）
PARTS = {
    'dim': (14, '全屏暗化背景 800×600'),
    'title': (3, '标题条 237×30'),
    'cell': (32, '技能格 28×28'),
    'cell_plain': (5, '技能底格 30×30'),
    'frame_selected': (4, '选中大图框 166×100'),
    'desc_box': (19, '说明底框 230×60'),
    'button': (20, '按钮 108×30'),
    'button_hot': (21, '按钮高亮 106×28'),
    'button_wide': (30, '宽按钮 180×30'),
    'button_wide_hot': (31, '宽按钮高亮 180×30'),
    'plus': (22, '加号 19×19'),
    'minus': (23, '减号 19×19'),
    'sp_icon': (15, 'SP 图标 19×19'),
    'arrow_down': (33, '下拉箭头 17×10'),
    'icon_frame': (45, '技能图标框 107×40'),
    'icon_big': (57, '说明图标框 74×48'),
}

# 技能文件名 → 中文名（E-ADAPT：原版本地化文本缺失，按语义整理，待使用者校对）
NAMES = {
    'guard': '格挡', 'reflectguard': '反击格挡', 'autoguard': '自动格挡',
    'lightswordmastery': '光剑精通', 'shortswordmastery': '短剑精通', 'blademastery': '太刀精通',
    'heavyswordmastery': '巨剑精通', 'bluntmastery': '钝器精通', 'weaponmasteryup': '武器精通强化',
    'hardattack': '重击', 'hardattackcharge': '蓄力重击', 'hitback': '后跳',
    'tripleslash': '三段斩', 'momentaryslash': '拔刀斩', 'dashattackmultihit': '冲刺连斩',
    'ashenfork': '灰烬之叉', 'jumpattackmulti': '空中连斩', 'ghoststep': '鬼影步',
    'pinchpowerup': '抓头强化', 'normalwave': '波动剑', 'icewave': '冰刃·波动剑',
    'firewave': '爆炎·波动剑', 'sacrifice': '血气之刃', 'bloodblast': '血气爆发',
    'khazan': '刀魂之卡赞', 'grabblastblood': '抓头爆破', 'releasewave': '释放波动',
    'diehard': '血气唤醒', 'ghostpowerup': '鬼力强化', 'saya': '剑鞘', 'fastequip': '快速换装',
    'overdrive': '超频', 'durabilityup': '耐久强化', 'reckless': '狂暴化',
    'bremen': '侵蚀之普戾蒙', 'tombstonerain': '崩山击', 'upperslash': '上挑',
    'wavemark': '波动标记', 'backstepcutter': '后跳斩', 'grandwave': '波动爆发',
    'grandwavecharge': '蓄力波动爆发', 'dotarea': '出血领域', 'mindflash': '心剑',
    'senseviolenttemper': '狂暴感知', 'shockwavearea': '冲击波领域', 'vaneslash': '剑气斩',
    'ghoststepslash': '鬼影步斩', 'standalonewave': '独立波动', 'bloodyvigorous': '血气旺盛',
    'gorecross': '十字斩', 'hopsmash': '跃击', 'weaponcombo': '武器连击',
    'chargecrash': '冲撞', 'rapidmoveslash': '疾影斩', 'illusionslash': '幻影剑',
    'wavespinarea': '旋波斩', 'epidemicrasa': '瘟疫之罗刹', 'frenzy': '暴走',
    'moonlightslash': '月光斩', 'bloodyrave': '嗜血', 'moonlightslashfull': '满月斩',
    'outragebreak': '怒气爆发', 'kalla': '卡拉斯', 'keiga': '鬼牙', 'hellbenter': '地狱突刺',
    'hundredsword': '幻影剑舞', 'blache': '血剑', 'waveeye': '波动眼', 'darkaura': '暗黑光环',
    'ghostsidewind': '鬼影侧风', 'triplestab': '三段刺', 'backstep': '后跳',
    'flowmind': '心流', 'flowmindone': '心流·一', 'flowmindtwo': '心流·二', 'flowmindthree': '心流·三',
    'flowmindpowerup': '心流强化', 'basicattackup': '基础攻击强化', 'jumppowerup': '跳跃力强化',
    'magicalattackup': '魔法攻击强化', 'throwmastery': '投掷精通', 'disjointitem': '分解',
    'disjointitemdark': '暗黑分解', 'superarmoroncast': '施放霸体', 'quickstanding': '快速起身',
    'enchant': '附魔', 'dollmaking': '人偶制作', 'alchemy': '炼金', 'opendisjointshop': '分解商店',
    'basichpmaxup': '生命上限强化', 'conversion': '转换', 'statusup': '状态强化',
    'experienceup': '经验强化', 'physicalcriticalhitup': '物理暴击强化', 'magicalcriticalhitup': '魔法暴击强化',
    'physicalbackattackcritical': '物理背击暴击', 'magicalbackattackcritical': '魔法背击暴击',
    'darkfriendship': '暗黑契约', 'darktoleranceup': '暗黑抗性强化',
    'armormasterycloth': '布甲精通', 'armormasteryleather': '皮甲精通', 'armormasterylight': '轻甲精通',
    'armormasteryheavy': '重甲精通', 'armormasteryplate': '板甲精通',
    'armormasteryheavybk': '重甲精通', 'armormasteryplatewave': '板甲精通',
    'armormasteryclothsb': '布甲精通', 'armormasterylightwm': '轻甲精通',
    'compoundcraft': '制作·工艺', 'compoundweaving': '制作·织物', 'compoundmachine': '制作·机械',
    'compoundchemistry': '制作·化学', 'jumpattackhighfast': '高空速降斩',
}


def chinese_name(key: str, sid: int) -> str:
    if key in NAMES:
        return NAMES[key]
    for suffix, tail in (('exp', '·强化'), ('ex', '·强化')):
        if key.endswith(suffix) and key[:-len(suffix)] in NAMES:
            return NAMES[key[:-len(suffix)]] + tail
    return '未开放技能 %d' % sid


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=None)
    args = parser.parse_args()
    pack = json.loads(PACK.read_text(encoding='utf-8'))
    numbers = json.loads((GAME / 'data/numbers.json').read_text(encoding='utf-8'))
    combat = json.loads((GAME / 'data/combat.json').read_text(encoding='utf-8'))
    index = pack['indexes']['swordman_skills']
    implemented = {}          # 原版路径 → 本地招式 id
    for move_id, move in combat['moves'].items():
        if move.get('skill'):
            implemented[move['skill'].lower()] = move_id
    local_ids = {v['path'].lower(): k for k, v in numbers['skills'].items() if v.get('path')}
    for local, definition in numbers['skills'].items():
        if not definition.get('path'):
            local_ids.setdefault('skill/swordman/%s.skl' % local, local)

    src = B.Source(args.library)
    (OUT / 'icons').mkdir(parents=True, exist_ok=True)
    (OUT / 'parts').mkdir(parents=True, exist_ok=True)
    parts = {}
    for key, (frame, note) in PARTS.items():
        image, meta = src.frame(PANEL_BANK, frame)
        image.save(OUT / 'parts' / (key + '.png'))
        parts[key] = {'file': 'parts/%s.png' % key, 'size': list(image.size), 'frame': frame, 'note': note}

    skills = []
    missing_icon = []
    for sid, path in sorted(index.items(), key=lambda kv: int(kv[0])):
        record = pack['records'].get(path.lower())
        if not record:
            continue
        decoded = record['decoded']
        key = path.rsplit('/', 1)[-1].removesuffix('.skl')
        icon = decoded.get('icon') or []
        normal = selected = ''
        if len(icon) >= 4:
            try:
                image, _ = src.frame(str(icon[0]), int(icon[1]))
                image.save(OUT / 'icons' / (key + '.png'))
                normal = 'icons/%s.png' % key
            except Exception:
                missing_icon.append(key)
            try:
                image, _ = src.frame(str(icon[2]), int(icon[3]))
                image.save(OUT / 'icons' / (key + '_on.png'))
                selected = 'icons/%s_on.png' % key
            except Exception:
                pass
        pre = []
        raw_pre = decoded.get('pre_required_skill') or []
        for i in range(0, len(raw_pre) - 1, 2):
            pre.append({'id': int(raw_pre[i]), 'level': int(raw_pre[i + 1])})
        skills.append({
            'id': int(sid), 'key': key, 'path': path, 'name': chinese_name(key, int(sid)),
            'type': (decoded.get('type') or [''])[0], 'skill_class': decoded.get('skill_class'),
            'max_level': decoded.get('max_level'),
            'required_level': decoded.get('required_level'),
            'required_level_range': decoded.get('required_level_range'),
            'growtype_max_level': decoded.get('growtype_max_level'),
            'fitness_growtype': decoded.get('fitness_growtype'),
            'purchase_cost': (decoded.get('purchase_cost') or [None])[0],
            'pre_required_skill': pre,
            'icon': normal, 'icon_selected': selected,
            'implemented': implemented.get(path.lower(), ''),
            'local_id': local_ids.get(path.lower(), ''),
            'evidence': 'SKL decoded E-PARSE; 中文名为 E-ADAPT（原版本地化文本缺失）',
        })
    total = sum(len((pack['records'][p.lower()]['decoded'].get('level_info') or [])) for p in index.values()
                if pack['records'].get(p.lower()))
    manifest = {
        'schema': 'dnf_skill_panel/1',
        'source': {'bank': PANEL_BANK, 'pack': 'assets_local/content/combat_content.json',
                   'icon_field': 'SKL [icon]', 'exporter': 'tools/build_dnf_skill_panel.py'},
        'parts': parts,
        'icons': len(skills) - len(missing_icon),
        'missing_icons': missing_icon,
    }
    (OUT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    CATALOG.write_text(json.dumps({'schema': 'dnf_skill_catalog/1', 'note': 'E-ADAPT 名称；原版要求数据 E-PARSE',
                                   'skills': skills}, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print('[SKILL_PANEL] skills=%d parts=%d icons=%d missing=%d level_rows=%d'
          % (len(skills), len(parts), manifest['icons'], len(missing_icon), total))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
