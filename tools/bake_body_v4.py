#!/usr/bin/env python3
"""Bake new idle, back-hop and upright jump poses without changing v3 assets.

The v4 manifest inherits v3 combat actions and keeps their file paths. Every
new body frame is a real generated source pose with a reviewed grip socket.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from bake_body_v3 import extract, draw_socket, FRAME_W, FRAME_H, AX, AY

ROOT = Path(__file__).resolve().parents[1]
SHEETS = ROOT/'art/animations/players/swordsman/v4/sources'
OUT = ROOT/'game'/'assets'/'actors_v4'
BASE = ROOT/'game'/'assets'/'actors_v3'/'manifest.json'

# (root_x, root_y, fist_x, fist_y, blade_degrees, front/back)
# Breathing frames share one planted ground plane. Airborne phases use a
# reviewed virtual floor, so the lowest toe never drags the pelvis downward.
CALIBRATION = {
    'idleback': {'standing_h':340, 'points':[
        (189,348,125,195,35,'front'), (500,348,438,195,35,'front'),
        (812,348,749,198,35,'front'), (1132,348,1092,189,35,'front'),
        (165,690,101,537,35,'front'), (488,690,429,538,35,'front'),
        (798,690,746,536,35,'front'), (1123,690,1063,538,35,'front'),
        # The remaining source-sheet back-hop attempt is intentionally unused.
        (168,980,98,858,145,'back'), (480,975,440,857,145,'back'),
        (790,981,767,831,145,'back'), (1133,952,1067,811,145,'back'),
        (185,1245,145,1106,145,'back'), (490,1245,436,1120,145,'back'),
        (812,1245,742,1137,145,'back'), (1124,1247,1058,1124,35,'front'),
    ]},
    'back': {'standing_h':413, 'points':[
        (169,582,88,389,35,'front'), (484,574,483,366,-115,'front'),
        (774,582,736,311,-125,'front'), (1145,558,1111,277,-130,'front'),
        (180,1070,174,790,-135,'front'), (535,1123,517,818,-120,'front'),
        (819,1126,796,972,35,'front'), (1124,1125,1057,929,35,'front'),
    ]},
    'jump': {'standing_h':377, 'points':[
        (185,428,112,257,35,'front'), (495,428,434,321,145,'back'),
        (789,430,725,238,145,'back'), (1137,430,1045,228,145,'back'),
        (185,839,127,658,145,'back'), (490,839,443,648,145,'back'),
        (798,840,768,648,35,'front'), (1129,829,1088,711,35,'front'),
    ]},
}


def refs(sheet: str, indices: list[int]) -> list[tuple[str,int]]:
    return [(sheet,i) for i in indices]


ACTION_SPECS = {
    'idle': (refs('idleback',list(range(8))), [15]*8, True,
             {'breath_in':[0,1,2,3], 'breath_out':[4,5,6,7]}),
    'back_dash': (refs('back',list(range(8))), [2,3,2,3,3,3,3,3], False,
                  {'prepare':[0,1], 'takeoff':[2], 'air':[3,4,5], 'land':[6], 'recover':[7]}),
    'jump': (refs('jump',list(range(8))), [2,3,3,6,7,6,4,3], False,
             {'prepare':[0,1], 'takeoff':[2], 'rise':[3], 'apex':[4], 'fall':[5,6], 'land':[7]}),
    'jump_rise': (refs('jump',[2,3,4]), [4,5,6], False, {'rise':[0,1,2]}),
    'jump_apex': (refs('jump',[4,5]), [5,5], False, {'apex':[0,1]}),
    'jump_fall': (refs('jump',[5,6]), [7,7], False, {'fall':[0,1]}),
    'jump_land': (refs('jump',[7,6,0]), [3,3,4], False, {'land':[0], 'recover':[1,2]}),
}


def bake() -> None:
    (OUT/'player').mkdir(parents=True,exist_ok=True)
    frames,sockets,reports={},{},{}
    used={key for spec in ACTION_SPECS.values() for key in spec[0]}
    for sheet,settings in CALIBRATION.items():
        poses,report=extract(SHEETS/f'body_{sheet}.png',len(settings['points']))
        reports[sheet]=report
        scale=190.0/settings['standing_h']
        for cell,(pose,info,point) in enumerate(zip(poses,report,settings['points'])):
            rx,ry,hx,hy,angle,layer=point
            info.update({'root':[rx,ry],'hand':[hx,hy],'angle':angle,'layer':layer,
                         'scale':round(scale,6),'used':(sheet,cell) in used})
            if (sheet,cell) not in used:
                continue
            x0,y0,_,_=info['bbox']
            resize=pose.resize((round(pose.width*scale),round(pose.height*scale)),Image.Resampling.LANCZOS)
            dst=(AX+round((x0-rx)*scale),AY+round((y0-ry)*scale))
            if dst[0]<0 or dst[1]<0 or dst[0]+resize.width>FRAME_W or dst[1]+resize.height>FRAME_H:
                raise ValueError(f'{sheet}:{cell}: frame canvas crops body {dst} {resize.size}')
            canvas=Image.new('RGBA',(FRAME_W,FRAME_H))
            canvas.alpha_composite(resize,dst)
            frames[(sheet,cell)]=canvas
            sockets[(sheet,cell)]={'hand':[round((hx-rx)*scale,2),round((hy-ry)*scale,2)],
                                  'angle':angle,'layer':layer,'source_pose':f'{sheet}:{cell}'}
            info['baked_offset']=list(dst)
        source=Image.open(SHEETS/f'body_{sheet}.png').convert('RGBA')
        review=Image.new('RGBA',source.size,'#171c27')
        review.alpha_composite(source)
        draw=ImageDraw.Draw(review)
        for cell,(rx,ry,hx,hy,angle,layer) in enumerate(settings['points']):
            if (sheet,cell) not in used:
                continue
            angle=math.radians(angle)
            draw.line((hx,hy,hx+math.cos(angle)*140,hy+math.sin(angle)*140),fill='#97c9df',width=3)
            draw.ellipse((hx-7,hy-7,hx+7,hy+7),outline='#ffd46a',width=3)
            draw.line((rx-8,ry,rx+8,ry),fill='#71d895',width=3)
            draw.line((rx,ry-8,rx,ry+8),fill='#71d895',width=3)
            draw.text((hx+9,hy),str(cell),fill='#ffd46a')
        review.convert('RGB').save(SHEETS/f'calibration_{sheet}.jpg',quality=92)

    manifest=copy.deepcopy(json.loads(BASE.read_text(encoding='utf-8')))
    manifest.update({'version':4,'generator':'tools/bake_body_v4.py','base_manifest':'game/assets/actors_v3/manifest.json',
                     'art_source':'built-in image_gen weaponless hand-painted body atlases, v3 combat + v4 movement',
                     'note':'New idle/back hop/upright jump poses; unchanged combat files and sockets stay in actors_v3. Every body is weaponless with per-frame grip sockets.'})
    clips=manifest['groups']['player']
    for action,(keys,durations,loop,motion_phases) in ACTION_SPECS.items():
        strip=Image.new('RGBA',(FRAME_W*len(keys),FRAME_H))
        for index,key in enumerate(keys):
            strip.alpha_composite(frames[key],(index*FRAME_W,0))
        strip.save(OUT/'player'/f'{action}.png',optimize=True)
        entry={'name':action,'file':f'assets/actors_v4/player/{action}.png','frames':len(keys),
               'frame_w':FRAME_W,'frame_h':FRAME_H,'ax':AX,'ay':AY,'durations':durations,
               'fps':12,'loop':loop,'weapon_separated':True,'source':'ai_keyframes',
               'source_poses':[f'{a}:{i}' for a,i in keys], 'unique_source_poses':len(set(keys)),
               'sockets':[sockets[key] for key in keys], 'phase_frames':{},'motion_phases':motion_phases}
        if action.startswith('jump_'):
            entry['pose_note']='Intentional phase-specific subset of the eight real jump source poses; select by jump velocity/height and landing state.'
        clips[action]=entry
        review=Image.new('RGBA',(FRAME_W*4,FRAME_H*math.ceil(len(keys)/4)),'#171c27')
        gif=[]
        for index,key in enumerate(keys):
            x,y=index%4*FRAME_W,index//4*FRAME_H
            review.alpha_composite(frames[key],(x,y))
            draw_socket(review,sockets[key],(x+AX,y+AY),f'{action} {index}: {key[0]}:{key[1]}')
            bg=Image.new('RGBA',(FRAME_W,FRAME_H),'#171c27')
            bg.alpha_composite(frames[key])
            gif.append(bg.convert('RGB'))
        review.convert('RGB').save(SHEETS/f'review_{action}.jpg',quality=92)
        gif[0].save(SHEETS/f'{action}.gif',save_all=True,append_images=gif[1:],
                    duration=[round(t*1000/60) for t in durations],loop=0,disposal=2)

    validation={'source_silhouettes':sum(len(r) for r in reports.values()),'unique_used_body_poses':len(used),
                'frame_canvas':[FRAME_W,FRAME_H],'root':[AX,AY],'source_calibration':reports,
                'overridden_clips':['idle','back_dash','jump'],
                'new_phase_clips':['jump_rise','jump_apex','jump_fall','jump_land'],
                'new_clip_checks':{}}
    for action,(keys,durations,loop,motion_phases) in ACTION_SPECS.items():
        entry=clips[action]
        assert len(entry['sockets'])==entry['frames']==len(entry['durations'])==len(entry['source_poses']),action
        assert Image.open(OUT/'player'/f'{action}.png').size==(FRAME_W*len(keys),FRAME_H),action
        for key,socket in zip(keys,entry['sockets']):
            px,py=round(AX+socket['hand'][0]),round(AY+socket['hand'][1])
            patch=np.asarray(frames[key])[max(0,py-3):py+4,max(0,px-3):px+4,3]
            assert patch.size and patch.max()>=180,(action,key,'grip misses painted hand')
        assert all(0<=i<entry['frames'] for phase in motion_phases.values() for i in phase),action
        hashes={hashlib.sha256(frames[k].tobytes()).hexdigest() for k in keys}
        assert len(hashes)==len(keys),(action,'duplicate actual frames')
        validation['new_clip_checks'][action]={'frames':len(keys),'distinct_pixel_frames':len(hashes),
            'sockets':len(entry['sockets']),'grips_touch_body':True,'no_canvas_crop':True}
    inherited=json.loads(BASE.read_text(encoding='utf-8'))['groups']['player']
    for action,entry in inherited.items():
        if action not in ACTION_SPECS:
            assert clips[action]==entry,(action,'inherited v3 action changed')
    validation['verified_unchanged_v3_clips']=len(inherited)-3
    (OUT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    (SHEETS/'bake_report.json').write_text(json.dumps(validation,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'actions':len(clips),'new_body_poses':len(used),'unchanged_v3_actions':len(inherited)-3,
                      'output':str(OUT/'manifest.json')},ensure_ascii=False))


def inspect() -> None:
    for sheet,count in [('idleback',16),('back',8),('jump',8)]:
        path=SHEETS/f'body_{sheet}.png'
        _,report=extract(path,count)
        print(path.name,Image.open(path).size)
        print(json.dumps(report,indent=None))


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--inspect',action='store_true')
    args=parser.parse_args()
    inspect() if args.inspect else bake()
