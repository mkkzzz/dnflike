"""Replay actual installed layers for visual QA; never synthesize replacement animation art."""
import json,math
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
ROOT=Path(__file__).resolve().parents[1]
PACKAGE=ROOT/'art/animations/players/swordsman/v7/exports/base_runtime_c5'
OUTPUT=ROOT/'docs/previews/v7_c5'
def composite(frame,profile='katana'):
 im=Image.new('RGBA',(1024,1080));p=frame['profiles'][profile]
 for ref in [p['back'],frame['body'],p['front'],frame['fingers']]:
  if ref:
   crop=Image.open(PACKAGE/ref['file']).convert('RGBA');im.alpha_composite(crop,tuple(ref['rect'][:2]))
 return im
def main():
 m=json.loads((PACKAGE/'manifest.json').read_text(encoding='utf-8'));OUTPUT.mkdir(parents=True,exist_ok=True)
 groups={'movement':['idle','walk','run','walk_start','walk_stop','turn'],
         'combo':['attack1','attack2','attack3'],
         'air_guard':['jump_start','jump_rise','jump_apex','jump_fall','jump_land','back_dash','air_attack','dash_attack','guard_start','guard','parry','guard_recoil','guard_end'],
         'reactions':['hit_light','hit_heavy','air_hit','down','getup','death','revive']}
 font=ImageFont.truetype('C:/Windows/Fonts/arial.ttf',15)
 for group,names in groups.items():
  entries=[(name,f,'katana')for name in names for f in m['clips'][name]['frames']]
  board=Image.new('RGB',(470*4,515*math.ceil(len(entries)/4)),'#22272e')
  for i,(name,frame,profile) in enumerate(entries):
   panel=Image.new('RGBA',(470,515),'#22272e');actor=composite(frame,profile)
   actor=actor.convert('RGBa').resize((461,486),Image.Resampling.LANCZOS).convert('RGBA')
   panel.alpha_composite(actor,(4,24));d=ImageDraw.Draw(panel);d.text((8,4),f'{name}: {frame["source_pose"]} / t{frame["start_tick"]}',font=font,fill='white');d.line((0,402,470,402),fill='#66727e')
   board.paste(panel.convert('RGB'),((i%4)*470,(i//4)*515))
  board.save(OUTPUT/(group+'_keyframes.png'))
 # Runtime death is the same three-stage reuse seen in the game.
 for name in ['death','getup','attack2','walk','run']:
  frames=[];times=[]
  bounds=[composite(f).getchannel('A').getbbox()for f in m['clips'][name]['frames']]
  box=(max(0,min(b[0]for b in bounds)-20),max(0,min(b[1]for b in bounds)-35),min(1024,max(b[2]for b in bounds)+20),min(1080,max(b[3]for b in bounds)+20))
  for frame in m['clips'][name]['frames']:
   panel=Image.new('RGBA',(1024,1080),'#22272e');panel.alpha_composite(composite(frame));panel=panel.crop(box)
   d=ImageDraw.Draw(panel);d.text((8,8),name+' / 1/3 speed / exact packaged layers',font=font,fill='white')
   frames.append(panel.convert('RGB'));times.append(frame['duration_ticks']*50)
  frames[0].save(OUTPUT/(name+'_slow3x.gif'),save_all=True,append_images=frames[1:],duration=times,loop=0,disposal=2,optimize=False)
 # Browser review uses the very same runtime manifest and PNGs, at a native scale.
 html='''<!doctype html><meta charset="utf-8"><title>鬼剑士基础动作 c5</title>
<style>body{background:#20242b;color:#eee;font:16px system-ui;margin:20px}canvas{background:#292f37;max-width:100%;height:auto}select,button,input{font:inherit;margin:6px}label{white-space:nowrap}</style>
<h2>鬼剑士基础动作</h2><select id="clip"></select><select id="weapon"><option value="katana">太刀</option><option value="greatsword">巨剑</option><option value="shortsword">短剑</option></select>
<select id="speed"><option value="0.333333">慢放 1/3</option><option value="1">实速</option><option value="0.5">1/2</option></select><button id="play">暂停</button><label><input type="checkbox" id="left">朝左</label><label><input type="checkbox" id="bare">裸身体</label><br>
<input id="tick" type="range" min="0" value="0" step="0.01" style="width:600px"><span id="info"></span><br><canvas width="1280" height="1080" id="canvas"></canvas>
<p>同一运行包回放；死亡复用受击、倒地、闭眼静止。跳跃高度由游戏物理驱动；此处展示姿态。技能不在本批。</p>
<script>const data=__DATA__,root='../../../art/animations/players/swordsman/v7/exports/base_runtime_c5/';
const el=id=>document.getElementById(id),ctx=el('canvas').getContext('2d'),images={};let clock=0,playing=true,last=0;
for(const key of Object.keys(data.clips)){const o=document.createElement('option');o.value=o.textContent=key;el('clip').append(o)}
for(const t of Object.values(data.textures)){const im=new Image();im.src=root+t.file;images[t.file]=im}
el('clip').onchange=()=>{clock=0};el('tick').oninput=()=>{clock=Number(el('tick').value);playing=false;el('play').textContent='播放'};
el('play').onclick=()=>{playing=!playing;el('play').textContent=playing?'暂停':'播放'};
function layer(r){if(!r||!r.file)return;const im=images[r.file];if(im&&im.complete)ctx.drawImage(im,r.rect[0],r.rect[1])}
function draw(t){const c=data.clips[el('clip').value];if(playing&&last)clock=(clock+(t-last)*.06*Number(el('speed').value))%c.duration_ticks;last=t;
const f=c.frames.find(x=>clock<x.start_tick+x.duration_ticks)||c.frames.at(-1),w=f.profiles[el('weapon').value];el('tick').max=c.duration_ticks;el('tick').value=clock;el('info').textContent='tick '+clock.toFixed(1)+' / '+c.duration_ticks;
ctx.setTransform(1,0,0,1,0,0);ctx.clearRect(0,0,1280,1080);const facing=el('left').checked?-1:1;ctx.setTransform(facing,0,0,1,640-facing*data.anchor[0],0);
if(!el('bare').checked)layer(w.back);layer(f.body);if(!el('bare').checked)layer(w.front);layer(f.fingers);requestAnimationFrame(draw)}requestAnimationFrame(draw);</script>'''
 (OUTPUT/'index.html').write_text(html.replace('__DATA__',json.dumps(m,ensure_ascii=False)),encoding='utf-8')
 print(OUTPUT)
if __name__=='__main__':main()
