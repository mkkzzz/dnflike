"""C9 whole-drawing review only: native keys plus unrigged RIFE diagnostics.

Never assembles limbs, retargets joints, locks the head, writes game/ or approves
the artwork. Dense frames are diagnostic until the complete motion is reviewed.
"""
from pathlib import Path
import hashlib,json,os,subprocess
import cv2,numpy as np
from PIL import Image,ImageDraw
import imageio_ffmpeg
from check_actor_proportions import preflight
from motion_neural import engine
from setup_motion_model import FILES

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'art/animations/players/swordsman/v7/sources/whole_body_gait_c9'
KEYS=ROOT/'art/animations/players/swordsman/v7/exports/whole_body_gait_c9_keys'
OUT=ROOT/'art/animations/players/swordsman/v7/exports/whole_body_gait_c9_review'
VIEW=ROOT/'docs/previews/v7_c9_whole_body'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def write(p,v):p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
def pm(im):
 a=np.array(im,dtype=np.float32)/255;a[:,:,:3]*=a[:,:,3:4];return a
def straight(a):
 a=a.copy();a[:,:,:3]/=np.maximum(a[:,:,3:4],1e-7)
 return Image.fromarray(np.rint(np.clip(a,0,1)*255).astype(np.uint8))
def interpolate(a,b,t):
 # Whole-drawing correspondence only. No per-limb/body region deformation maps.
 box=(200,400,720,870);ap=pm(a.crop(box));bp=pm(b.crop(box))
 for im in (a,b):
  bounds=im.getchannel('A').point(lambda x:255 if x>16 else 0).getbbox()
  if not bounds or not(box[0]<=bounds[0] and box[1]<=bounds[1] and box[2]>=bounds[2] and box[3]>=bounds[3]):
   raise ValueError('Native interpolation box clips the complete actor')
 flow,w=engine().fields(ap,bp,t);yy,xx=np.mgrid[:ap.shape[0],:ap.shape[1]].astype(np.float32)
 aa=cv2.remap(ap,xx+flow[0],yy+flow[1],cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
 bb=cv2.remap(bp,xx+flow[2],yy+flow[3],cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
 result=Image.new('RGBA',a.size);result.paste(straight(aa*w[:,:,None]+bb*(1-w[:,:,None])),box[:2]);return result
def video(path,images,repeat=4):
 cmd=[imageio_ffmpeg.get_ffmpeg_exe(),'-y','-f','rawvideo','-vcodec','rawvideo','-pix_fmt','rgb24','-s','700x650','-r','60','-i','-','-an','-c:v','libx264','-pix_fmt','yuv420p','-crf','16',str(path)]
 proc=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
 for _ in range(repeat):
  for im in images:
   stage=Image.new('RGB',(700,650),'#222a31');stage.paste(im.crop((98,290,798,940)),(0,0),im.crop((98,290,798,940)))
   ImageDraw.Draw(stage).line((0,551,700,551),fill='#596875');proc.stdin.write(stage.tobytes())
 proc.stdin.close();error=proc.stderr.read();code=proc.wait()
 if code:raise RuntimeError(error.decode(errors='replace'))
def main():
 cfg=read(SOURCE/'body_config.json');gate=preflight(SOURCE/'body_config.json',cfg)
 base=read(KEYS/'manifest.json')
 if base['config_sha256']!=sha(SOURCE/'body_config.json'):raise ValueError('Re-export changed key config first')
 model=Path(os.environ['SWORDSMAN_RIFE_MODEL'])
 for name,expected in FILES.items():
  if sha(model/name)!=expected:raise ValueError('Unverified RIFE model')
 OUT.mkdir(parents=True,exist_ok=True);VIEW.mkdir(parents=True,exist_ok=True);(OUT/'actor').mkdir(exist_ok=True)
 clip=base['clips']['walk'];keys=[Image.open(KEYS/r['file']).convert('RGBA') for r in clip['frames']]
 frames=[];records=[];held=[]
 for k,(key,record) in enumerate(zip(keys,clip['frames'])):
  duration=record['duration_ticks']
  for j in range(duration):
   im=key.copy() if j==0 else interpolate(key,keys[(k+1)%len(keys)],j/duration)
   p=OUT/'actor'/f'f{len(frames):03d}.png';im.save(p)
   records.append({'file':p.relative_to(OUT).as_posix(),'sha256':sha(p),'source_key':k,'next_key':(k+1)%len(keys),'fraction':j/duration,'is_painted_key':j==0})
   frames.append(im);held.append(key)
  print(f'whole-body interval {k+1}/{len(keys)}',flush=True)
 video(VIEW/'walk_dense.mp4',frames);video(VIEW/'walk_keys.mp4',held)
 # Contact sheet uses native actor pixels: no enlarged or separately redrawn art.
 sheet=Image.new('RGB',(1600,1000),'#222a31');draw=ImageDraw.Draw(sheet)
 for i,key in enumerate(keys):
  cut=key.crop((248,400,648,900));x=i%4*400;y=i//4*500;sheet.paste(cut,(x,y),cut)
  draw.text((x+12,y+8),str(i)+' '+clip['frames'][i]['source_pose'],fill='white')
 sheet.save(VIEW/'walk_keys.png')
 manifest={'schema':'whole_body_gait_review/1','revision':'v7_c9_whole_body_walk_c1','status':'diagnostic_not_approved','runtime_installed':False,'runtime_install_allowed':False,'fps':60,'duration_ticks':len(frames),'painted_keys':len(keys),'independent_limb_assembly':False,'per_part_scaling':False,'head_locking':False,'key_manifest':KEYS.relative_to(ROOT).as_posix()+'/manifest.json','key_manifest_sha256':sha(KEYS/'manifest.json'),'recipe_sha256':sha(Path(__file__)),'proportion_gate':gate,'model_files':FILES,'frames':records,'known_issues':['weight acceptance asymmetric','far passing extends too early','weapon grip/carry design not yet validated','dense interpolation remains subject to silhouette review'],'media':{p.name:sha(p) for p in [VIEW/'walk_dense.mp4',VIEW/'walk_keys.mp4',VIEW/'walk_keys.png']}}
 write(OUT/'manifest.json',manifest)
 write(VIEW/'review_manifest.json',{'export':OUT.relative_to(ROOT).as_posix()+'/manifest.json','sha256':sha(OUT/'manifest.json'),'artwork_approved':False,'runtime_installed':False,'video_size':[700,650],'native_actor_standing_height':380,'raster_upscaled':False})
 print(OUT/'manifest.json',flush=True)
if __name__=='__main__':main()
