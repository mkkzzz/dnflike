"""Review the actual c6 exported pixels, with native 2K 60fps movies."""
from pathlib import Path
import argparse,json,subprocess,hashlib
from PIL import Image,ImageDraw,ImageFont
import imageio_ffmpeg

ROOT=Path(__file__).resolve().parents[1]
PACKAGE=ROOT/'art/animations/players/swordsman/v7/exports/base_runtime_c6'
OUT=ROOT/'docs/previews/v7_c6'

def main():
 p=argparse.ArgumentParser();p.add_argument('--only',nargs='*');p.add_argument('--movies',action='store_true');p.add_argument('--checkpoints',action='store_true');args=p.parse_args()
 manifest=json.loads((PACKAGE/'manifest.json').read_text(encoding='utf-8'));OUT.mkdir(parents=True,exist_ok=True);cache={}
 if args.checkpoints:
  for name in args.only or []:manifest['clips'][name]=json.loads((PACKAGE/(name+'.checkpoint.json')).read_text(encoding='utf-8'))
 font=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',30);small=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',24)
 def image(ref):
  if not ref:return None
  file=ref['file']
  if file not in cache:cache[file]=Image.open(PACKAGE/file).convert('RGBA')
  return cache[file]
 def actor(frame,profile):
  im=Image.new('RGBA',(1024,1080));w=frame['profiles'][profile]
  for r in [w['back'],frame['body'],w['front'],frame['fingers']]:
   if r:im.alpha_composite(image(r),tuple(r['rect'][:2]))
  return im
 def screen(frame,name,tick):
  canvas=Image.new('RGBA',(2560,1440),'#252c35');draw=ImageDraw.Draw(canvas)
  draw.line((0,1120,2560,1120),fill='#66727f',width=2)
  for x,profile,title in [(500,'katana','太刀'),(1280,'greatsword','巨剑'),(2060,'shortsword','短剑')]:
   canvas.alpha_composite(actor(frame,profile),(x-448,1120-840));draw.text((x-70,250),title,font=font,fill='white')
  draw.text((60,50),'V7 c6 返修候选 / 原生 2K / 60 fps / 无刀光',font=font,fill='white')
  draw.text((60,105),f'{name}    tick {tick}    同一身体与手指层，三种独立武器',font=small,fill='#c7d6e8')
  draw.text((60,1320),'仅为同包离线回放；状态之间的实机过渡另验。',font=small,fill='#d9c6a7')
  return canvas.convert('RGB')
 for name,c in manifest['clips'].items():
  if args.only and name not in args.only:continue
  frames=c['frames'];chosen=sorted(set([0,len(frames)//4,len(frames)//2,len(frames)*3//4,len(frames)-1]+([8,12] if name.startswith('attack')else[])))
  board=Image.new('RGB',(768*3,620*((len(chosen)+2)//3)),'#252c35')
  for i,t in enumerate(chosen):
   panel=Image.new('RGBA',(1024,1080),'#252c35');panel.alpha_composite(actor(frames[t],'katana'))
   panel=panel.crop((64,260,960,900));panel.thumbnail((748,570),Image.Resampling.LANCZOS)
   board.paste(panel.convert('RGB'),(i%3*768,i//3*620+42));ImageDraw.Draw(board).text((i%3*768+12,i//3*620+5),f'{name} t{t}',font=small,fill='white')
  board.save(OUT/(name+'_keyframes.png'))
  for t in chosen:
   if t in [8,12,len(frames)//2]:screen(frames[t],name,t).save(OUT/(name+f'_t{t}_native_2k.png'))
  if args.movies:
   file=OUT/(name+'_60fps.mp4');log=open(ROOT/'temp'/('c6_'+name+'_ffmpeg.log'),'wb')
   process=subprocess.Popen([imageio_ffmpeg.get_ffmpeg_exe(),'-y','-f','rawvideo','-pixel_format','rgb24','-video_size','2560x1440','-framerate','60','-i','pipe:0','-an','-c:v','libx264','-preset','veryfast','-crf','18','-pix_fmt','yuv420p',str(file)],stdin=subprocess.PIPE,stderr=log)
   for t,f in enumerate(frames):process.stdin.write(screen(f,name,t).tobytes())
   process.stdin.close();code=process.wait();log.close()
   if code:raise RuntimeError('Movie encode failed '+name)
  print(name,len(frames),flush=True)
 names=[n for n in manifest['clips']if (OUT/(n+'_60fps.mp4')).exists()]
 html='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>鬼剑士 c6 动作返修预览</title>
<style>body{margin:24px;background:#171c24;color:#e5e9ef;font:16px system-ui}main{max-width:1440px;margin:auto}video{display:block;width:100%;background:#252c35;border-radius:8px;margin:18px 0}select,button{font:inherit;padding:8px;margin-right:8px}p{color:#b8c5d7;line-height:1.6}</style>
<main><h2>鬼剑士 c6 历史候选 / 部分退回</h2><p>用户已认可 idle 与采样流畅度；行走、奔跑和三连的动作设计已退回。离线片段为原生 2K；旧引擎连续录像实际 1080p，已纠正原命名。默认半速；力量感请同时看 1×。不含技能。</p>
<select id="clip"></select><select id="speed"><option value="0.25">0.25×</option><option value="0.5" selected>0.5×</option><option value="1">1×</option></select><button id="previous">上一帧</button><button id="next">下一帧</button><video id="video" controls loop playsinline></video><p>上一帧/下一帧按源文件 60Hz 逐帧查看。游戏视频含真实操作与恢复过渡，离线视频只显示各片段自身。</p></main>
<script>const names=__NAMES__;const clip=document.querySelector('#clip'),video=document.querySelector('#video'),speed=document.querySelector('#speed');for(const name of names){const option=document.createElement('option');option.value=name+'_60fps.mp4';option.textContent=name;clip.append(option)}
const game=document.createElement('option');game.value='gameplay_1080p.mp4';game.textContent='旧游戏连续操作（实机1080p，动作已退回）';clip.append(game);function load(){video.src=clip.value;video.playbackRate=Number(speed.value);video.play().catch(()=>{})}clip.onchange=load;speed.onchange=()=>video.playbackRate=Number(speed.value);for(const [id,d]of[['previous',-1],['next',1]])document.querySelector('#'+id).onclick=()=>{video.pause();video.currentTime=Math.max(0,video.currentTime+d/60)};load();</script></html>'''.replace('__NAMES__',json.dumps(names))
 (OUT/'index.html').write_text(html,encoding='utf-8')
 evidence={'package_sha256':hashlib.sha256((PACKAGE/'manifest.json').read_bytes()).hexdigest(),'clips':names,'review_files':{p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in OUT.iterdir()if p.suffix in ['.png','.mp4','.html']},'artwork_approved':False,'runtime_user_approved':False}
 (OUT/'review_manifest.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
