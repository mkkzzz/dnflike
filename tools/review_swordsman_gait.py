"""Make native-pixel crops from the same exported 2K gait review movies."""
from pathlib import Path
import hashlib,json,subprocess
import imageio_ffmpeg
from PIL import Image,ImageDraw,ImageFont
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'docs/previews/v7_c8_gait_rig'
PACKAGE=ROOT/'art/animations/players/swordsman/v7/exports/gait_rig_c8_pilot'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def apply_review_decision(html):
 decision_path=ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c8/gait_rig_rejection.json'
 decision=json.loads(decision_path.read_text(encoding='utf-8'))
 assert decision['status']=='rejected' and not decision['production_use_allowed']
 banner='<aside role="alert" style="padding:16px;border:2px solid #e99175;background:#442a2a;color:#fff"><strong>已退回 · 仅保留失败方案回放</strong><p>2026-10-21 用户否决拆分躯干和腿部的步态方案：整体人体运动不协调。本包未实装，停止沿用；将按完整人物关键姿势重新制作走路、跑步与起停。</p></aside>'
 html=html.replace('<main><h2>','<main>'+banner+'<h2>')
 html=html.replace('<title>C8 步行与奔跑样片</title>','<title>已退回：C8 拆件步态历史样片</title>')
 html=html.replace('此为离线设计候选，尚未接入游戏；起停和实机过渡仍需完成。','此为已退回的离线历史样片，尚未接入游戏；不得继续用于制作起停或实装。')
 return html,{'status':'rejected','decision_file':decision_path.relative_to(ROOT).as_posix(),'sha256':sha(decision_path),'production_use_allowed':False}

def main():
 views={'body':20,'katana':620,'greatsword':1220,'shortsword':1820};movies={}
 for clip in ['walk','run']:
  for view,x in views.items():
   source=OUT/(clip+'_60fps.mp4');dest=OUT/(clip+'_'+view+'_native.mp4')
   subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(),'-y','-i',str(source),'-an','-vf',f'crop=700:650:{x}:650','-c:v','libx264','-preset','fast','-crf','16',str(dest)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
   movies[dest.name]={'source_movie':source.name,'source_sha256':sha(source),'crop':[x,650,700,650],'resized':False,'sha256':sha(dest)}
  manifest=json.loads((PACKAGE/'manifest.json').read_text(encoding='utf-8'));frames=manifest['clips'][clip]['frames'];board=Image.new('RGB',(2160,1060),'#313943');draw=ImageDraw.Draw(board);font=ImageFont.truetype('C:/Windows/Fonts/arial.ttf',22)
  for i in range(8):
   tick=round(i*len(frames)/8);actor=Image.new('RGBA',(1024,1080))
   for layer in ['body','fingers']:
    ref=frames[tick][layer]
    if ref:actor.alpha_composite(Image.open(PACKAGE/ref['file']).convert('RGBA'),tuple(ref['rect'][:2]))
   background=Image.new('RGBA',actor.size,'#313943');background.alpha_composite(actor);x=i%4*540;y=i//4*530;board.paste(background.crop((220,400,760,900)).convert('RGB'),(x,y+30));draw.text((x+8,y+3),f'{clip} t{tick}',font=font,fill='white');draw.line((x,y+470,x+540,y+470),fill='#7c8c99')
  board.save(OUT/(clip+'_native_parts.png'))
 html='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>C8 步行与奔跑样片</title>
<style>body{margin:20px;background:#171c24;color:#e5e9ef;font:16px system-ui}main{max-width:1300px;margin:auto}p{color:#b8c5d7;line-height:1.6}select,button{font:inherit;padding:8px;margin:0 8px 8px 0}video{display:block;max-width:100%;width:700px;max-height:calc(100vh - 260px);background:#252c35}a{color:#9fc9ff}</style>
<main><h2>C8 步行 / 奔跑分层样片</h2><p>先看裸动作，再比较同身体的太刀、巨剑、短剑。默认半速；局部视图只裁切原始像素，没有放大。整屏选项为原生2560×1440。此为离线设计候选，尚未接入游戏；起停和实机过渡仍需完成。idle 保留原版。</p>
<select id="clip"><option value="walk">步行</option><option value="run">奔跑</option></select><select id="view"><option value="body">裸动作</option><option value="katana">太刀</option><option value="greatsword">巨剑</option><option value="shortsword">短剑</option><option value="full">完整2K对照</option></select><select id="speed"><option value="0.25">0.25×</option><option value="0.5" selected>0.5×</option><option value="1">1×</option></select><button id="play">播放 / 暂停</button><button id="previous">上一帧</button><button id="next">下一帧</button>
<video id="video" controls loop playsinline></video><p>一张躯干原画、独立摆臂和六个腿部件按轨迹烘焙；并非每个采样帧都重新绘画。步行42帧、奔跑32帧，均为60Hz；腿部不使用光流补间。头部沿用比例门禁，换刀不更换身体。</p><p><a href="../v7_c8_trial/index.html">第一刀：GM 试用与实机回放</a></p></main>
<script>const clip=document.querySelector('#clip'),view=document.querySelector('#view'),speed=document.querySelector('#speed'),video=document.querySelector('#video');function load(){video.src=clip.value+(view.value==='full'?'_60fps.mp4':'_'+view.value+'_native.mp4');video.style.width=view.value==='full'?'100%':'700px';video.playbackRate=Number(speed.value)}clip.onchange=load;view.onchange=load;speed.onchange=()=>video.playbackRate=Number(speed.value);document.querySelector('#play').onclick=()=>video.paused?video.play():video.pause();for(const[id,d]of[['previous',-1],['next',1]])document.querySelector('#'+id).onclick=()=>{video.pause();video.currentTime=Math.max(0,video.currentTime+d/60)};load();</script></html>'''
 html=html.replace("video.style.width=", "video.src+='?package="+sha(PACKAGE/'manifest.json')+"&range=1';video.style.width=")
 html,decision=apply_review_decision(html)
 (OUT/'index.html').write_text(html,encoding='utf-8',newline='\n')
 evidence={'package_sha256':sha(PACKAGE/'manifest.json'),'crop_movies':movies,'review_files':{p.name:sha(p)for p in OUT.iterdir()if p.suffix in ['.png','.mp4','.html']},'artwork_approved':False,'runtime_user_approved':False}
 evidence['review_decision']=decision
 (OUT/'review_manifest.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n');print('Eight native crops and one same-package review page saved')

if __name__=='__main__':main()
