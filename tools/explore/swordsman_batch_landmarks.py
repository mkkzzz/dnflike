"""Render actual source-bound marks for human/agent visual semantic inspection.

This never approves annotations. Use overlays and head crops to check the true
hair/jaw; an alpha hit on a mouth, neck or jacket cannot establish semantics.
"""
from pathlib import Path
import argparse,math
from PIL import Image,ImageDraw,ImageFont
from swordsman_layer_trial import read
from swordsman_base_batch import SOURCE

def render(group):
 folder=SOURCE/group;c=read(folder/'body_config.json');a=read(folder/'proportions.json')
 font=ImageFont.truetype('C:/Windows/Fonts/arial.ttf',13);panels=[];outputs=[]
 for name,source in c['sources'].items():
  raw=Image.open(folder/source['file']).convert('RGBA')
  out=Image.new('RGB',raw.size,'#282d34');out.paste(raw,mask=raw.getchannel('A'));d=ImageDraw.Draw(out)
  entries=[e for e in a['poses'] if e['source']==name]
  basis=a['sources'][name]['scale_basis']
  if not any(e['head']==basis['head'] for e in entries):entries.append({'pose_id':name+'_neutral_companion','head':basis['head']})
  for entry in entries:
   head=entry['head'];points=[head['hair_top'],head['chin']]
   for p,color in zip(points,['#ffd339','#40ebe3']):
    x,y=p;d.ellipse((x-3,y-3,x+3,y+3),outline=color);d.text((x+5,y),entry['pose_id']+' '+str(p),font=font,fill=color)
   xs,ys=zip(*points);box=(max(0,min(xs)-45),max(0,min(ys)-20),min(raw.width,max(xs)+45),min(raw.height,max(ys)+25))
   panel=Image.new('RGB',(250,200),'#282d34');pd=ImageDraw.Draw(panel);pd.text((4,2),entry['pose_id']+' / '+name,font=font,fill='white')
   panel.paste(out.crop(box),(5,25));pd.text((5,175),'H='+str(points[0])+' J='+str(points[1]),font=font,fill='white');panels.append(panel)
  path=folder/('marks_'+name+'.png');out.save(path);outputs.append(path)
 board=Image.new('RGB',(250*4,200*math.ceil(len(panels)/4)),'#181c22')
 for i,panel in enumerate(panels):board.paste(panel,((i%4)*250,(i//4)*200))
 path=folder/'heads_review.png';board.save(path);outputs.append(path)
 return outputs

if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('groups',nargs='+')
 p.add_argument('--source-dir',type=Path,default=SOURCE);args=p.parse_args();SOURCE=args.source_dir.resolve()
 for group in args.groups:
  for path in render(group):print(path)
