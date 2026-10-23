"""Export first Granfloris dungeons, the forest approach and Shylock's alley.

Native pixels and source anchors only; no painted substitutes. The two dungeon
exports retain their candidate maps for traceability. Runtime selects an explicit
reciprocal route; unsupported original randomness and special AI stay documented.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from dnf_asset_store import ROOT, LOCK, cache_home
from export_dnf_map import (Library, export_map, span_values, resolve, run, COORDINATES,
                            LAYERS, TILE_W, TILE_H, CELL_W, CELL_H, GRID_COLS, GRID_ROWS)

OUTPUT=ROOT/'game_dnf/assets_local/flow_v1/gran_v1'
MAPS={'hendon_forest_gate':'map/hendonmyre/d_hendon.map',
      'hendon_alley':'map/hendonmyre/hendon_ura.map'}
DUNGEONS={'mirkwood':'dungeon/act1/mirkwood.dgn',
          'mirkwood_deep':'dungeon/act1/mirkwooddeep.dgn'}

def restore_bunker_art(library: Path, folder: Path) -> None:
    """The source bunker has empty basic motion and explicit component ANIs.

    Preserve a source-composed idle state instead of silently omitting the object.
    Destruction/throwing script behaviour is not implemented by this art export.
    """
    path=folder/'map_export.json'
    data=json.loads(path.read_text(encoding='utf-8'))
    obj='passiveobject/mapobject/trap/goblinbunker/goblinbunker.obj'
    lib=Library(library,folder)
    lib.images=data['images']
    try:
        script=lib.script(obj)
        motions=span_values(script['spans'],'[etc motion]')
        parts=[motions[i] for i in [2,7,12,16,18]]
        for room in data['dungeon']['rooms'].values():
            for item in room['objects']:
                if item.get('obj')!=obj:continue
                for motion in parts:
                    sprite=lib.sprite(resolve(obj,motion),obj)
                    if not sprite:raise ValueError('Bunker component missing: '+motion)
                    room['animations'].append({'layer':'normal','anchor':item['anchor'],
                                               'space':'map','sprite':sprite,'source_object':obj})
                item['art_adaptation']='E-ADAPT source idle components; trap/destruction AI not restored'
        for d in data['diagnostics']:
            if d['code']=='ani_missing' and d['path']==obj:
                d.update(level='warning',selection='Empty basic motion resolved using original etc-motion idle components; behaviour not restored')
        data['images']=lib.images
        data['diagnostics'].extend(lib.diags)
        if any(d['level']=='error' for d in data['diagnostics']):raise ValueError(str(data['diagnostics']))
        path.write_text(json.dumps(data,ensure_ascii=False,indent=1)+'\n',encoding='utf-8')
    finally:lib.close()

def build(library: Path, output: Path, towns_only=False) -> dict:
    output.mkdir(parents=True,exist_ok=True)
    lib=Library(library,output)
    try:
        ids={'objects':lib.listing('passiveobject/passiveobject.lst'),
             'monsters':lib.listing('monster/monster.lst')}
        rooms={path:export_map(lib,path,ids) for path in MAPS.values()}
        npc_path='npc/shylock.npc'
        npc=lib.script(npc_path)
        ani=resolve(npc_path,span_values(npc['spans'],'[field animation]')[0])
        raw=span_values(lib.script(MAPS['hendon_alley'])['spans'],'[NPC]')
        anchor=next(raw[i:i+5] for i in range(0,len(raw),5) if raw[i]==9)
        sprite=lib.sprite(ani,npc_path)
        if not sprite:raise ValueError('Original Shylock field animation required')
        if anchor[1]=='[right]':
            for f in sprite['frames']:f['flip_x']=not f.get('flip_x',False)
        rooms[MAPS['hendon_alley']]['animations'].append(
            {'layer':'normal','anchor':anchor[2:5],'space':'map','sprite':sprite})
        portrait=lib.image('Interface/npc_dialog_face.img',7,'gran/shylock/portrait')
        cards={key:lib.image('WorldMap/SelectDungeonSlot/granfloris.img',i,'gran/dungeons')
               for i,key in enumerate(DUNGEONS)}
        if not portrait or not all(cards.values()):raise ValueError('Original portrait and dungeon cards required')
        for d in lib.diags:
            if d['code']=='pathgate_pos':d.update(level='info',selection='Town uses explicit town movable area')
            if d['code']=='tile_pass':d.update(level='warning',selection='Town uses source virtual movable rectangles, not the dungeon pass grid; raw tile retained')
        if any(d['level']=='error' for d in lib.diags):raise ValueError(str(lib.diags))
        data={'schema':'dnf_native_map/1','gran_art_schema':'dnf_gran_art/1',
              'source':{'asset_version':json.loads(LOCK.read_text(encoding='utf-8'))['version'],
                        'exporter':'tools/build_dnf_gran_assets.py',
                        'selection':'E-ADAPT existing backup MAPs; source-selected, effective client variant unconfirmed',
                        'pixel_policy':'Original IMG RGBA, no resize or substitutes'},
              'coordinates':COORDINATES,
              'constants':{'tile_width':TILE_W,'tile_height':TILE_H,'grid_cols':GRID_COLS,'grid_rows':GRID_ROWS,
                           'cell_width':CELL_W,'cell_height':CELL_H,'screen_y_offset':120,'viewport':[800,600],'layers':LAYERS},
              'dungeon':{'rooms':rooms,'placements':[{'id':key,'map':path,'gates':[]} for key,path in MAPS.items()],
                         'gate_objects':{}},
              'npcs':{'shylock':{'source_id':9,'anchor':anchor[2:5],'source':npc_path,'sha256':npc['sha256'],'ani':ani}},
              'ui':{'portraits':{'shylock':portrait},'dungeons':cards},'images':lib.images,'diagnostics':lib.diags}
        (output/'manifest.json').write_text(json.dumps(data,ensure_ascii=False,indent=1)+'\n',encoding='utf-8')
    finally:lib.close()
    if not towns_only:
        for key,path in DUNGEONS.items():
            run(library,path,output/key,[])
            restore_bunker_art(library,output/key)
    return {'output':str(output),'town_images':len(data['images']),'dungeons':list(DUNGEONS)}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path)
    p.add_argument('--output',type=Path,default=OUTPUT)
    p.add_argument('--towns-only',action='store_true',help='Development: export only town art; full release also needs both dungeon exports')
    args=p.parse_args()
    output=args.output.resolve()
    if not any(output.is_relative_to(r.resolve()) for r in [ROOT/'temp',ROOT/'game_dnf/assets_local']):p.error('Ignored outputs only')
    version=json.loads(LOCK.read_text(encoding='utf-8'))['version']
    print(json.dumps(build(args.library or cache_home()/version/'library_v1',output,args.towns_only)))
