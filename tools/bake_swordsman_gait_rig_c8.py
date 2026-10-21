"""Offline articulated gait pilot using painted cutouts, never leg optical flow.

Original RGBA is cropped/masked and transformed. Head size and the accepted
idle remain guarded separately. Generated parts have independent attachment
scales; they are not falsely treated as same-scale companion drawings.
"""
from pathlib import Path
import copy,hashlib,json,math
import cv2,numpy as np
from PIL import Image,ImageDraw
from check_actor_proportions import assess
from bake_swordsman_motion import retarget
from explore.swordsman_layer_trial import weapon_image,placement_matrix

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c8'
BASE=ROOT/'game/assets/swordsman_v7_c6'
OUT=ROOT/'art/animations/players/swordsman/v7/exports/gait_rig_c8_pilot'
CANVAS=(1024,1080)
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,d):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
def rotation(angle):return np.array([[math.cos(angle),-math.sin(angle)],[math.sin(angle),math.cos(angle)]])
def masked(raw,mask):
 a=np.asarray(raw).copy();a[~mask,3]=0;return Image.fromarray(a)
def warp(raw,pivot,target,matrix):
 assert np.linalg.svd(matrix,compute_uv=False).max()<=1.000001,'Source enlargement forbidden'
 inv=np.linalg.inv(matrix);offset=np.asarray(pivot)-inv@target
 return raw.convert('RGBa').transform(CANVAS,Image.Transform.AFFINE,tuple(np.c_[inv,offset].ravel()),resample=Image.Resampling.BICUBIC).convert('RGBA')
def bone_matrix(a,b,start,end,width):
 axis=np.asarray(b)-a;length=np.linalg.norm(axis);u=axis/length;v=np.array([-u[1],u[0]]);delta=np.asarray(end)-start;du=delta/np.linalg.norm(delta);dv=np.array([-du[1],du[0]])
 return np.c_[du,dv]@np.diag([np.linalg.norm(delta)/length,width])@np.c_[u,v].T
def knee(hip,ankle,thigh,shin,context=''):
 delta=ankle-hip;distance=float(np.linalg.norm(delta));assert distance<thigh+shin,(context,distance,thigh+shin,'Unreachable gait target')
 along=(thigh*thigh-shin*shin+distance*distance)/(2*distance);height=math.sqrt(max(0,thigh*thigh-along*along));axis=delta/distance;side=np.array([axis[1],-axis[0]])
 return hip+axis*along+side*height
def smooth(t):return t*t*(3-2*t)

def main():
 cal_path=SOURCE/'gait_rig_calibration.json';cal=read(cal_path);cfgpath=SOURCE/cal['upper']['config'];cfg=read(cfgpath);folder=cfgpath.parent;assert assess(cfgpath,folder/'proportions.json')['passed']
 for review in cal['attachment_reviews']:assert review['reviewed']and sha(SOURCE/review['file'])==review['sha256']
 bm=(folder/cfg['output_dir']/'manifest.json').resolve();data=read(bm);assert data['config_sha256']==sha(cfgpath);f=data['clips']['keys']['frames'][0];scale=f['scale'];rx,ry=f['source_root'];point=lambda p:np.array([448+(p[0]-rx)*scale,840+(p[1]-ry)*scale]);ann=read(folder/'proportions.json')['poses'][0]['head'];top=point(ann['hair_top']);chin=point(ann['chin']);primary=point(cal['upper']['grip'])
 recipe_files=['bake_swordsman_gait_rig_c8.py','bake_swordsman_motion.py','actor_motion.py','check_actor_proportions.py','explore/swordsman_layer_trial.py']
 bindings={path:sha(path)for path in [cal_path,cfgpath,folder/'proportions.json',bm,SOURCE/cal['arm']['file'],SOURCE/cal['leg_source']['file']]+[ROOT/'tools'/f for f in recipe_files]}
 sourcebody=Image.open(bm.parent/f['file']).convert('RGBA');g={'head_center':((top+chin)*.5).tolist(),'head_size':float(chin[1]-top[1]),'head_angle':0.,'grip':primary.tolist(),'root':[448,840],'joints':[point(cal['upper'][key]).tolist()for key in ['shoulder_near','shoulder_far','elbow_near','elbow_far_reference','grip','grip','hip_near','hip_far']]}
 empty=Image.new('RGBA',CANVAS)
 if g['head_size']>54:
  target=copy.deepcopy(g);target['head_center'][1]+=(g['head_size']-54)*.5;target['head_size']=54;sourcebody,_,g=retarget(sourcebody,empty,g,target)
 pixels=np.asarray(sourcebody);red=((pixels[:,:,0].astype(float)>pixels[:,:,1]*1.5)&(pixels[:,:,0].astype(float)>pixels[:,:,2]*1.25)&(pixels[:,:,0]>18)&(pixels[:,:,3]>128)).astype('uint8');red[:int(point([1120,445])[1])]=0
 n,labels,stats,centers=cv2.connectedComponentsWithStats(red,8);seed=np.rint(point(cal['upper']['back_coat_seed'])).astype(int);label=labels[seed[1],seed[0]];assert label>0,'Back coat seed must select painted red lining'
 coat=(labels==label).astype('uint8');contours,_=cv2.findContours(coat,cv2.RETR_EXTERNAL,cv2.CHAIN_APPROX_SIMPLE);cv2.drawContours(coat,contours,-1,1,-1);coat=cv2.dilate(coat,np.ones((5,5),np.uint8))>0
 back=masked(sourcebody,coat);front=masked(sourcebody,~coat)
 headmask=Image.new('L',CANVAS);ImageDraw.Draw(headmask).polygon([tuple(point(p))for p in cal['upper']['head_polygon']],fill=255);headmask=np.asarray(headmask)>0
 head=masked(front,headmask);front=masked(front,~headmask)
 hip_native={name:point(cal['upper']['hip_'+name])for name in ['near','far']};pivot=(hip_native['near']+hip_native['far'])*.5;neck=np.asarray(g['head_center'])+np.array([0,g['head_size']*.55])
 arm_spec=cal['arm'];arm_box=arm_spec['crop'];arm=Image.open(SOURCE/arm_spec['file']).convert('RGBA').crop(arm_box);arm_pivot=np.asarray(arm_spec['pivot'])-arm_box[:2];arm_wrist=np.asarray(arm_spec['wrist'])-arm_box[:2];arm_elbow=np.asarray(arm_spec['elbow'])-arm_box[:2]
 ay,ax=np.mgrid[:arm.height,:arm.width];arm_axis=(arm_elbow-arm_pivot)/np.linalg.norm(arm_elbow-arm_pivot);along=(ax-arm_elbow[0])*arm_axis[0]+(ay-arm_elbow[1])*arm_axis[1];upper_arm=masked(arm,along<20);forearm=masked(arm,along>-20)
 rawparts=Image.open(SOURCE/cal['leg_source']['file']).convert('RGBA');assert sha(SOURCE/cal['leg_source']['file'])==cal['leg_source']['sha256'];parts={}
 for name,spec in cal['parts'].items():
  image=rawparts.crop(spec['crop']);a=np.asarray(spec['a'])-spec['crop'][:2];b=np.asarray(spec['b'])-spec['crop'][:2]if 'b'in spec else None;ys,xs=np.where(np.asarray(image)[:,:,3]>=180)
  parts[name]={'raw':image,'a':a,'b':b,'alpha_points':np.c_[xs,ys]-a,'spec':spec}
 base=read(BASE/'manifest.json');frozen=read(SOURCE.parent/'base_batch_c7/idle_approval.json');assert base['clips']['idle']==frozen['clip'];assert all(sha(BASE/file)==h for file,h in frozen['textures'].items())
 OUT.mkdir(parents=True,exist_ok=True);textures={};weapons={};clips={};foot_evidence={}
 def layer(im):
  box=im.getchannel('A').getbbox()
  if not box:return {}
  cut=im.crop(box);file='layers/'+hashlib.sha256(str(cut.size).encode()+cut.tobytes()).hexdigest()+'.png';p=OUT/file;p.parent.mkdir(exist_ok=True)
  if not p.exists():cut.save(p)
  textures[file]={'file':file,'size':list(cut.size),'sha256':sha(p)};return {'file':file,'rect':[box[0],box[1],box[2]-box[0],box[3]-box[1]]}
 for name,spec in base['weapon_sources'].items():
  raw=Image.open(BASE/spec['file']).convert('RGBA');p=OUT/spec['file'];p.parent.mkdir(exist_ok=True);raw.save(p);textures[spec['file']]={'file':spec['file'],'size':list(raw.size),'sha256':sha(p)};weapons[name]=(raw,spec['marks'],spec['physical_blade_length'])
 for name,motion in cal['motions'].items():
  frames=[];feet=[];duration=motion['duration_ticks'];stance=motion['stance_fraction'];speed=motion['native_speed'];travel=speed*stance*duration/60
  # One local hilt channel follows the actual carrying fist in both actions.
  carry=np.asarray(base['clips']['idle']['frames'][0]['profiles']['katana']['basis_u'])if name=='walk'else np.array([-.9,-math.sqrt(1-.9**2)])
  fingers_mask=Image.new('L',CANVAS);ImageDraw.Draw(fingers_mask).ellipse((primary[0]-8,primary[1]-8,primary[0]+8,primary[1]+8),fill=255);skin=(pixels[:,:,0]>150)&(pixels[:,:,1]>90)&(pixels[:,:,2]>65);finger_bool=(np.asarray(fingers_mask)>0)&skin;fingers=masked(sourcebody,finger_bool)
  channel=Image.new('L',CANVAS);ImageDraw.Draw(channel).line([tuple(primary-carry*8),tuple(primary+carry*8)],fill=255,width=5);fa=np.asarray(front).copy();fa[np.asarray(channel)>0,3]=0;actionfront=Image.fromarray(fa)
  for tick in range(duration):
   phase=tick/duration;lean=math.radians(motion['lean_degrees']+1.0*math.sin(math.tau*phase));body_m=rotation(lean);hip_y=636+6*math.cos(2*math.tau*phase)if name=='walk'else 642+13*math.sin(2*math.tau*phase+.5);target_pivot=np.array([448+1.5*math.sin(math.tau*phase),hip_y]);placed=lambda p:target_pivot+body_m@(np.asarray(p)-pivot)
   shoulder=placed(point(cal['upper']['shoulder_far']));swing=math.radians(-motion['arm_swing_degrees']*math.cos(math.tau*phase));upper_angle=math.pi/2-swing;elbow=shoulder+body_m@np.array([math.cos(upper_angle),math.sin(upper_angle)])*arm_spec['native_upper_length'];fore_angle=upper_angle-math.radians(motion['elbow_bend_degrees']);wrist=elbow+body_m@np.array([math.cos(fore_angle),math.sin(fore_angle)])*arm_spec['native_forearm_length'];upper_m=bone_matrix(arm_pivot,arm_elbow,shoulder,elbow,arm_spec['scale']);fore_m=bone_matrix(arm_elbow,arm_wrist,elbow,wrist,arm_spec['scale']);fararm=warp(upper_arm,arm_pivot,shoulder,upper_m);fararm.alpha_composite(warp(forearm,arm_elbow,elbow,fore_m))
   painted=Image.new('RGBA',CANVAS);painted.alpha_composite(warp(back,pivot,target_pivot,body_m@rotation(math.radians(1.8*math.sin(math.tau*phase-.5)))));painted.alpha_composite(fararm);leg_geometry={};row=[]
   for side,offset in [('far',0.),('near',.5)]:
    p=(phase+offset)%1;support=p<stance
    if support:
     u=p/stance;x=travel*.5-travel*u;lift=0.;boot_angle=math.radians(-8*(1-smooth(u/.15))if u<.15 else 12*smooth((u-.75)/.25)if u>.75 else 0.)
    else:
     u=(p-stance)/(1-stance);m0=-speed*(1-stance)*duration/60;x=(2*u**3-3*u**2+1)*(-travel*.5)+(u**3-2*u**2+u)*m0+(-2*u**3+3*u**2)*(travel*.5)+(u**3-u**2)*m0;lift=motion['lift']*math.sin(math.pi*u)**2;boot_angle=math.radians(12-20*smooth(u))
    boot=parts[side+'_boot'];boot_m=rotation(boot_angle)*boot['spec']['scale'];relative=boot['alpha_points']@boot_m.T;bottom=float(relative[:,1].max());ankle=np.array([448+(hip_native[side][0]-pivot[0])+x,840-bottom-lift]);hip=placed(hip_native[side]);amplitude=motion['projected_length_amplitude']*math.cos(2*math.tau*p);l1=motion['thigh_length']+amplitude;l2=motion['shin_length']+amplitude;k=knee(hip,ankle,l1,l2,(name,tick,side,p))
    for partname,start,end in [(side+'_thigh',hip,k),(side+'_shin',k,ankle)]:
     part=parts[partname];mat=bone_matrix(part['a'],part['b'],start,end,part['spec']['width_scale']);painted.alpha_composite(warp(part['raw'],part['a'],start,mat))
    painted.alpha_composite(warp(boot['raw'],boot['a'],ankle,boot_m));toe=ankle+boot_m@np.array([boot['raw'].width-10-boot['a'][0],boot['raw'].height-15-boot['a'][1]]);heel=ankle+boot_m@np.array([10-boot['a'][0],boot['raw'].height-15-boot['a'][1]]);leg_geometry[side]={'hip':hip.tolist(),'knee':k.tolist(),'ankle':ankle.tolist(),'toe':toe.tolist(),'heel':heel.tolist()};row.append({'side':side,'phase':p,'support':support,'ankle':ankle.tolist(),'thigh_length':l1,'shin_length':l2,'lowest_sole_y':float(ankle[1]+bottom),'expected_floor':840,'world_ankle_x':float(ankle[0]+speed*tick/60)})
   painted.alpha_composite(warp(actionfront,pivot,target_pivot,body_m));neck_target=placed(neck);head_m=rotation(lean+math.radians(motion['head_counter_degrees']));painted.alpha_composite(warp(head,neck,neck_target,head_m));finger_pixels=warp(fingers,pivot,target_pivot,body_m);head_center=neck_target+head_m@(np.asarray(g['head_center'])-neck);grip=placed(primary)
   def legpart(side,key):return leg_geometry[side][key]
   geom={'head_center':head_center.tolist(),'head_size':g['head_size'],'head_angle':lean+math.radians(motion['head_counter_degrees']),'grip':grip.tolist(),'secondary_grip':wrist.tolist(),'root':[448,840],'joints':[placed(point(cal['upper']['shoulder_near'])).tolist(),shoulder.tolist(),placed(point(cal['upper']['elbow_near'])).tolist(),elbow.tolist(),wrist.tolist(),grip.tolist()]+[legpart(side,key)for key in ['hip','knee','ankle','toe','heel']for side in ['near','far']]}
   frame={'source_pose':'c8_articulated_'+name,'start_tick':tick,'duration_ticks':1,'height_px':0,'root_dx':0,'body':layer(painted),'fingers':layer(finger_pixels),'motion_geometry':geom,'profiles':{}}
   for profile,(raw,marks,length)in weapons.items():
    if name=='walk':idle=base['clips']['idle']['frames'][0]['profiles'][profile];u=body_m@np.asarray(idle['basis_u']);v=body_m@np.asarray(idle['basis_v'])
    else:u=body_m@carry;v=np.array([-u[1],u[0]])
    angle=math.atan2(u[1],u[0]);blade,sampling=weapon_image(raw,marks,CANVAS,grip,angle,length,(u,v));matrix,_=placement_matrix(marks,angle,length,(u,v));a,b,c,d=matrix
    def blade_point(mark):
     dx,dy=np.asarray(mark)-marks['grip'];return [float(grip[0]+a*dx+b*dy),float(grip[1]+c*dx+d*dy)]
    tip=blade_point(marks['tip']);assert tip[1]<=844,(name,tick,profile,tip)
    frame['profiles'][profile]={'front':layer(blade),'back':{},'grip':grip.tolist(),'guard':blade_point(marks['guard']),'tip':tip,'cutting_edge':blade_point(marks['cutting_edge']),'spine':blade_point(marks['spine']),'basis_u':u.tolist(),'basis_v':v.tolist(),'matrix':list(matrix),'physical_blade_length':length,'source_sampling_scale':sampling}
   frames.append(frame);feet.append({'tick':tick,'feet':row})
  clips[name]={'semantic_id':base['clips'][name]['semantic_id'],'duration_ticks':duration,'loop':True,'root_mode':'ground','frames':frames};foot_evidence[name]=feet;print(name,duration,flush=True)
 assert all(sha(path)==digest for path,digest in bindings.items()),'Inputs changed during bake; refuse stale manifest'
 manifest={'schema':'swordsman_runtime_layers/2','revision':'v7_c8_walk_run_rig_c1','fps':60,'native_canvas':list(CANVAS),'anchor':[448,840],'motion_backend':'articulated cutout parts, analytic foot trajectories and two-link knees; no leg optical flow','clips':clips,'textures':textures,'weapon_sources':base['weapon_sources'],'source_inputs':[{'config':cfgpath.relative_to(ROOT).as_posix(),'sha256':sha(cfgpath),'audit_sha256':sha(folder/'proportions.json'),'manifest':bm.relative_to(ROOT).as_posix(),'manifest_sha256':sha(bm)}],'part_inputs':{'calibration':cal_path.relative_to(ROOT).as_posix(),'calibration_sha256':sha(cal_path),'arm_source_sha256':sha(SOURCE/cal['arm']['file']),'leg_source_sha256':sha(SOURCE/cal['leg_source']['file'])},'coverage':{'complete':False,'reason':'walk/run loop pilot only; start/stop and actual runtime transition pending'},'authorization':{'runtime_trial_allowed':False},'validation':{'source_G1_passed':True,'head_upscale':False,'upper_body_paintings':1,'isolated_arm_paintings':1,'isolated_leg_parts':6,'artwork_approved':False,'runtime_user_approved':False,'G3_approved':False},'recipe':{f:sha(ROOT/'tools'/f)for f in recipe_files}}
 write(OUT/'manifest.json',manifest);write(OUT/'foot_contact_review.json',{'scope':'analytic joint/sole evidence, not actual runtime pixel slipping approval','native_speed':{'walk':450,'run':900},'clips':foot_evidence});print('Offline rig pilot exported; game unchanged',flush=True)

if __name__=='__main__':main()
