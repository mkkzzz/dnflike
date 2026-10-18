"""Draft limb landmarks for visual review; never measures/approves head scale.

Uses RTMPose's HumanArt/halpe26 estimator as a drafting aid, then writes explicit
native-pixel annotations. Review the overlays before binding them to a motion bake.
Model/tool sources: https://github.com/Tau-J/rtmlib (Apache-2.0),
https://github.com/open-mmlab/mmpose/tree/main/projects/rtmpose (Apache-2.0).
Weights and installed packages are local cache, not game runtime dependencies.
"""
from pathlib import Path
import argparse,json,hashlib
import numpy as np
from PIL import Image,ImageDraw,ImageFont
from rtmlib import RTMPose

ROOT=Path(__file__).resolve().parents[1]
MODEL='https://download.openmmlab.com/mmpose/v1/projects/rtmposev1/onnx_sdk/rtmpose-m_simcc-body7_pt-body7-halpe26_700e-256x192-4d3e73dd_20230605.zip'
OUT=ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c6'
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--only',nargs='*');args=parser.parse_args()
 model=RTMPose(MODEL,model_input_size=(192,256),backend='onnxruntime',device='cpu')
 cache=OUT/'motion_joints_draft.json';record=read(cache) if cache.exists() else {'schema':'native_limb_annotations/1','reviewed':False,'tool':'rtmlib 0.0.14 RTMPose HumanArt/halpe26 draft','model':MODEL,'poses':{}}
 configs=list((ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c5').glob('*/body_config.json'))+list(OUT.glob('*/body_config.json'))
 for cfg in configs:
  if args.only and cfg.parent.name not in args.only:continue
  c=read(cfg);manifest=(cfg.parent/c['output_dir']/'manifest.json').resolve()
  if not manifest.is_file():continue
  m=read(manifest);entries=[];seen=set()
  for clip in m['clips'].values():
   for f in clip['frames']:
    pid=f['source_pose']
    if pid in seen:continue
    seen.add(pid);p=manifest.parent/f['file'];im=Image.open(p).convert('RGBA');box=im.getchannel('A').getbbox()
    if pid not in record['poses'] or record['poses'][pid]['sha256']!=sha(p):
     bg=Image.new('RGBA',im.size,'#b0b0b0');bg.alpha_composite(im);image=np.asarray(bg.convert('RGB'))[:,:,::-1].copy()
     points,scores=model(image,bboxes=[list(box)])
     record['poses'][pid]={'file':p.relative_to(ROOT).as_posix(),'sha256':sha(p),'points':points[0].round(2).tolist(),'scores':scores[0].round(3).tolist(),'reviewed':False}
    d=record['poses'][pid];panel=Image.new('RGBA',(520,510),'#303741');panel.alpha_composite(im,(-200,-380));draw=ImageDraw.Draw(panel)
    for i in range(5,26):
     x,y=d['points'][i];x-=200;y-=380;draw.ellipse((x-3,y-3,x+3,y+3),fill='yellow');draw.text((x+3,y-10),str(i),fill='white')
    draw.text((5,5),pid,fill='white');entries.append(panel.convert('RGB'))
  board=Image.new('RGB',(520*2,510*((len(entries)+1)//2)),'#303741')
  for i,im in enumerate(entries):board.paste(im,(i%2*520,i//2*510))
  target=ROOT/'temp/v7_joint_drafts';target.mkdir(exist_ok=True);board.save(target/(('c6_' if cfg.parent.parent==OUT else '')+cfg.parent.name+'.png'))
  cache.write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n');print(cfg.parent.name,len(entries),flush=True)
if __name__=='__main__':main()
