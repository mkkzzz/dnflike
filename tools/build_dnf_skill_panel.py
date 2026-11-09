"""生成技能面板的数据与素材：175 条技能目录 + 原版技能树 + 面板零件。

数据来源（只读原版库，不改原内容包）：
  assets_local/content/combat_content.json 的 swordman_skills 索引与 SKL 记录
  ClientOnly/SkillShopTree{Sp,Tp}Index.co  原版剑士技能树路径、分支节点和 [next skill]
  Interface2/UI/SkillShop/Skillshop.img    面板零件（标题条、技能格、按钮、说明框、暗化背景）
  Interface/WindowCommon.img               右侧说明板原版九宫格
  SKL 自带 icon 字段                       每个技能的 未选中/选中 两帧图标

输出：
  game_dnf/data/skill_catalog.json              175 条技能 + SP/TP 五职业树布局与前置边
  game_dnf/assets_local/skill_panel/icons/*.png 技能图标（原生像素，不缩放）
  game_dnf/assets_local/skill_panel/parts/*.png 面板零件
  game_dnf/assets_local/skill_panel/manifest.json

名称与说明：优先通过 n_string.lst 解析 `name_ref/basic_explain_ref/explain_ref`
到 `skill/skill.kor.str`；少数 SKL 直接保存显示文本时按同源字节读取。只有
两类来源都缺失时才使用文件名语义兜底。

用法：python tools/build_dnf_skill_panel.py [--library DIR]
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_dnf_combat_assets as B
from audit_dnf_reusable_data import TextResolver
from build_dnf_progression_data import clean, simplify
from dnf_pvf import resolve

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'assets_local/skill_panel'
CATALOG = GAME / 'data/skill_catalog.json'
PACK = GAME / 'assets_local/content/combat_content.json'
RUNTIME = GAME / 'data/skill_runtime.json'

PANEL_BANK = 'Interface2/UI/SkillShop/Skillshop.img'
WINDOW_BANK = 'Interface/WindowCommon.img'
SP_DIGIT_BANK = 'Common/digit/SP/SP.img'
TREE_INDEX_PATHS = {
    'sp': 'clientonly/skillshoptreespindex.co',
    'tp': 'clientonly/skillshoptreetpindex.co',
}
SKILL_WINDOW_UI = 'ui/skill/skillshopwindow.ui'
SKILL_SP_PAGE_UI = 'ui/skill/skillshopsppage.ui'
SKILL_EXPLAIN_UI = 'ui/skill/skillshopexplain.ui'
GRID_X = [0, 47, 94, 141, 188, 235, 282, 329, 376, 423, 470]
GRID_Y = [0, 67, 134, 201, 268, 335, 402, 469, 536, 603, 670]
BRANCH_JOB = {
    'none': 'swordman',
    'weaponmaster': 'weaponmaster',
    'soulbringer': 'soulbringer',
    'berserker': 'berserker',
    'asura': 'asura',
}
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
    'plus': (22, '旧导出重置箭头；语义加号由v3覆盖'),
    'minus': (23, '旧导出重置箭头高亮；语义减号由v3覆盖'),
    'sp_icon': (15, 'SP 数值底条 181×18'),
    'arrow_down': (33, '下拉箭头 17×10'),
    'icon_frame': (45, '技能图标框 107×40'),
    'icon_big': (57, '说明图标框 74×48'),
    'detail_art': (4, '说明板技能图框 166×100'),
    'node_slot': (120, '技能树节点底框 38×38'),
    'node_selected': (147, '技能树节点选中蓝框 38×38'),
    'node_locked': (32, '技能树节点不可用暗红罩 28×28'),
    'scroll_track': (123, '旧导出保留；不是 SP 页 stick-vscroll 的已证实引用，不用于树'),
    'scroll_grabber': (124, '旧导出保留；不是 SP 页 stick-vscroll 的已证实引用，不用于树'),
    'detail_separator': (107, '说明板分隔条 179×37'),
    'tree_footer': (134, '技能窗底栏 800×32'),
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


def resolve_source_text(lib, resolver: TextResolver, path: str) -> dict:
    """Resolve SKL [name]/[basic explain]/[explain] through n_string.lst.

    The localization file is named skill.kor.str but contains the Chinese client
    text encoded as CP950.  Keep the resolved key/table/line provenance instead
    of treating the name as an inferred translation.
    """
    found = lib.raw(path)
    if found is None:
        return {}
    fields = resolver.fields(found[0])

    def entry(tag: str) -> dict:
        values = fields.get(tag) or []
        if not values:
            return {}
        value = values[0]
        text = clean(simplify(str(value.get("text", "")).replace("\r\n", "\n"))).strip()
        return {
            "text": text,
            "table": value.get("table", ""),
            "key": value.get("key", ""),
            "line": value.get("line"),
            "missing": bool(value.get("missing", False)),
        }

    return {
        "name": entry("[name]"),
        "basic_explain": entry("[basic explain]"),
        "explain": entry("[explain]"),
    }


def chinese_name(key: str, sid: int) -> str:
    if key in NAMES:
        return NAMES[key]
    for suffix, tail in (('exp', '·强化'), ('ex', '·强化')):
        if key.endswith(suffix) and key[:-len(suffix)] in NAMES:
            return NAMES[key[:-len(suffix)]] + tail
    return '未开放技能 %d' % sid


def parse_branch(section: dict, skills_by_id: dict[int, dict]) -> dict:
    """Decode one [character job] section and join SKL prerequisites to its nodes."""
    raw_branch = str(section['values'][1])
    job = BRANCH_JOB.get(raw_branch, raw_branch)
    nodes = []
    by_id = {}
    next_edges = []
    for order, node in enumerate(section.get('children', [])):
        fields = {}
        next_skills = []
        for field in node.get('children', []):
            if field['tag'] == '[next skill]':
                next_skills.extend(int(value) for value in field.get('values', []))
            else:
                fields[field['tag']] = field.get('values', [])
        sid = int(fields['[index]'][0])
        x, y = (int(value) for value in fields['[icon pos]'][:2])
        if x not in GRID_X or y not in GRID_Y:
            raise ValueError('skill tree node is outside the measured grid: %s %s %s' % (raw_branch, sid, (x, y)))
        entry = {
            'id': sid,
            'x': x,
            'y': y,
            'grid_x': GRID_X.index(x),
            'grid_y': GRID_Y.index(y),
            'order': order,
            'next_skill': next_skills,
        }
        nodes.append(entry)
        by_id[sid] = entry
        for target in next_skills:
            next_edges.append((sid, target, 'next'))

    edges = []
    seen = set()
    missing = []
    for source, target, relation in next_edges:
        if source not in by_id or target not in by_id:
            missing.append({'from': source, 'to': target, 'relation': relation})
            continue
        if (source, target) not in seen:
            seen.add((source, target))
            edges.append({'from': source, 'to': target, 'sources': [relation]})
    for sid in by_id:
        for requirement in skills_by_id[sid].get('pre_required_skill', []):
            source = int(requirement['id'])
            target = sid
            if source not in by_id:
                missing.append({'from': source, 'to': target, 'relation': 'pre_required_skill'})
                continue
            if (source, target) in seen:
                edge = next(item for item in edges if item['from'] == source and item['to'] == target)
                if 'pre' not in edge['sources']:
                    edge['sources'].append('pre')
            else:
                seen.add((source, target))
                edges.append({'from': source, 'to': target, 'sources': ['pre']})
    return {
        'job': job,
        'source_branch': raw_branch,
        'nodes': nodes,
        'edges': edges,
        'missing_edges': missing,
    }


def build_detail_board(src: B.Source) -> Image.Image:
    """Tile the source 3x3 WindowCommon board to the SkillShopExplain 199x438 area."""
    frames = {}
    for index in range(213, 222):
        image, _ = src.frame(WINDOW_BANK, index)
        frames[index] = image.convert('RGBA')
    width, height = 199, 438
    board = Image.new('RGBA', (width, height), (0, 0, 0, 0))
    board.paste(frames[217].resize((width - 24, height - 25), Image.Resampling.NEAREST), (12, 13))
    for x in range(12, width - 12, 2):
        board.paste(frames[214], (x, 0))
        board.paste(frames[220], (x, height - 12))
    for y in range(13, height - 12, 2):
        board.paste(frames[216], (0, y))
        board.paste(frames[218], (width - 12, y))
    for frame, at in [
        (213, (0, 0)),
        (215, (width - 12, 0)),
        (219, (0, height - 12)),
        (221, (width - 12, height - 12)),
    ]:
        board.paste(frames[frame], at)
    return board


def ui_control_node(src: B.Source, path: str, control_id: str) -> dict:
    """Read a specific source control instead of guessing from IMG contact sheets."""
    script = src.lib.script(path)
    if script is None:
        raise FileNotFoundError(path)

    def walk(nodes):
        for node in nodes:
            values = node.get('values', [])
            if node['tag'] == '[ui controls]' and len(values) > 1 and values[1] == control_id:
                return node
            found = walk(node.get('children', []))
            if found:
                return found
        return None

    node = walk(script['fields'])
    if node is None:
        raise ValueError('Missing UI control: %s #%s' % (path, control_id))
    return node


def ui_control(src: B.Source, path: str, control_id: str) -> list:
    return ui_control_node(src, path, control_id)['values']


def detail_title_layout(src: B.Source) -> dict:
    title = ui_control(src, SKILL_EXPLAIN_UI, '4011')
    if title[0] != '[control]':
        raise ValueError('Unexpected SkillShopExplain title anchor')
    return {'position': title[2:4], 'ui_path': SKILL_EXPLAIN_UI, 'control': '4011'}


def build_ui_revision(src: B.Source, parts: dict) -> dict:
    """Export immutable v2 parts with the exact owning UI references attached."""
    output = OUT / 'v2'
    output.mkdir(parents=True, exist_ok=True)
    references = {
        'dim': (SKILL_WINDOW_UI, '10'),
        'sp_icon': (SKILL_WINDOW_UI, '24'),
        'tree_footer': (SKILL_WINDOW_UI, '8999'),
        'title': (SKILL_EXPLAIN_UI, '22'),
        'detail_art': (SKILL_EXPLAIN_UI, '23'),
        'detail_separator': (SKILL_EXPLAIN_UI, '6000'),
    }
    for key, (path, control_id) in references.items():
        values = ui_control(src, path, control_id)
        if values[0] != '[image]' or values[5].lower() != PANEL_BANK.lower():
            raise ValueError('Unexpected source image control: %s #%s' % (path, control_id))
        frame = int(values[7])
        image, meta = src.frame(PANEL_BANK, frame)
        parts[key] = {
            'file': parts[key]['file'], 'size': list(image.size), 'frame': frame,
            'note': PARTS[key][1], 'offset': [meta['x'], meta['y']],
            'ui_reference': {'path': path, 'control': control_id, 'position': values[2:4]},
        }
    values = ui_control(src, SKILL_WINDOW_UI, '20')
    if values[0] != '[board image]' or values[7:9] != [199, 438] or values[9:18] != list(range(213, 222)):
        raise ValueError('SkillShopWindow detail board reference changed')
    board = build_detail_board(src)
    board.save(output / 'detail_board.png')
    parts['detail_board'] = {
        'file': 'v2/detail_board.png', 'size': list(board.size),
        'frames': values[9:18], 'note': '原版九宫格：顶边高13，底边高12，左右宽12',
        'ui_reference': {'path': SKILL_WINDOW_UI, 'control': '20', 'position': values[2:4]},
    }
    body_node = ui_control_node(src, SKILL_EXPLAIN_UI, '4013')
    body = body_node['values']
    body_options = dict(child['values'] for child in body_node['children'] if child['tag'] == '[int option]')
    line_height = body_options['line height']
    display_marginwidth = body_options['display marginwidth']
    return {
        'evidence': 'UI references parsed from this archived PVF; runtime placement adapters are explicit',
        'detail_title': detail_title_layout(src),
        'detail_body': {'position': body[2:4], 'size': body[6:8], 'line_height': line_height,
                        'display_marginwidth': display_marginwidth,
                        'ui_path': SKILL_EXPLAIN_UI, 'control': '4013'},
        'tree_inset': [24, 8],
        'popup': {'position': [14, 12], 'size': [772, 490],
                  'tree_position': [10, 88], 'tree_size': [540, 342],
                  'detail_position': [562, 35], 'detail_size': [199, 402],
                  'body_content_size': [body[6] + display_marginwidth, 214 // line_height * line_height]},
        'adapters': ['tree inset prevents clipping the x=0 slot border',
                     'Chinese system font and scrollable full skill description',
                     'existing common scrollbar; Skillshop frames 123/124 are not the SP stick-vscroll',
                     'user-requested large popup leaves the two live HUD rows visible; no in-panel shortcut editor',
                     'crop the UI-referenced frame 14 at native pixel size; retain the existing native window border',
                     'Chinese footer commands; ASDFGH legacy indices plus QWERTY in the live HUD'],
    }


def swordman_tree_path(library, index_path: str) -> str:
    index = library.script(index_path)
    if index is None:
        raise FileNotFoundError('Required skill tree index missing: ' + index_path)
    sections = [field['values'] for field in index['fields'] if field['tag'] == '[skill tree]']
    if len(sections) != 1 or len(sections[0]) % 2:
        raise ValueError('Invalid skill tree index: ' + index_path)
    entries = sections[0]
    matches = [path for job, path in zip(entries[::2], entries[1::2]) if job == '[swordman]']
    if len(matches) != 1 or not isinstance(matches[0], str) or not matches[0].lower().endswith('.co'):
        raise ValueError('Swordman skill tree entry missing or ambiguous: ' + index_path)
    return resolve(index_path, matches[0])


def second_growth_fields(library, path: str) -> dict:
    # The panel pack predates these tags. Read the original source fields, keeping
    # the exact order without mapping them to local job or awakening state.
    fields = library.script(path, 'skl')['fields']
    tags = {
        '[second growtype maximum level]': 'second_growtype_max_level',
        '[skill fitness second growtype]': 'fitness_second_growtype',
    }
    result = {}
    for field in fields:
        key = tags.get(field['tag'])
        if key is None:
            continue
        values = field['values']
        if key in result or any(type(value) is not int for value in values):
            raise ValueError(f'Invalid {field["tag"]} in {path}')
        if key == 'second_growtype_max_level' and len(values) != 12:
            raise ValueError(f'Expected six pairs of second-growth caps in {path}')
        result[key] = values
    return result


def tree_source_info(src: B.Source, tree_paths: dict) -> dict:
    result = {}
    for path in [*tree_paths.values(), *TREE_INDEX_PATHS.values(), SKILL_WINDOW_UI,
                 SKILL_SP_PAGE_UI, SKILL_EXPLAIN_UI]:
        found = src.lib.raw(path)
        if found is None:
            raise FileNotFoundError('Required skill tree source missing: ' + path)
        result[path] = found[1]
    return result


def build_rank_controls(src: B.Source, parts: dict) -> None:
    """Native +/- states, audited visually; old 22/23 entries were reset arrows.

    Explain.ui 4000/4001 actually use change/lock sprites (75..82). These
    learning controls are an explicit adapter, not a claim about those controls.
    """
    output = OUT / 'v3'
    output.mkdir(parents=True, exist_ok=True)
    for key, first in [('plus', 59), ('minus', 62)]:
        for offset, state in enumerate(['', '_hover', '_pressed']):
            image, meta = src.frame(PANEL_BANK, first + offset)
            if image.size != (18, 18):
                raise ValueError('Unexpected skill rank button size')
            name = key + state
            target = output / (name + '.png')
            if target.exists():
                from PIL import Image
                if Image.open(target).convert('RGBA').tobytes() != image.convert('RGBA').tobytes():
                    raise ValueError('Refusing to overwrite immutable v3 asset: ' + name)
            else:
                image.save(target)
            parts[name] = {
                'file': 'v3/' + target.name, 'size': list(image.size),
                'frame': first + offset, 'offset': [meta['x'], meta['y']],
                'note': 'Original +/- sprite; learning placement is E-ADAPT, not Explain 4000/4001',
            }


def build_sp_digits(src: B.Source, parts: dict) -> None:
    """Pack the ten original digit crops with no scaling or recoloring."""
    node = ui_control_node(src, SKILL_WINDOW_UI, '2000')
    control = node['values']
    parent_id = next(child['values'][0] for child in node['children'] if child['tag'] == '[parent]')
    if (control[0] != '[numberset]' or control[5].lower() != SP_DIGIT_BANK.lower()
            or parent_id != '24' or control[7] != 0 or control[10] != 1):
        raise ValueError('Unexpected SP digit control')
    parent = ui_control(src, SKILL_WINDOW_UI, parent_id)
    _, parent_meta = src.frame(parent[5], parent[7])
    frames = list(range(1, 11))
    digits = [src.frame(SP_DIGIT_BANK, frame) for frame in frames]
    glyphs = [image.convert('RGBA') for image, _ in digits]
    atlas = Image.new('RGBA', (sum(glyph.width for glyph in glyphs), max(glyph.height for glyph in glyphs)))
    regions = []
    x = 0
    for glyph in glyphs:
        atlas.paste(glyph, (x, 0))
        regions.append([x, 0, glyph.width, glyph.height])
        x += glyph.width
    target = OUT / 'v4/sp_digits.png'
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        with Image.open(target) as previous:
            if previous.size != atlas.size or previous.convert('RGBA').tobytes() != atlas.tobytes():
                raise ValueError('SP digit art differs from the existing revision')
    else:
        atlas.save(target)
    parts['sp_digits'] = {
        'file': 'v4/sp_digits.png', 'size': list(atlas.size), 'frames': frames,
        'regions': regions, 'bank': SP_DIGIT_BANK,
        'bank_sha256': src.sources['sprite/' + SP_DIGIT_BANK.lower()],
        'ui_reference': {'path': SKILL_WINDOW_UI, 'control': '2000',
                         'parent': parent_id, 'position': control[2:4], 'parameters': control[6:]},
        # CNNumberSet measures canvas width + spacing (0x11B2275/0x11B2A16).
        # This popup mounts the cropped bar, so express each crop origin relative to it.
        'digit_advances': [meta['cw'] + control[9] for _, meta in digits],
        'glyph_offsets': [[meta['x'] - parent_meta['x'], meta['y'] - parent_meta['y']]
                          for _, meta in digits],
        'max_digits': control[8],
    }


def build_detail_scroll(src: B.Source, parts: dict) -> None:
    """Pack the WindowCommon pieces actually drawn by Explain #4013."""
    node = ui_control_node(src, SKILL_EXPLAIN_UI, '4013')
    options = dict(child['values'] for child in node['children'] if child['tag'] == '[int option]')
    if node['values'][0] != '[hyperlinklabel]' or node['values'][11] != 1:
        raise ValueError('Unexpected Explain scrollbar control')
    # 0x11F0CC0 binds the arrows and track. 0x11CAA70 uses the visible thumb caps and strip.
    states = {
        'decrement': [16], 'decrement_highlight': [17], 'decrement_pressed': [18],
        'increment': [22], 'increment_highlight': [23], 'increment_pressed': [24],
        'scroll': [28], 'grabber': [184, 185, 186], 'grabber_highlight': [187, 188, 189],
    }
    frames = {index: src.frame(WINDOW_BANK, index) for indexes in states.values() for index in indexes}
    # The track starts at the unadjusted control edge, 5 px past the text wrap edge.
    anchor = -options['display marginwidth']
    width = max(anchor + meta['x'] + image.getbbox()[2] for image, meta in frames.values())
    arrow_height = frames[16][1]['ch']
    strips = {}
    for state, indexes in states.items():
        height = arrow_height if state.startswith(('decrement', 'increment')) else sum(
            frames[index][0].height for index in indexes)
        strip = Image.new('RGBA', (width, height))
        y = 0
        for index in indexes:
            image, meta = frames[index]
            bounds = image.getbbox()
            strip.paste(image.crop(bounds), (anchor + meta['x'] + bounds[0], y + meta['y'] + bounds[1]))
            y += image.height
        strips[state] = strip
    atlas = Image.new('RGBA', (width, sum(strip.height for strip in strips.values())))
    regions = {}
    y = 0
    for state, strip in strips.items():
        atlas.paste(strip, (0, y))
        regions[state] = [0, y, width, strip.height]
        y += strip.height
    target = OUT / 'v5/detail_scroll.png'
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        with Image.open(target) as previous:
            if previous.size != atlas.size or previous.convert('RGBA').tobytes() != atlas.tobytes():
                raise ValueError('Explain scrollbar art differs from the existing revision')
    else:
        atlas.save(target)
    parts['detail_scroll'] = {
        'file': 'v5/detail_scroll.png', 'size': list(atlas.size), 'bank': WINDOW_BANK,
        'bank_sha256': src.sources['sprite/' + WINDOW_BANK.lower()],
        'ui_reference': {'path': SKILL_EXPLAIN_UI, 'control': '4013'},
        'frames': states, 'regions': regions, 'thumb_caps': [frames[184][0].height, frames[186][0].height],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=None)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--rank-controls-only', action='store_true',
                        help='Only export the audited +/- revision and update its manifest entries')
    mode.add_argument('--sp-digits-only', action='store_true',
                      help='Only export the original SP digits and update their manifest entry')
    mode.add_argument('--detail-scroll-only', action='store_true',
                      help='Only export the original Explain scrollbar and update its manifest entry')
    args = parser.parse_args()
    if args.rank_controls_only:
        manifest_path = OUT / 'manifest.json'
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        source = B.Source(args.library)
        build_rank_controls(source, manifest['parts'])
        bank_hash = source.sources['sprite/' + PANEL_BANK.lower()]
        if bank_hash != manifest['source']['bank_sha256']:
            raise ValueError('Skillshop bank version differs from the manifest')
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
        print('[SKILL_PANEL] audited rank controls: 6 native 18x18 sprites')
        return 0
    if args.sp_digits_only:
        manifest_path = OUT / 'manifest.json'
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        source = B.Source(args.library)
        if source.lib.raw(SKILL_WINDOW_UI)[1] != manifest['source']['tree_sources'][SKILL_WINDOW_UI]:
            raise ValueError('Skillshop window version differs from the manifest')
        build_sp_digits(source, manifest['parts'])
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
        print('[SKILL_PANEL] original SP digits: 10 glyphs')
        return 0
    if args.detail_scroll_only:
        manifest_path = OUT / 'manifest.json'
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        source = B.Source(args.library)
        if source.lib.raw(SKILL_EXPLAIN_UI)[1] != manifest['source']['tree_sources'][SKILL_EXPLAIN_UI]:
            raise ValueError('Skillshop Explain version differs from the manifest')
        build_detail_scroll(source, manifest['parts'])
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
        print('[SKILL_PANEL] original Explain scrollbar: WindowCommon arrows, track and thumb')
        return 0
    pack = json.loads(PACK.read_text(encoding='utf-8'))
    runtime = json.loads(RUNTIME.read_text(encoding='utf-8'))
    combat = json.loads((GAME / 'data/combat.json').read_text(encoding='utf-8'))
    index = pack['indexes']['swordman_skills']
    implemented = {}          # 原版路径 → 本地招式 id
    for move_id, move in combat['moves'].items():
        if move.get('skill'):
            implemented[move['skill'].lower()] = move_id
    local_ids = {
        str(definition['source_path']).lower(): local
        for local, definition in runtime['skills'].items()
        if definition.get('source_path', '')
    }
    implemented.update({
        str(definition['skill']).lower(): local
        for local, definition in runtime['moves'].items()
        if definition.get('skill', '')
    })

    src = B.Source(args.library)
    tree_paths = {page: swordman_tree_path(src.lib, index_path)
                  for page, index_path in TREE_INDEX_PATHS.items()}
    tree_sources = tree_source_info(src, tree_paths)
    resolver = TextResolver(src.lib)
    (OUT / 'icons').mkdir(parents=True, exist_ok=True)
    (OUT / 'parts').mkdir(parents=True, exist_ok=True)
    parts = {}
    for key, (frame, note) in PARTS.items():
        image, meta = src.frame(PANEL_BANK, frame)
        image.save(OUT / 'parts' / (key + '.png'))
        parts[key] = {'file': 'parts/%s.png' % key, 'size': list(image.size), 'frame': frame, 'note': note}
    ui_layout = build_ui_revision(src, parts)
    build_rank_controls(src, parts)
    build_sp_digits(src, parts)
    build_detail_scroll(src, parts)

    skills = []
    missing_icon = []
    for sid, path in sorted(index.items(), key=lambda kv: int(kv[0])):
        record = pack['records'].get(path.lower())
        if not record:
            continue
        decoded = record['decoded']
        key = path.rsplit('/', 1)[-1].removesuffix('.skl')
        localized = resolve_source_text(src.lib, resolver, path)
        localized_name = str(localized.get("name", {}).get("text", ""))
        basic_explain = str(localized.get("basic_explain", {}).get("text", ""))
        explain = str(localized.get("explain", {}).get("text", ""))
        name = localized_name or chinese_name(key, int(sid))
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
        localization_refs = {
            tag: {key: value for key, value in entry.items() if key != "text"}
            for tag, entry in localized.items()
        }
        skills.append({
            'id': int(sid), 'key': key, 'path': path, 'name': name,
            'basic_explain': basic_explain, 'explain': explain,
            'command': decoded.get('command') or [],
            'type': (decoded.get('type') or [''])[0], 'skill_class': decoded.get('skill_class'),
            'max_level': decoded.get('max_level'),
            'required_level': decoded.get('required_level'),
            'required_level_range': decoded.get('required_level_range'),
            'growtype_max_level': decoded.get('growtype_max_level'),
            'fitness_growtype': decoded.get('fitness_growtype'),
            **second_growth_fields(src.lib, path),
            'purchase_cost': (decoded.get('purchase_cost') or [None])[0],
            'pre_required_skill': pre,
            'icon': normal, 'icon_selected': selected,
            'implemented': implemented.get(path.lower(), ''),
            'local_id': local_ids.get(path.lower(), ''),
            'evidence': ('SKL decoded E-PARSE; name/explain resolved through n_string.lst -> skill/skill.kor.str'
                         if localized_name else
                         'SKL decoded E-PARSE; localization entry missing, name fallback is E-ADAPT'),
            'localization': localization_refs,
        })
    skills_by_id = {skill['id']: skill for skill in skills}
    trees = {
        page: [parse_branch(section, skills_by_id) for section in src.lib.script(path)['fields']]
        for page, path in tree_paths.items()
    }
    total = sum(len((pack['records'][p.lower()]['decoded'].get('level_info') or [])) for p in index.values()
                if pack['records'].get(p.lower()))
    manifest = {
        'schema': 'dnf_skill_panel/2',
        'source': {'bank': PANEL_BANK, 'pack': 'assets_local/content/combat_content.json',
                   'icon_field': 'SKL [icon]', 'tree': tree_paths['sp'],
                   'tree_sha256': tree_sources[tree_paths['sp']],
                   'bank_sha256': src.sources.get('sprite/' + PANEL_BANK.lower()),
                   'window_bank_sha256': src.sources.get('sprite/' + WINDOW_BANK.lower()),
                   'tree_sources': tree_sources,
                   'exporter': 'tools/build_dnf_skill_panel.py'},
        'parts': parts,
        'ui_layout': ui_layout,
        'icons': len(skills) - len(missing_icon),
        'missing_icons': missing_icon,
        'tree_counts': {branch['source_branch']: len(branch['nodes']) for branch in trees['sp']},
        'tree_edges': {branch['source_branch']: len(branch['edges']) for branch in trees['sp']},
    }
    (OUT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    CATALOG.write_text(json.dumps({
        'schema': 'dnf_skill_catalog/3',
        'note': ('names/explains from SKL localization references; requirements and edges from SKL fields; '
                 'tree branches and node coordinates from the SP and TP index targets'),
        'trees': trees,
        'skills': skills,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    runtime_descriptions = {}
    for skill in skills:
        local_id = skill['local_id']
        if not local_id:
            continue
        runtime_descriptions[local_id] = {
            'name': skill['name'],
            'brief': skill['basic_explain'] or skill['explain'] or '原版说明暂缺',
            'detail': skill['explain'] or skill['basic_explain'] or '原版说明暂缺',
            'source_id': skill['id'],
            'source_path': skill['path'],
            'evidence': skill['evidence'],
        }
    descriptions = (
        "extends RefCounted\n"
        "## Generated by tools/build_dnf_skill_panel.py from SKL localization records.\n"
        "## Do not hand-edit names/descriptions here; regenerate from the source archive.\n"
        "const SKILLS := "
        + json.dumps(runtime_descriptions, ensure_ascii=False, indent=1)
        + "\n"
    )
    (GAME / 'items/skill_descriptions.gd').write_text(descriptions, encoding='utf-8')
    print('[SKILL_PANEL] skills=%d localized=%d parts=%d icons=%d missing=%d level_rows=%d '
          'tree_nodes=%s tree_edges=%s'
          % (len(skills), sum(bool(s['localization'].get('name')) for s in skills),
             len(parts), manifest['icons'], len(missing_icon), total,
             manifest['tree_counts'], manifest['tree_edges']))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
