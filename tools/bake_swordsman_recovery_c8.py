"""First-cut recovery candidate with a genuinely drawn off-hand release key.

Accepted c6 idle is read unchanged. New c7 source keys pass G1 before the
body/fingers/replaceable blade are coupled on the same 30-tick clock.
"""
from pathlib import Path
import argparse,copy,hashlib,json,math,os
import numpy as np
from PIL import Image,ImageDraw
from check_actor_proportions import assess
from actor_motion import Tween,geometry
from bake_swordsman_motion import retarget
from explore.swordsman_layer_trial import weapon_image,placement_matrix
from setup_motion_model import FILES

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c7/attack1_c1'
RECOVER=ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c7/attack1_recover_c1'
NEW=SOURCE.parent.parent/'base_batch_c8'
OUT=ROOT/'art/animations/players/swordsman/v7/exports/base_runtime_c8_c3'
OLD=ROOT/'game/assets/swordsman_v7_c6'
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,d):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
def full(ref,folder):
 im=Image.new('RGBA',(1024,1080))
 if ref:im.alpha_composite(Image.open(folder/ref['file']).convert('RGBA'),tuple(ref['rect'][:2]))
 return im

def main():
 global OUT
 parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,default=OUT);parser.add_argument('--arm-controls',action='store_true');args=parser.parse_args();OUT=args.output.resolve();assert OUT.is_relative_to(ROOT)
 model=Path(os.environ.get('SWORDSMAN_RIFE_MODEL',''))
 assert all((model/f).is_file() and sha(model/f)==h for f,h in FILES.items()),'Audited RIFE 4.6 required'
 cfg=read(SOURCE/'body_config.json');g1=assess(SOURCE/'body_config.json',SOURCE/'proportions.json');assert g1['passed'],g1['failures']
 approval=read(SOURCE/'direction_approval.json');assert sha(SOURCE/approval['file'])==approval['sha256']
 bm_path=(SOURCE/cfg['output_dir']/'manifest.json').resolve();bm=read(bm_path);assert bm['config_sha256']==sha(SOURCE/'body_config.json')
 old=read(OLD/'manifest.json');idle=old['clips']['idle']['frames'][0]
 idle_key={'pose':'approved_c6_idle','body':full(idle['body'],OLD),'fingers':full(idle['fingers'],OLD),'geometry':copy.deepcopy(idle['motion_geometry']),'two_hand':False}
 idle_u=np.asarray(idle['profiles']['katana']['basis_u']);idle_v=np.asarray(idle['profiles']['katana']['basis_v'])
 audit=read(SOURCE/'proportions.json');hands=read(SOURCE/'hand_calibration.json');heads={p['pose_id']:p['head']for p in audit['poses']}
 # Explicit source-pixel joint review. Wrist 9/10 is replaced by the actual
 # calibrated shared hilt, rather than inferred a second time.
 joints={
 'load':[[1362,217],[1265,224],[1318,213],[1207,194],[1274,178],[1252,157],[1350,309],[1282,311],[1445,365],[1194,409],[1525,478],[1111,486],[1554,499],[1091,509],[1513,489],[1121,503]],
 'contact':[[468,626],[452,602],[565,627],[551,635],[628,639],[650,636],[480,714],[422,719],[596,756],[314,816],[669,886],[199,887],[704,903],[165,911],[653,901],[208,906]],
 'follow':[[1422,628],[1347,603],[1387,694],[1352,689],[1352,733],[1325,733],[1382,744],[1300,758],[1488,782],[1226,836],[1554,888],[1120,870],[1584,908],[1098,886],[1543,906],[1133,881]],
 'release':[[1260,340],[1105,350],[1320,439],[1068,391],[1227,406],[1195,361],[1240,540],[1170,542],[1485,628],[1019,700],[1542,857],[779,857],[1625,893],[733,901],[1510,887],[772,884]],
 'settled':[[1262,260],[1110,253],[1310,440],[1038,416],[1355,518],[1045,518],[1240,492],[1162,493],[1302,649],[1115,645],[1370,846],[1038,860],[1432,885],[1021,898],[1324,883],[1026,882]],
 'recover':[[1002,285],[855,264],[967,385],[755,321],[842,376],[834,342],[992,469],[910,474],[1046,636],[917,620],[1101,833],[750,798],[1145,879],[760,859],[1090,866],[780,847]]}
 joints['hand_release']=read(NEW/'attack1_hand_release_c1/joint_calibration.json')['points']
 joints.update(read(NEW/'attack1_breakdowns_c1/joint_calibration.json')['points'])
 keys={}
 def prepare(frame,bm_path,hands,heads):
  pid=frame['source_pose'];name=pid.removeprefix('c7_attack1_').removeprefix('c8_attack1_');s=frame['scale'];rx,ry=frame['source_root'];point=lambda p:np.array([448+(p[0]-rx)*s,840+(p[1]-ry)*s])
  head=heads[pid];crown=point(head['hair_top']);chin=point(head['chin']);primary=point(hands[pid]['primary']);secondary=point(hands[pid]['secondary'])
  g={'head_center':((crown+chin)*.5).tolist(),'head_size':float(chin[1]-crown[1]),'head_angle':0.0,'grip':primary.tolist(),'secondary_grip':secondary.tolist(),'root':[448,840],'joints':[point(p).tolist()for p in joints[name]]}
  body=Image.open(bm_path.parent/frame['file']).convert('RGBA');mask=Image.new('L',body.size);draw=ImageDraw.Draw(mask)
  for x,y in [primary,secondary]:draw.ellipse((x-8,y-8,x+8,y+8),fill=255)
  pixels=np.asarray(body);skin=(pixels[:,:,0]>150)&(pixels[:,:,1]>90)&(pixels[:,:,2]>65);alpha=np.asarray(mask).copy();alpha[~skin]=0;mask=Image.fromarray(alpha)
  fingers=Image.composite(body,Image.new('RGBA',body.size),mask);clean=np.asarray(body).copy();channel=Image.new('L',body.size);unit=(primary-secondary)/np.linalg.norm(primary-secondary)if name not in ['settled','hand_release']else (np.array([0.12,-0.9927738917])if name=='hand_release'else idle_u);channel_start=secondary-unit*8 if name not in ['settled','hand_release']else primary-unit*8;ImageDraw.Draw(channel).line([tuple(channel_start),tuple(primary+unit*8)],fill=255,width=5);clean[np.asarray(channel)>0,3]=0;body=Image.fromarray(clean)
  if g['head_size']>54:
   target=copy.deepcopy(g);target['head_center'][1]+=(g['head_size']-54)*.5;target['head_size']=54;body,fingers,g=retarget(body,fingers,g,target)
  span=float(np.linalg.norm(primary-secondary))
  if name in ['sweep','late']:
   tick=hands[pid]['motion_tick'];yaw=math.pi*(tick-8)/5;span/=np.linalg.norm([math.cos(yaw),.22*math.sin(yaw)])
  keys[name]={'pose':pid,'body':body,'fingers':fingers,'geometry':g,'two_hand':name not in ['settled','hand_release'],'span':span,'u':unit}
 for frame in bm['clips']['keys']['frames']:prepare(frame,bm_path,hands,heads)
 rcfg=read(RECOVER/'body_config.json');rg1=assess(RECOVER/'body_config.json',RECOVER/'proportions.json');assert rg1['passed'],rg1['failures']
 rbm_path=(RECOVER/rcfg['output_dir']/'manifest.json').resolve();rbm=read(rbm_path);assert rbm['config_sha256']==sha(RECOVER/'body_config.json')
 rhands=read(RECOVER/'hand_calibration.json');rheads={p['pose_id']:p['head']for p in read(RECOVER/'proportions.json')['poses']}
 for frame in rbm['clips']['keys']['frames']:prepare(frame,rbm_path,rhands,rheads)
 folders=[SOURCE,RECOVER]+[SOURCE.parent/name for name in ['attack1_release_c1','attack1_settled_c1']]+[NEW/'attack1_hand_release_c1',NEW/'attack1_breakdowns_c1']
 for folder in folders[2:]:
  config=read(folder/'body_config.json');gate=assess(folder/'body_config.json',folder/'proportions.json');assert gate['passed'],gate['failures']
  path=(folder/config['output_dir']/'manifest.json').resolve();data=read(path);assert data['config_sha256']==sha(folder/'body_config.json')
  annotations={p['pose_id']:p['head']for p in read(folder/'proportions.json')['poses']};calibration=read(folder/'hand_calibration.json')
  for frame in data['clips']['keys']['frames']:prepare(frame,path,calibration,annotations)
 write(NEW/'pilot_joint_review.json',{'reviewed':True,'method':'Manual source-pixel shoulder/elbow/hip/knee/boot review; not a pose-model confidence approval','joint_order':[5,6,7,8,9,10,11,12,13,14,15,16,20,21,24,25],'source_points':joints,'sources':[{'config':(f/'body_config.json').relative_to(ROOT).as_posix(),'sha256':sha(f/'body_config.json')}for f in folders],'runtime_installed':False})
 textures={};OUT.mkdir(parents=True,exist_ok=True)
 def layer(im):
  box=im.getchannel('A').getbbox()
  if not box:return {}
  cut=im.crop(box);name=hashlib.sha256(str(cut.size).encode()+cut.tobytes()).hexdigest();file='layers/'+name+'.png';path=OUT/file;path.parent.mkdir(exist_ok=True)
  if not path.exists():cut.save(path)
  textures[file]={'file':file,'size':list(cut.size),'sha256':sha(path)};return {'file':file,'rect':[box[0],box[1],box[2]-box[0],box[3]-box[1]]}
 weapon_sources=copy.deepcopy(old['weapon_sources']);weapons={}
 for profile,source in weapon_sources.items():
  raw=Image.open(OLD/source['file']).convert('RGBA');path=OUT/source['file'];path.parent.mkdir(exist_ok=True);raw.save(path);weapons[profile]=(raw,source['marks'],source['physical_blade_length']);textures[source['file']]={'file':source['file'],'size':list(raw.size),'sha256':sha(path)}
 sequence=[(0,idle_key),(3,keys['windup']),(6,keys['load']),(7,keys['release']),(8,keys['contact']),(10,keys['sweep']),(11,keys['late']),(13,keys['follow']),(17,keys['recover_breakdown']),(20,keys['recover']),(22,keys['hand_release']),(25,keys['settled']),(29,idle_key),(30,idle_key)]
 frames=[]
 for segment in range(len(sequence)-1):
  start,a=sequence[segment];end,b=sequence[segment+1];tween=Tween(a['body'],b['body'],a['geometry'],b['geometry'],a['fingers'],b['fingers'],arms=args.arm_controls,protect_head=True,opaque_silhouette=True)
  for tick in range(start,end):
   t=(tick-start)/(end-start);g=geometry(a['geometry'],b['geometry'],t)
   if 8<=tick<13:
    yaw=math.pi*(tick-8)/5;u=np.array([math.cos(yaw),.22*math.sin(yaw)]);side=1.0
   else:
    ua=a.get('u',idle_u);ub=b.get('u',idle_u);aa=math.atan2(ua[1],ua[0]);ab=math.atan2(ub[1],ub[0])
    if start==13:
     aa=math.pi
     while ab<aa:ab+=math.tau
    else:ab=aa+(ab-aa+math.pi)%math.tau-math.pi
    angle=aa*(1-t)+ab*t;u=np.array([math.cos(angle),math.sin(angle)]);side=1.0
   if abs(side)<.025:side=.025
   normal=np.array([-u[1],u[0]])/np.linalg.norm(u);v=normal*side
   if a['two_hand'] and b['two_hand']:
    span=a['span']*(1-t)+b['span']*t;secondary=np.asarray(g['grip'])-u*span;offset=secondary-np.asarray(g['secondary_grip']);g['secondary_grip']=secondary.tolist();g['joints'][4]=(np.asarray(g['joints'][4])+offset).tolist()
   pixels,fingers,g=tween.sample(t,g);frame={'source_pose':a['pose'],'target_pose':b['pose'],'source_mix':t,'start_tick':tick,'duration_ticks':1,'height_px':0,'root_dx':0,'body':layer(Image.fromarray(pixels)),'fingers':layer(Image.fromarray(fingers)),'motion_geometry':g,'profiles':{}}
   for profile,(raw,wm,length)in weapons.items():
    pu,pv=u,v
    if not a['two_hand']or not b['two_hand']:
     # Accepted idle already has a slightly safer greatsword wrist pitch.
     # Preserve each actual weapon endpoint, rather than copying katana's
     # pitch to a longer blade and clipping it into the ground.
     idle_profile=idle['profiles'][profile];iu=np.asarray(idle_profile['basis_u']);iv=np.asarray(idle_profile['basis_v'])
     if a['pose']in ['approved_c6_idle','c7_attack1_settled']and b['pose']in ['approved_c6_idle','c7_attack1_settled']:pu,pv=iu,iv
     else:
      ua=iu if a['pose']in ['approved_c6_idle','c7_attack1_settled']else a['u'];ub=iu if b['pose']in ['approved_c6_idle','c7_attack1_settled']else b['u'];aa=math.atan2(ua[1],ua[0]);ab=math.atan2(ub[1],ub[0])
      if start==13:
       aa=math.pi
       while ab<aa:ab+=math.tau
      else:ab=aa+(ab-aa+math.pi)%math.tau-math.pi
      angle=aa*(1-t)+ab*t;pu=np.array([math.cos(angle),math.sin(angle)]);pv=np.array([-pu[1],pu[0]])*side
    angle=math.atan2(pu[1],pu[0]);rendered,sampling=weapon_image(raw,wm,(1024,1080),g['grip'],angle,length,(pu,pv));matrix,_=placement_matrix(wm,angle,length,(pu,pv));ma,mb,mc,md=matrix
    def placed(mark):
     dx,dy=np.asarray(mark)-wm['grip'];return [float(g['grip'][0]+ma*dx+mb*dy),float(g['grip'][1]+mc*dx+md*dy)]
    tip=placed(wm['tip']);assert tip[1]<=844,(tick,profile,'blade crosses floor',tip)
    frame['profiles'][profile]={'front':layer(rendered),'back':{},'grip':g['grip'],'guard':placed(wm['guard']),'tip':tip,'cutting_edge':placed(wm['cutting_edge']),'spine':placed(wm['spine']),'basis_u':pu.tolist(),'basis_v':pv.tolist(),'matrix':list(matrix),'source_sampling_scale':sampling,'physical_blade_length':length}
   frames.append(frame)
  print(a['pose'],'->',b['pose'],end-start,flush=True)
 manifest={'schema':'swordsman_runtime_layers/2','revision':'v7_c8_first_cut_'+OUT.name.removeprefix('base_runtime_c8_'),'fps':60,'native_canvas':[1024,1080],'anchor':[448,840],'clips':{'attack1':{'semantic_id':'actor.player.base.combo.1','duration_ticks':30,'loop':False,'frames':frames}},'textures':textures,'weapon_sources':weapon_sources,'source_inputs':[{'config':(folder/'body_config.json').relative_to(ROOT).as_posix(),'sha256':sha(folder/'body_config.json'),'audit_sha256':sha(folder/'proportions.json'),'manifest_sha256':sha((folder/read(folder/'body_config.json')['output_dir']/'manifest.json').resolve())}for folder in folders],'coverage':{'complete':False,'reason':'one representative clip, never auto install'},'authorization':{'runtime_trial_allowed':False,'direction_approval':(SOURCE/'direction_approval.json').relative_to(ROOT).as_posix()},'validation':{'source_G1_passed':True,'source_keys':12,'sampling_frames':30,'head_upscale':False,'artwork_approved':False,'G3_approved':False,'runtime_user_approved':False},'recipe':{f:sha(ROOT/'tools'/f)for f in ['bake_swordsman_recovery_c8.py','actor_motion.py','motion_neural.py']}}
 write(OUT/'manifest.json',manifest);print('Pilot exported; game package untouched',flush=True)

if __name__=='__main__':main()
