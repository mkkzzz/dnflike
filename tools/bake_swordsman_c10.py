"""Whole-person run and three-cut continuation, native actor pixels and shared weapons.

No isolated leg/torso rig. Source proportion checks run before uniform downscale.
Intermediate body rasters use whole-image correspondence; anatomy landmarks only
align heads and actual grips, never independently pose or assemble legs.
"""
from pathlib import Path
import argparse,copy,hashlib,json,math,os
import numpy as np
from PIL import Image,ImageDraw
from check_actor_proportions import preflight
from explore.standard_actions_pilot import load_sources,export_pose
from explore.swordsman_layer_trial import weapon_image,placement_matrix
from actor_motion import geometry
from whole_body_motion import WholeBodyTween as Tween
from setup_motion_model import FILES

ROOT=Path(__file__).resolve().parents[1]
SRC=ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c10'
OUT=ROOT/'art/animations/players/swordsman/v7/exports/run_combo_c10'
BASE=ROOT/'game/assets/swordsman_v7_c6'
C8=ROOT/'art/animations/players/swordsman/v7/exports/first_cut_c8_trial'
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,d):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
def full(ref,folder):
 im=Image.new('RGBA',(1024,1080))
 if ref:im.alpha_composite(Image.open(folder/ref['file']).convert('RGBA'),tuple(ref['rect'][:2]))
 return im

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--only',nargs='*');args=parser.parse_args()
 model=Path(os.environ.get('SWORDSMAN_RIFE_MODEL',''))
 assert all((model/f).is_file()and sha(model/f)==h for f,h in FILES.items()),'Audited RIFE required'
 OUT.mkdir(parents=True,exist_ok=True);textures={};sources=[];keys={};base=read(BASE/'manifest.json');oldfirst=read(C8/'manifest.json')
 def layer(im):
  box=im.getchannel('A').getbbox()
  if not box:return {}
  cut=im.crop(box);file='layers/'+hashlib.sha256(str(cut.size).encode()+cut.tobytes()).hexdigest()+'.png';p=OUT/file;p.parent.mkdir(exist_ok=True)
  if not p.exists():cut.save(p)
  textures[file]={'file':file,'size':list(cut.size),'sha256':sha(p)}
  return {'file':file,'rect':[box[0],box[1],box[2]-box[0],box[3]-box[1]]}
 def from_frame(frame,folder,name,two=False):
  g=copy.deepcopy(frame['motion_geometry']);g.pop('joints',None)
  p=frame['profiles']['katana'];u=np.asarray(p['basis_u']);v=np.asarray(p['basis_v'])
  return {'name':name,'body':full(frame['body'],folder),'fingers':full(frame['fingers'],folder),'g':g,'u':u,'v':v,'two':two,'span':float(np.linalg.norm(np.asarray(g['grip'])-g['secondary_grip']))}
 idle=from_frame(base['clips']['idle']['frames'][0],BASE,'accepted_idle');keys['idle']=idle
 for name,tick in [('first_load',6),('first_follow',13),('recover',20),('hand_release',22),('settled',25)]:keys[name]=from_frame(oldfirst['clips']['attack1']['frames'][tick],C8,'c8_'+name,name in ['first_load','first_follow','recover'])
 def load_keys(folder):
  folder=Path(folder);cfgpath=folder/'body_config.json';cfg=read(cfgpath);audit=read(folder/'proportions.json')
  assert audit['landmark_semantics_reviewed']and audit['visual_review']['reviewed'],cfgpath
  assert sha(folder/audit['visual_review']['overlay'])==audit['visual_review']['sha256']
  gate=preflight(cfgpath,cfg);raws=load_sources(cfg,folder);hands=read(folder/'hand_calibration.json');ann={p['pose_id']:p['head']for p in audit['poses']}
  keyout=OUT/'key_sources'/sha(cfgpath)[:12];keyout.mkdir(parents=True,exist_ok=True);records=[]
  for clip in cfg['clips'].values():
   for pose in clip['poses']:
    marks=ann[pose['id']];pose=copy.deepcopy(pose);pose['landmarks'].update(proportion_hair_top=marks['hair_top'],proportion_chin=marks['chin'])
    masks=[];body,record=export_pose(pose,raws[pose['source']],tuple(cfg['canvas']),tuple(cfg['anchor']),cfg['target_standing_height'],clip['root_mode'],mask_files=masks)
    file='actor/'+pose['id']+'.png';p=keyout/file;p.parent.mkdir(exist_ok=True);body.save(p)
    for filemask,mask in masks:
     p=keyout/filemask;p.parent.mkdir(parents=True,exist_ok=True);mask.save(p)
    record.update(file=file,source_pose=pose['id']);records.append(record)
    s=record['scale'];rx,ry=record['source_root'];point=lambda p:np.array([448+(p[0]-rx)*s,840+(p[1]-ry)*s])
    h=hands[pose['id']]if pose['id']in hands else hands
    if h.get('finger_region'):h={**h,'finger_polygon':h['finger_region']}
    primary=point(h['primary']);secondary=point(h['secondary'])if h.get('secondary')else None
    crown,chin=point(marks['hair_top']),point(marks['chin']);g={'head_center':((crown+chin)/2).tolist(),'head_size':float(chin[1]-crown[1]),'head_angle':0.,'root':[448,840],'grip':primary.tolist()}
    # The free wrist is only a correspondence anchor, never a second hilt grip.
    g['secondary_grip']=(secondary if secondary is not None else np.array([primary[0]+215*s,primary[1]-115*s])).tolist()
    mask=Image.new('L',body.size);d=ImageDraw.Draw(mask)
    if h.get('finger_polygon'):d.polygon([tuple(point(p))for p in h['finger_polygon']],fill=255)
    else:
     for p in [primary]+([secondary]if secondary is not None else[]):
      x,y=p;d.ellipse((x-11,y-12,x+11,y+11),fill=255)
    fingers=Image.composite(body,Image.new('RGBA',body.size),mask)
    u=np.asarray(h.get('blade_axis')if h.get('blade_axis')else primary-secondary);u=u/np.linalg.norm(u)
    v=np.array([-u[1],u[0]])*(-1 if 'attack3'in pose['id']else 1)
    name=pose['id'].removeprefix('c10_');keys[name]={'name':pose['id'],'body':body,'fingers':fingers,'g':g,'u':u,'v':v,'two':secondary is not None,'span':float(np.linalg.norm(primary-secondary))if secondary is not None else 0}
  write(keyout/'manifest.json',{'schema':'standard_actions_pilot/1','fps':60,'config_sha256':sha(cfgpath),'proportion_gate':gate,'clips':{'keys':{'frames':records}},'source_mode':'whole-person uniform downscale only'})
  sources.append({'config':cfgpath.relative_to(ROOT).as_posix(),'sha256':sha(cfgpath),'audit_sha256':sha(folder/'proportions.json'),'hand_sha256':sha(folder/'hand_calibration.json'),'body_manifest':(keyout/'manifest.json').relative_to(ROOT).as_posix(),'body_manifest_sha256':sha(keyout/'manifest.json')})
 for name in ['pass_near','push_near','pre_far','pass_far','push_far','pre_near','contact_near_new','contact_far_new','drive_near','drive_far','flight_far','flight_near']:load_keys(SRC/'run_pairs'/name)
 for name in ['run_c','attack3','combo_breakdowns']:load_keys(SRC/name)
 # Accepted C3 contact is a complete clean drawing with the same native proportion gate.
 keys['run_contact']=keys['run_contact_near_new']
 # Existing low load for third cut has its own verified same-sheet ruler.
 load_keys(ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c8/attack3_load_c1')
 # Reuse the reviewed second-cut body keys, without another head normalization.
 load_keys(ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c8/attack2_c1')
 def find(suffix):
  names=[k for k in keys if k.endswith(suffix)];assert len(names)==1,(suffix,names);return keys[names[0]]
 library_path=ROOT/'art/concepts/characters/players/swordsman/v7/weapon/grip_c8_c1/exports/manifest.json';library=read(library_path);weapons={};weapon_sources={}
 for profile,spec in library['weapons'].items():
  p=ROOT/spec['file'];assert sha(p)==spec['sha256'];im=Image.open(p).convert('RGBA');file='weapons_c10/'+profile+'.png';dest=OUT/file;dest.parent.mkdir(exist_ok=True);im.save(dest);textures[file]={'file':file,'size':list(im.size),'sha256':sha(dest)};weapons[profile]=(im,spec['marks'],spec['physical_blade_length']);weapon_sources[profile]=copy.deepcopy(spec);weapon_sources[profile]['file']=file
 runseq=[(0,keys['run_contact']),(7,keys['run_pass_near']),(10,keys['run_drive_near']),(12,keys['run_push_near']),(13,keys['run_flight_far']),(15,keys['run_pre_far']),(18,keys['run_contact_far_new']),(25,keys['run_pass_far']),(28,keys['run_drive_far']),(30,keys['run_push_far']),(31,keys['run_flight_near']),(33,keys['run_pre_near']),(36,keys['run_contact'])]
 sequences={'run':runseq,'run_start':[(0,idle),(4,keys['run_start']),(9,keys['run_contact'])],
  'run_stop':[(0,keys['run_contact']),(3,keys['run_brake']),(6,keys['run_settle']),(9,idle),(10,idle)],
  'attack2':[(0,keys['first_follow']),(5,find('attack2_load')),(8,keys['attack2_release']),(12,find('attack2_contact')),(16,find('attack2_follow')),(21,keys['attack3_recover']),(25,keys['recover']),(27,keys['hand_release']),(31,idle),(32,idle)],
  'attack3':[(0,find('attack2_follow')),(5,find('attack3_load')),(9,keys['attack3_drive']),(13,keys['attack3_lift']),(18,keys['attack3_follow']),(23,keys['attack3_recover']),(29,keys['recover']),(33,keys['hand_release']),(37,keys['settled']),(40,idle),(41,idle)]}
 clips={}
 # First cut retains its actual C8 body/finger samples and clock; all weapons are re-hung from the shared canonical library.
 def profile_pixels(frame,u,v,profile):
  raw,marks,length=weapons[profile];g=frame['motion_geometry'];angle=math.atan2(u[1],u[0]);im,sampling=weapon_image(raw,marks,(1024,1080),g['grip'],angle,length,(u,v));matrix,_=placement_matrix(marks,angle,length,(u,v));a,b,c,d=matrix
  def place(mark):
   x,y=np.asarray(mark)-marks['grip'];return [float(g['grip'][0]+a*x+b*y),float(g['grip'][1]+c*x+d*y)]
  tip=place(marks['tip']);assert tip[1]<=844,(frame['source_pose'],profile,frame['start_tick'],'blade crosses floor',tip)
  return {'front':layer(im),'back':{},'grip':g['grip'],'guard':place(marks['guard']),'tip':tip,'cutting_edge':place(marks['cutting_edge']),'spine':place(marks['spine']),'basis_u':np.asarray(u).tolist(),'basis_v':np.asarray(v).tolist(),'matrix':list(matrix),'source_sampling_scale':sampling,'physical_blade_length':length}
 if not args.only or 'attack1'in args.only:
  frames=[]
  for old in oldfirst['clips']['attack1']['frames']:
   f=copy.deepcopy(old);f['body']=layer(full(old['body'],C8));f['fingers']=layer(full(old['fingers'],C8));f['motion_geometry']['joints']=[];f['profiles']={}
   for profile in weapons:
    p=old['profiles'][profile];f['profiles'][profile]=profile_pixels(f,np.asarray(p['basis_u']),np.asarray(p['basis_v']),profile)
   frames.append(f)
  clips['attack1']={**copy.deepcopy(oldfirst['clips']['attack1']),'frames':frames}
 for name,sequence in sequences.items():
  if args.only and name not in args.only:continue
  frames=[]
  for (start,a),(end,b)in zip(sequence,sequence[1:]):
   tween=Tween(a['body'],b['body'],a['g'],b['g'],a['fingers'],b['fingers'],arms=False,protect_head=True,opaque_silhouette=True)
   profile_paths={}
   for profile,(_,marks,length)in weapons.items():
    ip=base['clips']['idle']['frames'][0]['profiles'][profile]
    ua=np.asarray(ip['basis_u'])if a['name']=='accepted_idle'else a['u'];ub=np.asarray(ip['basis_u'])if b['name']=='accepted_idle'else b['u']
    pa=math.atan2(ua[1],ua[0]);pb=pa+(math.atan2(ub[1],ub[0])-pa+math.pi)%math.tau-math.pi
    def safe_profile(target):
     for pt in np.linspace(0,1,35):
      pg=geometry(a['g'],b['g'],float(pt));ang=pa*(1-pt)+target*pt;pu=np.array([math.cos(ang),math.sin(ang)]);pv=np.array([-pu[1],pu[0]])
      matrix,_=placement_matrix(marks,ang,length,(pu,pv));ma,mb,mc,md=matrix;dx,dy=np.asarray(marks['tip'])-marks['grip']
      if pg['grip'][1]+mc*dx+md*dy>843:return False
     return True
    valid_profile=[p for p in [pb,pb+math.tau,pb-math.tau]if safe_profile(p)]
    assert valid_profile,(name,start,end,profile,'No safe authored recovery arc')
    profile_paths[profile]=(pa,min(valid_profile,key=lambda p:abs(p-pa)))
   aa=math.atan2(a['u'][1],a['u'][0]);ab=math.atan2(b['u'][1],b['u'][0]);ab=aa+(ab-aa+math.pi)%math.tau-math.pi
   # Prefer a continuous recovery arc above the floor; evaluate physical longest blade before baking.
   choices=[ab,ab+math.tau,ab-math.tau]
   def safe(target):
    for t in np.linspace(0,1,25):
     g=geometry(a['g'],b['g'],float(t));ang=aa*(1-t)+target*t
     if g['grip'][1]+math.sin(ang)*340>838:return False
    return True
   valid=[x for x in choices if safe(x)];target=min(valid,key=lambda v:abs(v-aa))if valid else ab
   for tick in range(start,end):
    t=(tick-start)/(end-start);g=geometry(a['g'],b['g'],t);angle=aa*(1-t)+target*t;u=np.array([math.cos(angle),math.sin(angle)]);v=np.array([-u[1],u[0]])
    if name=='attack2'and 8<=tick<=12:
     yaw=math.pi*(tick-8)/4;u=np.array([-math.cos(yaw),-.22*math.sin(yaw)]);v=np.array([-u[1],u[0]])/np.linalg.norm(u)
    elif name=='attack3':v=-v
    if a['two']and b['two']:
     span=a['span']*(1-t)+b['span']*t;g['secondary_grip']=(np.asarray(g['grip'])-u*span).tolist()
    body,fingers,g=tween.sample(t,g);g['joints']=[]
    actual_two_hand=a['two']and b['two']
    if actual_two_hand:
     delta=np.asarray(g['grip'])-g['secondary_grip'];span=a['span']*(1-t)+b['span']*t
     u=delta/max(1e-6,span)
     if np.linalg.norm(u)>1:u/=np.linalg.norm(u)
     if np.linalg.norm(u)<.035:u=np.array([u[0],-.035])
     v=np.array([-u[1],u[0]])/np.linalg.norm(u)*(-1 if name in ['attack2','attack3']else 1)
     if name=='attack2':
      # The near/right primary stays left of the offhand through release.
      # During active frames the hilt crosses the camera plane continuously.
      if 8<=tick<=12:
       yaw=math.pi*(tick-8)/4;u=np.array([-math.cos(yaw),-.22*math.sin(yaw)])
       g['secondary_grip']=(np.asarray(g['grip'])-u*span).tolist()
      v=np.array([-u[1],u[0]])/np.linalg.norm(u)
    f={'source_pose':a['name'],'target_pose':b['name'],'source_mix':t,'start_tick':tick,'duration_ticks':1,'height_px':0,'root_dx':0,'body':layer(Image.fromarray(body)),'fingers':layer(Image.fromarray(fingers)),'motion_geometry':g,'profiles':{}}
    for profile in weapons:
     pu,pv=u,v
     if not actual_two_hand and not (name=='attack2'and 8<=tick<=12):
      pa,pb=profile_paths[profile];angle=pa*(1-t)+pb*t;pu=np.array([math.cos(angle),math.sin(angle)]);normal=np.array([-pu[1],pu[0]])
      if name=='run':side=-1.
      elif name=='run_start':side=1-2*t if a['name']=='accepted_idle'else -1.
      elif name=='run_stop':side=-1+2*t if b['name']=='accepted_idle'else -1.
      elif name=='attack3':side=-1.
      else:side=1.
      if abs(side)<.025:side=.025 if side>=0 else -.025
      pv=normal*side
      if a['name']==b['name']=='accepted_idle':
       ip=base['clips']['idle']['frames'][0]['profiles'][profile];pu=np.asarray(ip['basis_u']);pv=np.asarray(ip['basis_v'])
     f['profiles'][profile]=profile_pixels(f,pu,pv,profile)
    frames.append(f)
   print(name,start,end,a['name'],'->',b['name'],flush=True)
  clip={'semantic_id':base['clips'][name]['semantic_id'],'duration_ticks':sequence[-1][0],'loop':name=='run','root_mode':'ground','frames':frames};clips[name]=clip
  write(OUT/(name+'.checkpoint.json'),clip)
 manifest={'schema':'swordsman_runtime_layers/2','revision':'v7_c10_run_combo','fps':60,'native_canvas':[1024,1080],'anchor':[448,840],
  'clips':clips,'textures':textures,'weapon_sources':weapon_sources,'weapon_library':{'manifest':library_path.relative_to(ROOT).as_posix(),'sha256':sha(library_path)},
  'source_inputs':sources,'whole_body_motion':True,'whole_body_method':'full painted source poses + whole-image correspondence, no leg cutout/IK assembly or per-pose head resize',
  'reused_first_cut':{'manifest':(C8/'manifest.json').relative_to(ROOT).as_posix(),'sha256':sha(C8/'manifest.json')},
  'validation':{'passed':set(clips)=={'run','run_start','run_stop','attack1','attack2','attack3'},'source_G1_passed':True,'head_upscale':False,'artwork_approved':False,'runtime_user_approved':False},
  'authorization':{'runtime_trial_allowed':True,'user_instruction':'2026-10-22 按照这个逻辑继续制作，完成跑动、三段普攻的实装'},
  'coverage':{'complete':False,'reason':'six-clip overlay; all remaining clips inherit installed c6 unchanged'},
  'recipe':{file:sha(ROOT/'tools'/file)for file in ['bake_swordsman_c10.py','whole_body_motion.py','actor_motion.py','motion_neural.py','explore/standard_actions_pilot.py','explore/swordsman_layer_trial.py']}}
 write(OUT/'manifest.json',manifest);print('C10 overlay exported',len(clips),flush=True)

if __name__=='__main__':main()
