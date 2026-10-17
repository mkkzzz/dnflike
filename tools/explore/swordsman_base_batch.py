"""Rebuild the explicit, source-bound c4 non-skill animation batch.

No generated art, pose-grid inference, per-pose scale normalization or gameplay
changes. Body calibration and weapon edge directions are authored source data.
"""
from __future__ import annotations
import argparse,json,math,os,subprocess,sys,hashlib
from pathlib import Path
from PIL import Image,ImageOps,ImageDraw,ImageFont
if __package__:
 from .swordsman_layer_trial import sha,read
else:
 from swordsman_layer_trial import sha,read

ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c4'
OUTPUT=ROOT/'art/animations/players/swordsman/v7/exports/base_batch_c4'

def write(path,value):
 path.parent.mkdir(parents=True,exist_ok=True)
 path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')

def relative(path,base):return os.path.relpath(path,base).replace('\\','/')

def annotation_signature(audit):
 value={key:audit[key] for key in ['sources','poses','profile_sha256']}
 return hashlib.sha256(json.dumps(value,sort_keys=True,ensure_ascii=False).encode('utf-8')).hexdigest()

def prepare_group(group):
 folder=SOURCE/group
 body_config=folder/'body_config.json';config=read(body_config)
 audit=read(folder/'proportions.json');review=audit.get('visual_review',{})
 if not audit.get('landmark_semantics_reviewed'):
  raise ValueError('Review the true jaw/hair overlay before exporting '+group)
 if review.get('annotation_signature')!=annotation_signature(audit) or not review.get('files'):
  raise ValueError('Missing/stale visual annotation review binding for '+group)
 for evidence in review['files']:
  if sha(folder/evidence['file'])!=evidence['sha256']:raise ValueError('Changed visual annotation evidence')
 subprocess.run([sys.executable,str(ROOT/'tools/explore/standard_actions_pilot.py'),str(body_config),'--overwrite'],check=True)
 body_manifest=(folder/config['output_dir']/'manifest.json').resolve();body=read(body_manifest)
 if group=='attack1':
  path=folder/'layer_config.json';c=read(path)
  for f in body['clips']['attack1']['frames']:c['poses'][f['source_pose']]['body_sha256']=sha(body_manifest.parent/f['file'])
  write(path,c)
  subprocess.run([sys.executable,str(ROOT/'tools/explore/swordsman_layer_trial.py'),str(path),'--overwrite'],check=True)
  return {'attack1':{'manifest':'attack1/manifest.json','loop':False,'root_mode':'ground','duration_ticks':30,'source_group':'attack1','frame_count':7}}
 calibration=read(folder/'pose_calibration.json')
 template=read(SOURCE/'attack1/layer_config.json')
 guide={'schema':'authored_weapon_plane/1','camera':{'yaw':0,'pitch':0},
        'method':'Source-calibrated screen blade angle, explicit cutting side and authored depth proxy. Not a recovered 3D body rig.',
        'frames':[]}
 for p in calibration:
  angle=math.radians(p['blade_angle_degrees']);f=p.get('blade_foreshortening',1.0);side=p['cutting_side']
  if not .2<=f<=1 or side not in [-1,1]:raise ValueError('Invalid authored weapon plane')
  guide['frames'].append({'pose_cm':{'blade_dir':[f*math.cos(angle),-f*math.sin(angle),math.sqrt(1-f*f)],
                         'blade_edge':[-side*math.sin(angle),-side*math.cos(angle),0]},
                         'intent':p['edge_intent']})
 write(folder/'weapon_guide.json',guide)
 result={}
 for name,clip in body['clips'].items():
  if name=='neutral':continue
  path=folder/('layer_'+name+'.json')
  c={'revision':'v7_base_batch_c4_'+name,'clip_name':name,'duration_ticks':clip['duration_ticks'],
     'output_dir':relative(OUTPUT/name,folder),'body_manifest':relative(body_manifest,folder),
     'body_config':'body_config.json','body_audit':'proportions.json',
     'katana_blade_length_px':256,'edge_contract':template['edge_contract'],
     'projection_guide':{'file':'weapon_guide.json','sha256':sha(folder/'weapon_guide.json')},
     'weapons':{},'poses':{},'limitations':[
      'Batch art candidate under user-authorized direction; not final art or runtime approval.',
      'Shared body/finger pixels and clocks across katana/greatsword/shortsword; right-hand forward grip.',
      'Explicit source-calibrated weapon planes, not full 3D reconstruction or automatic depth solving.',
      'No skills, FX, equipment UI, damage/reach or gameplay timing changes. Runtime adapter pending.']}
  for key,w in template['weapons'].items():
   w=dict(w);w['file']=relative((SOURCE/'attack1'/w['file']).resolve(),folder);c['weapons'][key]=w
  for frame in clip['frames']:
   pid=frame['source_pose'];i=int(pid.rsplit('_',1)[1]);p=calibration[i]
   angle=math.radians(p['blade_angle_degrees']);gx,gy=p['grip']
   c['poses'][pid]={'body_sha256':sha(body_manifest.parent/frame['file']),
       'grip':p['grip'],'guard':[gx+25*math.cos(angle),gy+25*math.sin(angle)],
       'tip':[gx+285*math.cos(angle),gy+285*math.sin(angle)],
       'weapon_layer':p.get('weapon_layer','front'),'finger_polygon':p['finger_polygon'],
       'guide_pose_index':i,'cutting_direction':[-p['cutting_side']*math.sin(angle),p['cutting_side']*math.cos(angle)],
       'edge_intent':p['edge_intent'],'allow_edge_roll_from_previous':p.get('allow_edge_roll_from_previous',False),
       'tip_basis':'authored_axis_after_removal_not_falsely_observed_tip'}
  write(path,c)
  subprocess.run([sys.executable,str(ROOT/'tools/explore/swordsman_layer_trial.py'),str(path),'--overwrite'],check=True)
  result[name]={'manifest':relative(OUTPUT/name/'manifest.json',OUTPUT),'loop':config['clips'][name]['loop'],
                'root_mode':clip['root_mode'],'duration_ticks':clip['duration_ticks'],
                'source_group':group,'frame_count':len(clip['frames'])}
 return result

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('groups',nargs='*')
 args=parser.parse_args();groups=args.groups or read(SOURCE/'batch_spec.json')['groups']
 result={}
 for group in groups:result.update(prepare_group(group))
 path=OUTPUT/'manifest.json';old=read(path) if path.exists() else {}
 clips={**old.get('clips',{}),**result}
 a=OUTPUT/'attack1/manifest.json'
 if a.exists():clips['attack1']={'manifest':'attack1/manifest.json','loop':False,'root_mode':'ground','duration_ticks':30,'source_group':'attack1','frame_count':7}
 write(path,{'schema':'swordsman_base_batch/1','revision':'v7_base_batch_c4','fps':60,
             'canvas':[1024,1080],'anchor':[448,840],'target_standing_height':380,
             'actor_includes_weapon':False,'hitstop_baked':False,'clips':clips,
             'scope':'non-skill base actions; explicit reuse and state mappings in coverage.json',
             'artwork_approved':False,'integration_allowed':False})
 print(json.dumps({'clips':len(clips),'groups_rebuilt':groups},ensure_ascii=False))

if __name__=='__main__':main()
