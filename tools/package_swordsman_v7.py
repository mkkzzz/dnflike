"""Verify and trim the c5 layer exports without resampling; package the same pixels for game/review."""
from __future__ import annotations
import argparse,copy,hashlib,json,shutil
from pathlib import Path
from PIL import Image,ImageChops

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'art/animations/players/swordsman/v7/exports/base_batch_c5'
OUTPUT=ROOT/'art/animations/players/swordsman/v7/exports/base_runtime_c5'
GAME=ROOT/'game/assets/swordsman_v7_c5'
PROFILES=['katana','greatsword','shortsword']
def read(path):return json.loads(path.read_text(encoding='utf-8'))
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def write(path,value):
 path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')

def package(install=False):
 index=read(SOURCE/'manifest.json')
 if not index.get('complete') or len(index['clips'])!=32:raise ValueError('All 32 source clip candidates must exist before packaging')
 OUTPUT.mkdir(parents=True,exist_ok=True)
 textures={};clips={};checked=0;body_hashes=set()
 def layer(folder,path):
  raw=Image.open(folder/path).convert('RGBA');box=raw.getchannel('A').getbbox()
  if not box:return {}
  crop=raw.crop(box);identifier=hashlib.sha256(str(crop.size).encode()+crop.tobytes()).hexdigest()
  file='layers/'+identifier+'.png';target=OUTPUT/file
  if identifier not in textures:
   target.parent.mkdir(exist_ok=True);crop.save(target)
   textures[identifier]={'file':file,'sha256':sha(target),'size':list(crop.size)}
  return {'file':file,'rect':[box[0],box[1],box[2]-box[0],box[3]-box[1]]}
 for name,entry in index['clips'].items():
  path=SOURCE/entry['manifest'];m=read(path);folder=path.parent
  if sha(path)!=entry['manifest_sha256']:raise ValueError('Stale source manifest '+name)
  if not m['proportion_gate']['passed']:raise ValueError('Failed proportion gate '+name)
  for file,digest in m['files'].items():
   if sha(folder/file)!=digest:raise ValueError('Changed source pixels '+file)
  clip={'semantic_id':m['semantic_id'],'duration_ticks':m['duration_ticks'],'loop':entry['loop'],
        'root_mode':m['root_mode'],'frames':[],'source_manifest':path.relative_to(ROOT).as_posix(),'source_manifest_sha256':sha(path)}
  for f in m['frames']:
   body=Image.open(folder/f['body']).convert('RGBA');fingers=Image.open(folder/f['fingers']).convert('RGBA')
   body_hashes.add(f['body_sha256'])
   frame={k:copy.deepcopy(f[k])for k in ['source_pose','start_tick','duration_ticks','height_px','root_dx','edge_intent','allow_edge_roll_from_previous']}
   frame['body']=layer(folder,f['body']);frame['fingers']=layer(folder,f['fingers']);frame['profiles']={}
   for key,p in f['profiles'].items():
    back=Image.open(folder/p['back']).convert('RGBA');front=Image.open(folder/p['front']).convert('RGBA')
    actual=Image.alpha_composite(Image.alpha_composite(Image.alpha_composite(back,body),front),fingers)
    expected=Image.open(folder/p['composite']).convert('RGBA')
    if actual.tobytes()!=expected.tobytes():raise ValueError('Export layer recomposition mismatch '+name)
    if p['edge_review']['cutting_alignment']<.2 or p['source_sampling_scale']>1:raise ValueError('Invalid blade side/sampling '+name)
    if m['root_mode']=='ground' and p['tip'][1]>index['anchor'][1]+4:raise ValueError('Ground-pose blade tip penetrates floor '+name)
    # Reconstruct trimmed layers back at their exact original pixel coordinates.
    packed={'back':layer(folder,p['back']),'front':layer(folder,p['front']),
            'grip':p['grip'],'guard':p['guard'],'tip':p['tip'],
            'cutting_edge':p['cutting_edge'],'spine':p['spine'],'edge_review':p['edge_review']}
    reconstructed=Image.new('RGBA',actual.size)
    for reference in [packed['back'],frame['body'],packed['front'],frame['fingers']]:
     if reference:
      piece=Image.open(OUTPUT/reference['file']).convert('RGBA');reconstructed.alpha_composite(piece,tuple(reference['rect'][:2]))
    # Fully transparent source PNGs may carry arbitrary RGB. It is not visible
    # straight-alpha content and is intentionally absent outside the trim.
    alpha=actual.getchannel('A');mask=alpha.point(lambda value:255 if value else 0).convert('RGB')
    rgb_diff=ImageChops.multiply(ImageChops.difference(reconstructed.convert('RGB'),actual.convert('RGB')),mask)
    if reconstructed.getchannel('A').tobytes()!=alpha.tobytes() or rgb_diff.getbbox():raise ValueError('Trim/anchor mismatch '+name)
    frame['profiles'][key]=packed;checked+=1
   clip['frames'].append(frame)
  if sum(f['duration_ticks']for f in clip['frames'])!=clip['duration_ticks']:raise ValueError('Broken clock '+name)
  clips[name]=clip
 # Death is a real three-stage reuse, not a held resting pose pretending to fall.
 rest=copy.deepcopy(clips['death']['frames'][0]);clips['death']['source_rest_frame']=copy.deepcopy(rest)
 stages=[(copy.deepcopy(clips['hit_heavy']['frames'][0]),6,'hit_heavy'),(copy.deepcopy(clips['down']['frames'][0]),8,'down'),(rest,28,'death_rest')]
 cursor=0;frames=[]
 for frame,duration,origin in stages:
  frame.update(start_tick=cursor,duration_ticks=duration,reused_from=origin);cursor+=duration;frames.append(frame)
 clips['death']['frames']=frames;clips['death']['duration_ticks']=cursor
 coverage={'complete':True,'scope':'non-skill base actions only','source_clip_count':len(clips),
  'aliases':{'hit':'hit_light','air':'air_hit'},
  'state_mapping':{'IDLE':'idle','WALK':'walk_start / walk / walk_stop','RUN':'run_start / run / run_stop',
   'JUMP':'jump_start / rise / apex / fall / land driven by actual physics','BACK_DASH':'back_dash',
   'ATK':'attack1 / attack2 / attack3','DASH_ATK':'dash_attack','AIR_ATK':'air_attack',
   'GUARD':'guard_start / guard / parry or recoil / guard_end','HIT':'hit_light or hit_heavy',
   'AIR':'air_hit','DOWN':'down','GETUP':'getup','DEAD':'death: heavy reaction -> down -> closed-eye rest','REVIVE':'revive'},
  'turn':'visual turn only; facing/gameplay state stays authoritative; interrupted immediately by attacks',
  'skills':'existing V3/V4/V6, intentionally excluded',
  'reuse':{'death':['hit_heavy frame0:6 ticks','down frame0:8 ticks','closed-eye death rest:28 ticks'],
          'idle':'A-B-A-C; three unique breathing drawings','run_stop':'source guard pivot pose explicitly reused'},
  'height_policy':'CharacterBody physics height only; source height_px is review reference and never added in game',
  'root_policy':'Existing gameplay root motion only; trimmed layer offsets never move the actor'}
 validation={'passed':True,'checks':['source hashes','all source proportion gates','body/finger shared across profiles','real cutting-side binding','exact trim/layer pixel reconstruction','complete integer clocks'],
             'verified_profile_frames':checked,'unique_body_rasters':len(body_hashes),'unique_trimmed_textures':len(textures),
             'artwork_approved':False,'runtime_user_approved':False}
 manifest={'schema':'swordsman_runtime_layers/1','revision':'v7_base_runtime_c5','fps':60,'native_canvas':index['canvas'],
  'anchor':index['anchor'],'native_standing_height':380,'world_scale':.5,'profiles':PROFILES,
  'alpha_mode':'straight','blend':'normal','actor_includes_weapon':False,'hitstop_baked':False,
  'layer_order':['weapon_back','body','weapon_front','fingers'],'clips':clips,'textures':textures,
  'coverage':coverage,'validation':validation,
  'authorization':{'date':'2026-10-18','user':'Finish base actions and continue integration','runtime_trial_allowed':True,'artwork_approved':False,'runtime_user_approved':False}}
 write(OUTPUT/'manifest.json',manifest);write(OUTPUT/'validation.json',validation);write(OUTPUT/'coverage.json',coverage)
 if install:
  GAME.mkdir(parents=True,exist_ok=True)
  for file in [OUTPUT/'manifest.json',OUTPUT/'validation.json',OUTPUT/'coverage.json']+[OUTPUT/x['file']for x in textures.values()]:
   dest=GAME/file.relative_to(OUTPUT);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(file,dest)
 print(json.dumps({'clips':len(clips),**validation,'installed':install},ensure_ascii=False))
 return manifest

if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--install',action='store_true');a=p.parse_args();package(a.install)
