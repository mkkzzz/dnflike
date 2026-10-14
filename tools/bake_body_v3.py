#!/usr/bin/env python3
"""Bake weaponless hand-painted body keys and calibrated runtime weapon sockets.

The tool never invents frames: each baked frame identifies a reviewed source
pose. One anatomical scale is used per source sheet, with root and hand points
reviewed in source pixels. Run --inspect to see connected silhouettes.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from bake_demo_art import components

ROOT = Path(__file__).resolve().parents[1]
SHEETS = ROOT / 'art' / 'sheets' / 'v3'
OUT = ROOT / 'game' / 'assets' / 'actors_v3'

FRAME_W, FRAME_H, AX, AY = 320, 248, 144, 230

# Source-space landmarks were reviewed against the red gripping glove and the
# pelvis/ground plane. A single scale per sheet preserves a common anatomy;
# in-air roots use a virtual ground baseline instead of chasing the lowest boot.
# Each landmark is (root_x, root_y, grip_x, grip_y, blade_angle_degrees, layer).
CALIBRATION = {
    'base': {'standing_h': 324, 'points': [
        (151,333,94,183,35,'front'), (478,333,435,187,35,'front'),
        (798,330,856,108,-135,'front'), (1129,323,1038,187,145,'back'),
        (190,622,118,442,145,'back'), (490,627,441,457,145,'back'),
        (816,619,757,455,145,'back'), (1120,627,1091,486,145,'back'),
        (168,932,62,699,-165,'back'), (482,930,560,765,0,'front'),
        (795,940,881,663,-45,'front'), (1118,940,1127,675,65,'front'),
        (174,1230,109,1011,145,'back'), (466,1233,441,1102,35,'front'),
        (790,1223,783,1207,5,'front'), (1112,1222,1106,1204,-75,'front'),
    ]},
    'locomotion': {'standing_h': 326, 'points': [
        (178,342,120,200,35,'front'), (493,342,452,200,35,'front'),
        (787,342,754,210,35,'front'), (1117,341,1080,210,35,'front'),
        (179,672,120,533,35,'front'), (494,672,450,527,35,'front'),
        (798,672,749,522,35,'front'), (1120,670,1080,530,35,'front'),
        (180,948,101,769,145,'back'), (475,948,424,774,145,'back'),
        (797,948,767,829,145,'back'), (1120,948,1050,767,145,'back'),
        (180,1230,101,1042,145,'back'), (475,1230,425,1075,145,'back'),
        (797,1230,763,1090,145,'back'), (1120,1230,1064,1060,145,'back'),
    ]},
    'walk': {'standing_h': 381, 'points': [
        (208,403,178,222,35,'front'), (521,406,493,222,35,'front'),
        (804,406,794,218,35,'front'), (1130,406,1124,222,35,'front'),
        (213,810,168,638,35,'front'), (523,814,489,642,35,'front'),
        (805,814,794,634,35,'front'), (1140,813,1126,637,35,'front'),
    ]},
    'combo12': {'standing_h': 325, 'points': [
        (169,334,103,190,35,'front'), (465,334,402,64,-155,'back'),
        (775,334,748,74,-160,'back'), (1100,334,1231,144,0,'front'),
        (199,640,327,500,10,'front'), (527,645,625,528,65,'front'),
        (820,645,780,508,45,'front'), (1113,647,1045,507,35,'front'),
        (174,940,104,811,35,'front'), (479,936,531,875,35,'front'),
        (806,937,891,889,60,'front'), (1114,937,1222,693,-50,'front'),
        (178,1245,247,958,-85,'front'), (500,1245,582,971,-50,'front'),
        (801,1242,800,1063,-10,'front'), (1112,1247,1046,1113,35,'front'),
    ]},
    'combo3upper': {'standing_h': 334, 'points': [
        (173,348,137,179,35,'front'), (495,348,464,75,-150,'back'),
        (809,348,829,25,-100,'front'), (1144,350,1204,259,35,'front'),
        (202,673,289,577,65,'front'), (541,673,620,589,75,'front'),
        (831,672,849,472,-15,'front'), (1121,675,1081,509,35,'front'),
        (192,963,245,881,35,'front'), (486,958,549,899,55,'front'),
        (817,973,903,816,20,'front'), (1138,976,1224,688,-55,'front'),
        (185,1240,224,958,-100,'front'), (492,1260,501,964,-105,'front'),
        (809,1243,763,1075,-20,'front'), (1124,1250,1085,1097,35,'front'),
    ]},
    'airdash': {'standing_h': 311, 'points': [
        (195,345,121,199,145,'back'), (479,350,428,108,-150,'back'),
        (786,350,791,20,-105,'front'), (1124,369,1221,280,45,'front'),
        (195,670,244,590,65,'front'), (497,679,545,601,80,'front'),
        (802,664,744,459,145,'back'), (1120,666,1061,525,35,'front'),
        (183,941,84,759,145,'back'), (498,938,519,743,-160,'back'),
        (799,938,745,730,-170,'back'), (1130,938,1242,758,0,'front'),
        (217,1217,274,1106,35,'front'), (506,1224,514,1155,65,'front'),
        (794,1234,784,1048,-15,'front'), (1109,1240,1064,1113,35,'front'),
    ]},
}


def refs(sheet: str, start: int, end: int) -> list[tuple[str,int]]:
    return [(sheet, i) for i in range(start, end)]


SWING_PHASES = {'windup': [0, 1, 2], 'active': [3, 4], 'recovery': [5, 6, 7]}

ACTION_SPECS = {
    'idle': (refs('base',0,2), [24,24], True, {}),
    'walk': (refs('walk',0,8), [5]*8, True, {}),
    'run': (refs('locomotion',8,16), [3]*8, True, {}),
    'attack1': (refs('combo12',0,8), [3,3,2,2,2,3,3,4], False, SWING_PHASES),
    'attack2': (refs('combo12',8,16), [3,3,2,2,2,3,3,4], False, SWING_PHASES),
    'attack3': (refs('combo3upper',0,8), [4,4,3,2,3,4,4,5], False, SWING_PHASES),
    'upper': (refs('combo3upper',8,16), [3,3,2,2,3,4,3,4], False, SWING_PHASES),
    'air_attack': (refs('airdash',0,8), [3,3,2,2,3,4,4,5], False, SWING_PHASES),
    'dash_attack': (refs('airdash',8,16), [3,3,2,2,3,3,4,5], False, SWING_PHASES),
    'jump': ([('base',3),('base',12)], [4,12], False, {}),
    'air': ([('base',12)], [12], True, {}),
    'back_dash': ([('base',3),('base',12),('base',3),('base',1)], [3,8,3,4], False, {}),
    'guard': ([('base',2)], [12], True, {}),
    'hit': ([('base',13),('base',3),('base',1)], [7,4,5], False, {}),
    'down': ([('base',13),('base',14)], [5,24], False, {}),
    'getup': ([('base',14),('base',15),('base',3),('base',1)], [4,7,4,5], False, {}),
    'blood_rage': ([('base',2),('base',8),('base',2),('base',1)], [6,4,4,6], False, {}),
    'quick_draw': (refs('combo12',0,8), [6,8,6,2,2,4,4,5], False, SWING_PHASES),
    'rage_slash': (refs('combo12',8,16)+refs('combo3upper',0,8),
                   [3,3,2,2,2,3,3,3,3,3,2,2,2,4,5,6], False,
                   {'windup':[0,1,2], 'active':[3,4,11,12], 'recovery':[13,14,15]}),
    'thrust': ([('combo12',0),('combo12',1),('combo12',3),('combo12',4),
                ('combo12',6),('combo12',2),('combo12',3),('combo12',4),
                ('combo12',6),('combo12',2),('combo12',3),('combo12',4),
                ('combo12',5),('combo12',6),('combo12',7)],
               [3,3,2,2,3,3,2,2,3,3,2,2,5,5,6], False,
               {'windup':[0,1], 'active':[2,3,6,7,10,11], 'recovery':[12,13,14]}),
}


def extract(path: Path, expected: int) -> tuple[list[Image.Image], list[dict]]:
    im = Image.open(path).convert('RGBA')
    rgba = np.asarray(im)
    if rgba[...,3].min()!=0 or rgba[...,3].max()!=255:
        raise ValueError(f'{path.name}: expected real transparent RGBA source alpha')
    # A 25%-alpha core threshold rejects a faint generation bridge between the
    # ready boot and uppercut fist in combo3upper without cutting either pose.
    labels, stats = components(rgba[..., 3] >= 64)
    bodies = [s for s in stats if s['area'] > 4000]
    if len(bodies) != expected:
        raise ValueError(f'{path.name}: expected {expected} silhouettes, got {len(bodies)}')
    # Rows are ranked rather than hard-cut so modest generated layout variation
    # never crops a hand, coat tip or boot at a nominal grid boundary.
    bodies.sort(key=lambda s: s['sy'] / s['area'])
    order = []
    for start in range(0, expected, 4):
        order += sorted(bodies[start:start + 4], key=lambda s: s['sx'] / s['area'])
    poses, report = [], []
    for i, s in enumerate(order):
        box = (max(0, s['x0'] - 3), max(0, s['y0'] - 3),
               min(im.width, s['x1'] + 3), min(im.height, s['y1'] + 3))
        x0, y0, x1, y1 = box
        member = Image.fromarray((labels[y0:y1, x0:x1] == s['label']).astype(np.uint8) * 255)
        support = np.asarray(member.filter(ImageFilter.MaxFilter(5))) > 0
        part = rgba[y0:y1, x0:x1].copy()
        part[..., 3] *= support
        poses.append(Image.fromarray(part))
        report.append({'cell': i, 'bbox': list(box), 'area': s['area'],
                       'centroid': [round(s['sx'] / s['area']), round(s['sy'] / s['area'])]})
    return poses, report


def inspect() -> None:
    for path in SHEETS.glob('body_*.png'):
        expected = 8 if path.stem == 'body_walk' else 16
        _, report = extract(path, expected)
        print(path.name, Image.open(path).size)
        print(json.dumps(report, indent=None))


def draw_socket(im: Image.Image, socket: dict, origin: tuple[int,int], label: str) -> None:
    d = ImageDraw.Draw(im)
    ox, oy = origin
    hx = ox + socket['hand'][0]
    hy = oy + socket['hand'][1]
    angle = math.radians(socket['angle'])
    tx, ty = hx + math.cos(angle) * 110, hy + math.sin(angle) * 110
    d.line((hx,hy,tx,ty), fill='#97c9df', width=2)
    d.line((hx-4,hy,hx+4,hy), fill='#ffd46a', width=2)
    d.line((hx,hy-4,hx,hy+4), fill='#ffd46a', width=2)
    d.ellipse((hx-6,hy-6,hx+6,hy+6), outline='#ffd46a', width=1)
    d.line((ox-5,oy,ox+5,oy), fill='#71d895', width=2)
    d.line((ox,oy-5,ox,oy+5), fill='#71d895', width=2)
    d.text((ox-AX+8,oy-AY+8), label, fill='#ebedf4')


def bake() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT/'player').mkdir(exist_ok=True)
    frames, sockets, reports = {}, {}, {}
    for sheet, settings in CALIBRATION.items():
        poses, report = extract(SHEETS/f'body_{sheet}.png', len(settings['points']))
        reports[sheet] = report
        scale = 190.0 / settings['standing_h']
        for cell, (pose, info, point) in enumerate(zip(poses, report, settings['points'])):
            rx,ry,hx,hy,angle,layer = point
            x0,y0,_,_ = info['bbox']
            resized = pose.resize((round(pose.width*scale), round(pose.height*scale)), Image.Resampling.LANCZOS)
            dst = (AX+round((x0-rx)*scale), AY+round((y0-ry)*scale))
            if dst[0]<0 or dst[1]<0 or dst[0]+resized.width>FRAME_W or dst[1]+resized.height>FRAME_H:
                raise ValueError(f'{sheet}:{cell} cropped by frame canvas {dst} {resized.size}')
            frame = Image.new('RGBA', (FRAME_W,FRAME_H))
            frame.alpha_composite(resized, dst)
            frames[(sheet,cell)] = frame
            sockets[(sheet,cell)] = {
                'hand': [round((hx-rx)*scale,2),round((hy-ry)*scale,2)],
                'angle': angle, 'layer': layer, 'source_pose': f'{sheet}:{cell}',
            }
            info.update({'root': [rx,ry], 'hand':[hx,hy], 'angle':angle,
                         'layer':layer, 'scale':round(scale,6), 'baked_offset':list(dst)})
        # Annotated source atlas records the exact hand/root calibration, without
        # modifying any generated artwork used by the game.
        source = Image.open(SHEETS/f'body_{sheet}.png').convert('RGBA')
        backdrop = Image.new('RGBA',source.size,'#171c27')
        backdrop.alpha_composite(source)
        d = ImageDraw.Draw(backdrop)
        for cell, point in enumerate(settings['points']):
            rx,ry,hx,hy,angle,layer = point
            rad = math.radians(angle)
            d.line((hx,hy,hx+math.cos(rad)*140,hy+math.sin(rad)*140),fill='#97c9df',width=3)
            d.ellipse((hx-7,hy-7,hx+7,hy+7),outline='#ffd46a',width=3)
            d.line((rx-8,ry,rx+8,ry),fill='#71d895',width=3)
            d.line((rx,ry-8,rx,ry+8),fill='#71d895',width=3)
            d.text((hx+8,hy),str(cell),fill='#ffd46a')
        backdrop.convert('RGB').save(SHEETS/f'calibration_{sheet}.jpg',quality=92)

    clips = {}
    for action, (keys,durations,loop,phases) in ACTION_SPECS.items():
        strip = Image.new('RGBA',(FRAME_W*len(keys),FRAME_H))
        for i,key in enumerate(keys):
            strip.alpha_composite(frames[key], (i*FRAME_W,0))
        strip.save(OUT/'player'/f'{action}.png', optimize=True)
        entry = {'name':action, 'file':f'assets/actors_v3/player/{action}.png',
                 'frames':len(keys), 'frame_w':FRAME_W, 'frame_h':FRAME_H,
                 'ax':AX, 'ay':AY, 'durations':durations, 'fps':12,
                 'loop':loop, 'weapon_separated':True,
                 'source':'ai_keyframes', 'source_poses':[f'{a}:{i}' for a,i in keys],
                 'unique_source_poses':len(set(keys)),
                 'sockets':[sockets[key] for key in keys], 'phase_frames':phases}
        if action=='rage_slash':
            entry['segments'] = [
                {'windup':[0,1,2], 'active':[3,4]},
                {'windup':[8,9,10], 'active':[11,12]},
            ]
        elif action=='thrust':
            entry['segments'] = [
                {'windup':[0,1], 'active':[2,3]},
                {'windup':[4,5], 'active':[6,7]},
                {'windup':[8,9], 'active':[10,11]},
            ]
            entry['pose_note']='Three sword thrusts reuse the authored forward-extension body pose; each segment has its own sockets and hit phase.'
        if action in ['jump','air','back_dash','guard','hit','down','getup','blood_rage']:
            entry['pose_note']='Reviewed weaponless foundation poses; holds and limited purposeful pose reuse remain for this secondary action.'
        clips[action] = entry

        review = Image.new('RGBA',(FRAME_W*4,FRAME_H*math.ceil(len(keys)/4)),'#171c27')
        for i,key in enumerate(keys):
            x,y = i%4*FRAME_W,i//4*FRAME_H
            review.alpha_composite(frames[key],(x,y))
            draw_socket(review,sockets[key],(x+AX,y+AY),f'{action} {i}: {key[0]}:{key[1]}')
        review.convert('RGB').save(SHEETS/f'review_{action}.jpg',quality=92)
        if action in ['walk','run','attack1','attack2','attack3','upper','air_attack','dash_attack']:
            gif = []
            for key in keys:
                bg = Image.new('RGBA',(FRAME_W,FRAME_H),'#171c27')
                bg.alpha_composite(frames[key])
                gif.append(bg.convert('RGB'))
            gif[0].save(SHEETS/f'{action}.gif',save_all=True,append_images=gif[1:],
                        duration=[max(30,round(t*1000/60)) for t in durations],loop=0,disposal=2)

    manifest = {'version':3,'fps':60,'generator':'tools/bake_body_v3.py',
                'art_source':'built-in image_gen transparent weaponless hand-painted body atlases',
                'note':'All bodies face right. Weapon profiles render separately with reviewed per-frame grip sockets. Frame/root is common. Real source poses only; no fake crossfade frames.',
                'groups':{'player':clips}}
    (OUT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    validation = {'source_silhouettes':sum(len(x) for x in reports.values()),
                  'unique_used_body_poses':len({k for spec in ACTION_SPECS.values() for k in spec[0]}),
                  'frame_canvas':[FRAME_W,FRAME_H], 'root':[AX,AY],
                  'source_calibration':reports,
                  'actions':{name:{'frames':e['frames'],'unique_source_poses':e['unique_source_poses'],
                                   'socket_count':len(e['sockets']),
                                   'alpha_bounds':list(Image.open(OUT/'player'/f'{name}.png').getbbox())}
                             for name,e in clips.items()}}
    for name,e in clips.items():
        assert len(e['sockets'])==e['frames']==len(e['durations'])==len(e['source_poses']),name
        assert Image.open(OUT/'player'/f'{name}.png').size==(e['frame_w']*e['frames'],e['frame_h']),name
        # Each socket must touch an opaque hand-sized neighborhood in its own
        # authored frame. This catches an off-body grip after source changes.
        for key,socket in zip(ACTION_SPECS[name][0],e['sockets']):
            px,py=round(AX+socket['hand'][0]),round(AY+socket['hand'][1])
            patch=np.asarray(frames[key])[max(0,py-3):py+4,max(0,px-3):px+4,3]
            assert patch.size and patch.max()>=180,(name,key,'socket misses painted hand')
        for indices in e['phase_frames'].values():
            assert all(0<=i<e['frames'] for i in indices),name
    core=['walk','run','attack1','attack2','attack3','upper','air_attack','dash_attack']
    hashes={name:len({hashlib.sha256(frames[k].tobytes()).hexdigest() for k in ACTION_SPECS[name][0]})
            for name in core}
    assert all(count==8 for count in hashes.values()),hashes
    validation['verified_core_distinct_frames']=hashes
    validation['verified_sockets_touch_body']=True
    validation['verified_socket_count_matches_frames']=True
    validation['verified_no_cropped_silhouette']=True
    (SHEETS/'bake_report.json').write_text(json.dumps(validation,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'actions':len(clips),'unique_body_poses':validation['unique_used_body_poses'],
                      'output':str(OUT/'manifest.json')},ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--inspect', action='store_true')
    args = parser.parse_args()
    inspect() if args.inspect else bake()
