"""Export original Hendon streets and the first NPC batch, without painting replacements.

Generic Hendon.map is missing in this backup; (r)hendon.map is an explicit
E-ADAPT variant selection. Portal topology follows MAP town-movable groups and
town.lst indices, not an invented teleport menu. Runtime placement is separate.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from dnf_asset_store import ROOT, LOCK, cache_home
from export_dnf_map import (Library, export_map, span_values, resolve, COORDINATES, LAYERS,
                            TILE_W, TILE_H, CELL_W, CELL_H, GRID_COLS, GRID_ROWS)

OUTPUT = ROOT/'game_dnf/assets_local/flow_v1/hendon_v1'
MAPS = {'hendon_city':'map/hendonmyre/hendon_city.map',
        'hendon_main':'map/hendonmyre/(r)hendon.map',
        'hendon_auction':'map/hendonmyre/hendon_auction.map'}
# NPC ID: (runtime key, Chinese name, dialogue illustration frame).
NPCS = {6:('pungjin','风振',5),4:('sinda','辛达',3),7:('gsd','G.S.D',6),
        3:('kanna','卡妮娜',2),17:('kiri','凯丽',9),13:('norton','诺顿',12),
        45:('grandis','歌兰蒂斯',19),27:('albert','阿尔伯特',14)}


def build(library: Path, output: Path) -> dict:
    output.mkdir(parents=True,exist_ok=True)
    lib=Library(library,output)
    try:
        ids={'objects':lib.listing('passiveobject/passiveobject.lst'),
             'monsters':lib.listing('monster/monster.lst')}
        npcs=lib.listing('npc/npc.lst')
        rooms={}
        residents={}
        for key,path in MAPS.items():
            room=export_map(lib,path,ids)
            # Original extended floor is a second row of native 224x120 tiles,
            # not a stretched copy of the main floor. Needed by the lower exit.
            for col,tile in enumerate(span_values(lib.script(path)['spans'],'[extended tile]') or []):
                til_path=resolve(path,tile)
                til=lib.script(til_path)
                ref=span_values(til['spans'],'[IMAGE]')
                image=lib.image(ref[0],ref[1],til_path)
                if not image:raise ValueError('Required extended floor missing: '+til_path)
                offset=lib.images[image]['canvas_offset']
                room['tiles'].append({'column':col,'til':til_path,'sha256':til['sha256'],
                                      'image':image,'offset':[offset[0],480+offset[1]],'extended':True})
            rooms[path]=room
            raw=span_values(lib.script(path)['spans'],'[NPC]')
            residents[key]=[]
            for i in range(0,len(raw),5):
                npc_id,direction,x,y,z=raw[i:i+5]
                if npc_id not in NPCS:continue
                npc_key,name,frame=NPCS[npc_id]
                npc_path='npc/'+npcs[npc_id].lower()
                script=lib.script(npc_path)
                ani=resolve(npc_path,span_values(script['spans'],'[field animation]')[0])
                sprite=lib.sprite(ani,npc_path)
                if not sprite:raise ValueError('Required original NPC missing: '+npc_path)
                # Original [left] is the neutral orientation of these NPC banks.
                if direction=='[right]':
                    for f in sprite['frames']:f['flip_x']=not f.get('flip_x',False)
                room['animations'].append({'layer':'normal','anchor':[x,y,z],'space':'map','sprite':sprite})
                residents[key].append({'id':npc_key,'source_id':npc_id,'name':name,'anchor':[x,y,z],
                                       'source':npc_path,'sha256':script['sha256'],'ani':ani})
        portraits={key:lib.image('Interface/npc_dialog_face.img',frame,'hendon/portrait/'+key)
                   for key,_name,frame in NPCS.values()}
        if not all(portraits.values()):raise ValueError('Required original portrait missing')
        # Town MAPs intentionally lack the dungeon's eight pathgate positions.
        for d in lib.diags:
            if d['code']=='pathgate_pos':d.update(level='info',selection='Town exits use [town movable area]')
        failures=[d for d in lib.diags if d['level']=='error']
        if failures:raise ValueError(json.dumps(failures,ensure_ascii=False))
        result={'schema':'dnf_native_map/1','hendon_art_schema':'dnf_hendon_art/1',
                'source':{'asset_version':json.loads(LOCK.read_text(encoding='utf-8'))['version'],
                          'exporter':'tools/build_dnf_hendon_assets.py',
                          'selection':'E-ADAPT explicit (r)hendon variant; effective client variant unconfirmed',
                          'pixel_policy':'Native IMG RGBA; no resize, painting or substitute background'},
                'coordinates':COORDINATES,
                'constants':{'tile_width':TILE_W,'tile_height':TILE_H,'grid_cols':GRID_COLS,
                             'grid_rows':GRID_ROWS,'cell_width':CELL_W,'cell_height':CELL_H,
                             'screen_y_offset':120,'viewport':[800,600],'layers':LAYERS},
                'dungeon':{'rooms':rooms,'placements':[{'id':key,'map':path,'gates':[]} for key,path in MAPS.items()],
                           'gate_objects':{}},'npcs':residents,'ui':{'portraits':portraits},
                'topology_source':lib.script('town/hendonmyre.twn'),'images':lib.images,'diagnostics':lib.diags}
        (output/'manifest.json').write_text(json.dumps(result,ensure_ascii=False,indent=1)+'\n',encoding='utf-8')
        return {'output':str(output),'images':len(lib.images),'npcs':{k:len(v) for k,v in residents.items()},'diagnostics':len(lib.diags)}
    finally:lib.close()


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path)
    p.add_argument('--output',type=Path,default=OUTPUT)
    args=p.parse_args()
    output=args.output.resolve()
    if not any(output.is_relative_to(r.resolve()) for r in [ROOT/'temp',ROOT/'game_dnf/assets_local']):p.error('Ignored outputs only')
    version=json.loads(LOCK.read_text(encoding='utf-8'))['version']
    print(json.dumps(build(args.library or cache_home()/version/'library_v1',output),ensure_ascii=False))
