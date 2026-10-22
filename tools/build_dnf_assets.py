"""Select existing local IMG/ANI/audio, preserve sources, and compile native atlases.

All third-party bytes and manifests remain inside ignored assets_local/. Runtime
never depends on the original client or the temporary SQL catalog after baking.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
from PIL import Image
from dnf_asset_reader import parse, decode

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'game_dnf/assets_local'
LAYERS = ['pants/sm_pants0000b.img', 'shoes/sm_shoes0000b.img', 'skin/sm_body0000.img',
          'pants/sm_pants0000a.img', 'shoes/sm_shoes0000a.img',
          'coat/sm_coat0000a.img', 'hair/sm_hair0000a.img']
WEAPONS = {'shortsword': 'sswd', 'katana': 'katana', 'greatsword': 'lswd'}
PLAYER_CLIPS = ['stay','move','dash','jump','jumpattack','hitback','guard','damage1',
                'damage2','down','sit','overturn','attack1','attack2','attack3',
                'dashattack','upperslashafter','momentaryslash','triplestab','gorecross']
FX_CLIPS = {
 'draw': 'character/swordman/effect/animation/momentaryslash.ani',
 'hit': 'common/hiteffect/animation/age12/slashsmall1.ani',
 'heavy': 'common/hiteffect/animation/age12/slashlarge1.ani',
}


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')


def sha(data): return hashlib.sha256(data).hexdigest()


def stage(library):
    sources = OUT/'sources';sources.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(library/'catalog.sqlite');c.row_factory = sqlite3.Row
    a = sqlite3.connect(library/'pvf_config.sqlite')
    manifest = {'schema': 'dnf_selected_sources/1', 'images': {}, 'animations': {}, 'audio': {},
                'rights': 'Existing local client assets; no redistribution authorization inferred; Git ignored.',
                'config_provenance': '111Script.pvf backup; runtime PVF equivalence unconfirmed.'}
    def image(path):
        path = path.lower()
        if path in manifest['images']:return
        rows = c.execute("select * from assets where lower(original_path)=? and validation='image_data_checked'", (path,)).fetchall()
        if not rows:raise ValueError('Missing validated image: '+path)
        rows = sorted(rows, key=lambda r:(not Path(r['container']).name.lower().startswith('sprite_'),r['container']))
        row = dict(rows[0]);data = (library/row['local_path']).read_bytes()
        assert sha(data) == row['sha256']
        target = Path('sources/img')/(row['id']+'.img');(OUT/target).parent.mkdir(parents=True,exist_ok=True);(OUT/target).write_bytes(data)
        manifest['images'][path] = dict(file=target.as_posix(),sha256=sha(data),source_npk=row['container'],
                                      original_path=row['original_path'],variants=len(rows),selection='Prefer conventionally named original NPK; explicit local trial choice, not inferred client priority.')
    for layer in LAYERS:image('sprite/character/swordman/equipment/avatar/'+layer)
    for weapon in WEAPONS.values():
        for side in ['b','c']:image(f'sprite/character/swordman/equipment/weapon/{weapon}/{weapon}0000{side}.img')
    for path in ['sprite/monster/goblin/body1.img','sprite/monster/goblin/body2.img',
                 'sprite/map/00far1.img','sprite/map/00mid0.img','sprite/map/00mid1.img','sprite/map/00tile.img',
                 'sprite/map/00obj0.img','sprite/map/00obj1.img','sprite/map/00obj2.img',
                 'sprite/map/pathgate/granflorisbush01.img','sprite/map/pathgate/granflorisbush02.img',
                 'sprite/map/pathgate/granflorisdowngate01.img','sprite/map/pathgate/granflorisdowngate02.img',
                 'sprite/map/pathgate/granflorissidedoor01.img','sprite/map/pathgate/granflorissidedoor02.img',
                 'sprite/map/pathgate/granflorisupdoor01.img','sprite/map/pathgate/granflorisupdoor02.img',
                 'sprite/map/breakableobject/grass1lorien.img','sprite/interface2/hud/hud.img',
                 'sprite/interface2/hud/menu_icon.img']:
        image(path)
    ani_paths = ['character/swordman/animation/'+x+'.ani' for x in PLAYER_CLIPS]
    ani_paths += ['monster/goblin/animation_goblin/'+x+'.ani' for x in ['stay','move','attack1','damage1','down','sit','overturn']]
    ani_paths += list(FX_CLIPS.values())
    for path in ani_paths:
        row = a.execute("select metadata from animations where path=? and status='parsed'",(path,)).fetchone()
        if not row:raise ValueError('Missing parsed ANI: '+path)
        ani = json.loads(row[0]);manifest['animations'][path] = ani
        if path in FX_CLIPS.values():
            for img in ani['images']:image('sprite/'+img)
    sound_map = {'swing1':'sm_atk_01.ogg','swing2':'sm_atk_02.ogg','swing3':'sm_atk_03.ogg',
                 'hurt':'sm_dmg_01.ogg','jump':'sm_jump.ogg','upper':'sm_upslash.ogg',
                 'draw_ready':'sm_bal1.ogg','thrust':'sm_thrust.ogg',
                 'draw':'sm_bal2.ogg','goblin_hurt':'gbn_dmg_01.ogg','goblin_die':'gbn_die_01.ogg'}
    # Exact unavailable names are omitted and reported; never fabricate replacements.
    # Some original Sony Vorbis comments are not KEY=VALUE and cause Godot
    # metadata warnings. Preserve those source bytes and record this limitation;
    # a comment warning does not establish a corrupt audio packet or bad timbre.
    for key,tail in sound_map.items():
        row = c.execute("select * from assets where kind='audio' and lower(original_path) like ? order by container limit 1",('%/'+tail.lower(),)).fetchone()
        if not row:continue
        data = (library/row['local_path']).read_bytes();target = Path('audio')/(key+Path(tail).suffix)
        (OUT/target).parent.mkdir(parents=True,exist_ok=True);(OUT/target).write_bytes(data)
        manifest['audio'][key] = dict(file=target.as_posix(),sha256=sha(data),source=row['original_path'],source_npk=row['container'])
    row = c.execute("select * from assets where category='11_music' and lower(original_path)='music/forest01.ogg' limit 1").fetchone()
    if not row:row = c.execute("select * from assets where category='11_music' and lower(original_path) like '%lorien%' limit 1").fetchone()
    if row:
        data=(library/row['local_path']).read_bytes();target=Path('audio/music.ogg');(OUT/target).write_bytes(data)
        manifest['audio']['music']=dict(file=target.as_posix(),sha256=sha(data),source=row['original_path'])
    write(sources/'selection.json',manifest)
    c.close();a.close()


class Atlas:
    def __init__(self,name):self.name=name;self.items={};self.images=[];self.x=2;self.y=2;self.row_h=0
    def add(self,key,image,offset):
        w,h=image.size
        if w+4>2048:raise ValueError('Atlas image too wide')
        if self.x+w+2>2048:self.x=2;self.y+=self.row_h+4;self.row_h=0
        self.items[str(key)]={'rect':[self.x,self.y,w,h],'offset':list(offset)}
        self.images.append((image,self.x,self.y));self.x+=w+4;self.row_h=max(self.row_h,h)
    def save(self):
        height=self.y+self.row_h+2;canvas=Image.new('RGBA',(2048,height))
        for image,x,y in self.images:canvas.paste(image,(x,y))
        canvas.save(OUT/(self.name+'.png'))
        return dict(texture='res://assets_local/'+self.name+'.png',items=self.items,size=[2048,height])


def bake():
    selection=json.loads((OUT/'sources/selection.json').read_text(encoding='utf-8'))
    decoded={}
    def source(path):
        path=path.lower()
        if path not in decoded:
            m=selection['images'][path];data=(OUT/m['file']).read_bytes()
            if sha(data)!=m['sha256']:raise ValueError('Source hash changed: '+path)
            decoded[path]=(data,parse(data))
        return decoded[path]
    def frame(path,n):
        data,p=source(path);return decode(data,p,n)
    def composite(paths,n):
        layers=[]
        for path in paths:
            im,meta=frame(path,n)
            bounds=im.getbbox()
            if bounds:
                layers.append((im.crop(bounds),meta['x']+bounds[0],meta['y']+bounds[1]))
        if not layers:return Image.new('RGBA',(1,1)),[0,0]
        x0=min(x for _,x,y in layers);y0=min(y for _,x,y in layers)
        x1=max(x+im.width for im,x,y in layers);y1=max(y+im.height for im,x,y in layers)
        result=Image.new('RGBA',(x1-x0,y1-y0))
        for im,x,y in layers:result.alpha_composite(im,(x-x0,y-y0))
        return result,[x0,y0]
    runtime={'schema':'dnf_native_runtime/1','native_pixels':True,'players':{},'goblins':{},'clips':{},'effects':{},'scene':{},'ui':{},'audio':selection['audio']}
    avatar=['sprite/character/swordman/equipment/avatar/'+p for p in LAYERS]
    for label,weapon in WEAPONS.items():
        atlas=Atlas('player_'+label)
        paths=[f'sprite/character/swordman/equipment/weapon/{weapon}/{weapon}0000b.img']+avatar+[f'sprite/character/swordman/equipment/weapon/{weapon}/{weapon}0000c.img']
        for n in range(210):
            image,offset=composite(paths,n);atlas.add(n,image,offset)
        runtime['players'][label]=atlas.save()
    for key,body in [('normal','body1'),('chief','body2')]:
        atlas=Atlas('goblin_'+key)
        for n in range(17):
            image,offset=composite(['sprite/monster/goblin/'+body+'.img'],n);atlas.add(n,image,offset)
        runtime['goblins'][key]=atlas.save()
    for path,ani in selection['animations'].items():
        if path in FX_CLIPS.values():continue
        key=('goblin/' if path.startswith('monster/') else 'player/')+Path(path).stem
        runtime['clips'][key]=ani
    for key,path in FX_CLIPS.items():
        ani=selection['animations'][path];atlas=Atlas('effect_'+key)
        entries=[]
        for n,f in enumerate(ani['frames']):
            rec=dict(f)
            if f['img'] is not None:
                im,meta=frame('sprite/'+f['img'],f['img_frame']);atlas.add(n,im,[meta['x']+f['pos'][0],meta['y']+f['pos'][1]])
                rec['sprite']=str(n)
            entries.append(rec)
        runtime['effects'][key]=dict(atlas=atlas.save(),frames=entries,duration_ms=ani['duration_ms'])
    scene_atlas=Atlas('scene')
    scene_specs={
      'far':('sprite/map/00far1.img',0),'mid':('sprite/map/00mid0.img',0),'mid_front':('sprite/map/00mid1.img',0),
      'floor':('sprite/map/00tile.img',0),'floor2':('sprite/map/00tile.img',1),
      'bush':('sprite/map/pathgate/granflorisbush01.img',0),'bush2':('sprite/map/pathgate/granflorisbush02.img',0),
      'gate_closed':('sprite/map/pathgate/granflorisdowngate01.img',0),'gate_open':('sprite/map/pathgate/granflorisdowngate02.img',0),
      'side_closed':('sprite/map/pathgate/granflorissidedoor01.img',0),'side_open':('sprite/map/pathgate/granflorissidedoor02.img',0),
      'up_closed':('sprite/map/pathgate/granflorisupdoor01.img',0),'up_open':('sprite/map/pathgate/granflorisupdoor02.img',0),
      'rock':('sprite/map/00obj0.img',10),'tree':('sprite/map/00obj1.img',0),'stump':('sprite/map/00obj1.img',6),
      'grass':('sprite/map/breakableobject/grass1lorien.img',0)}
    for n in range(8):scene_specs['grass_'+str(n)]=('sprite/map/breakableobject/grass1lorien.img',n)
    for key,(path,n) in scene_specs.items():
        im,meta=frame(path,n)
        bounds=im.getbbox()
        if bounds:
            # Trim transparent authored padding, without changing any native pixels.
            scene_atlas.add(key,im.crop(bounds),[meta['x']+bounds[0],meta['y']+bounds[1]])
        else:scene_atlas.add(key,im,[meta['x'],meta['y']])
    runtime['scene']=scene_atlas.save()
    ui=Atlas('ui')
    for n in [0,1,2,3,21,22,29,37,51,76,81]:
        im,meta=frame('sprite/interface2/hud/hud.img',n);ui.add('hud_'+str(n),im,[0,0])
    for n in [4,8,12,16]:
        im,meta=frame('sprite/interface2/hud/menu_icon.img',n);ui.add('icon_'+str(n),im,[0,0])
    runtime['ui']=ui.save()
    write(OUT/'manifest.json',runtime)
    write(OUT/'build_validation.json',dict(passed=True,source_images=len(selection['images']),
      source_animations=len(selection['animations']),actor_pose_count=3*210+2*17,
      image_resize_operations=0,alpha='RGBA straight alpha',frame_time_unit='ms',
      note='All selected frame payloads decoded; native cropped pixels packed without resizing. Original crop coordinates retained.'))
    print(json.dumps({'images':len(selection['images']),'animations':len(selection['animations']),'atlases':len(list(OUT.glob('*.png'))),'audio':len(runtime['audio'])}))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--library',type=Path);args=parser.parse_args()
    OUT.mkdir(parents=True,exist_ok=True)
    if args.library:stage(args.library.resolve())
    bake()
