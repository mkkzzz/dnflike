"""Publish the C10 review UI and unscaled, actor-following game crops.

Full framebuffer proof is encoded separately. Detail clips crop those exact frames;
they never resize or substitute offline character renders for game evidence.
"""
from pathlib import Path
import argparse,hashlib,json,subprocess
from PIL import Image
import imageio_ffmpeg

R=Path(__file__).resolve().parents[1]
OUT=R/'docs/previews/v7_c10_run_combo'
PACKAGE=R/'art/animations/players/swordsman/v7/exports/run_combo_c10'
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def main():
 p=argparse.ArgumentParser();p.add_argument('--frames',type=Path);args=p.parse_args()
 manifest=read(PACKAGE/'manifest.json');proof=read(OUT/'gameplay_native_2k.json')
 assert proof['packages']['c10_manifest_sha256']==sha(PACKAGE/'manifest.json')
 details=[]
 if args.frames:
  for profile in ['katana','greatsword','shortsword']:
   for facing in [1,-1]:
    rows=[v for v in proof['timeline']if v['profile']==profile and v['facing']==facing]
    assert rows
    file=OUT/f'game_{profile}_face{facing}_detail.mp4'
    process=subprocess.Popen([imageio_ffmpeg.get_ffmpeg_exe(),'-y','-f','rawvideo','-pixel_format','rgb24','-video_size','1120x880','-framerate','60','-i','pipe:0','-an','-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuv420p',str(file)],stdin=subprocess.PIPE,stderr=subprocess.PIPE)
    crops=[]
    suffix='webp'if(args.frames/'f00000.webp').exists()else'png'
    for row in rows:
     with Image.open(args.frames/f"f{row['frame']:05d}.{suffix}")as im:
      assert im.size==(2560,1440)
      x=round(row['position'][0]*2+facing*64-560);y=round(row['position'][1]*2-760)
      box=[x,y,x+1120,y+880];crop=im.crop(box).convert('RGB')
      process.stdin.write(crop.tobytes());crops.append({'frame':row['frame'],'box':box})
    process.stdin.close();error=process.stderr.read();assert process.wait()==0,error.decode(errors='replace')
    details.append({'file':file.name,'sha256':sha(file),'size':[1120,880],'fps':60,'resize':False,'source_movie_sha256':proof['movie_sha256'],'source_frame_crops':crops})
    print(file.name,flush=True)
  (OUT/'detail_crops.json').write_text(json.dumps(details,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
 html='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>鬼剑士 C10 · 跑动与三段普攻实装</title>
<style>:root{color-scheme:dark}body{margin:0;background:#141920;color:#e5edf5;font:16px/1.6 system-ui}main{max-width:1200px;margin:auto;padding:24px}h1{font-size:25px}p{color:#b7c4d5}.controls{display:flex;gap:8px;flex-wrap:wrap}select,button{font:inherit;padding:8px 12px;background:#273343;border:1px solid #4e617b;border-radius:6px;color:inherit}video{display:block;width:100%;max-height:75vh;background:#252c35;margin:20px auto;object-fit:contain}small{color:#b7c4d5}a{color:#8fc7ff}.badge{color:#a7e3bd}</style>
<main><h1>鬼剑士 C10 · 跑动与三段普攻</h1><p class="badge">已接入游戏，默认启用 · 完整人物关键原画 · 武器独立切换</p><p>沿用已认可的拖刀握持与收腿/过步方向，补齐蹬地、腾空、着地、起跑和停步。三连为双手左挥 → 右挥 → 下方上挑。已认可 idle 保留。完整动作观感与实机试玩仍待验收。</p>
<div class="controls"><select id="clip" aria-label="回放片段"><optgroup label="真实游戏 · 原像素跟随裁切">
<option value="game_katana_face1_detail.mp4">太刀 · 朝右 · 跑动与三连</option><option value="game_katana_face-1_detail.mp4">太刀 · 朝左 · 跑动与三连</option><option value="game_greatsword_face1_detail.mp4">巨剑 · 朝右 · 跑动与三连</option><option value="game_greatsword_face-1_detail.mp4">巨剑 · 朝左 · 跑动与三连</option><option value="game_shortsword_face1_detail.mp4">短剑 · 朝右 · 跑动与三连</option><option value="game_shortsword_face-1_detail.mp4">短剑 · 朝左 · 跑动与三连</option></optgroup><optgroup label="真实游戏 · 原生2K完整画面"><option value="gameplay_native_2k.mp4">三种武器 × 左右朝向</option></optgroup><optgroup label="同一导出包 · 无特效离线三武器"><option value="run_60fps.mp4">跑步循环</option><option value="run_start_60fps.mp4">起跑</option><option value="run_stop_60fps.mp4">停步恢复</option><option value="attack1_60fps.mp4">第一刀</option><option value="attack2_60fps.mp4">第二刀</option><option value="attack3_60fps.mp4">第三刀</option></optgroup></select>
<select id="speed" aria-label="速度"><option value="0.25">0.25×</option><option value="0.5" selected>0.5×</option><option value="1">1× 实速</option></select><button id="play">播放 / 暂停</button><button id="previous">上一帧</button><button id="next">下一帧</button></div>
<video id="video" controls loop playsinline preload="metadata"></video><p id="caption"></p><small>上下帧按原始60Hz时间定位；慢放只改变播放速度。近景来自2560×1440游戏帧缓冲的1120×880原像素裁切，未放大。离线片段直接消费已安装的同一个导出包。单张生成源图实际1672×941，原生2K源画布目标仍未达到；入用人物按约380px站高缩小导出，没有把低分辨率角色放大。</small><p>游戏中按 P →「新版跑动与三连」；可用「回退 c6 动作」比较旧版。行走及其他基础动作沿用现有版本，本次交付范围是跑动、起停与地面三连。</p></main>
<script>const video=document.querySelector('#video'),clip=document.querySelector('#clip'),speed=document.querySelector('#speed'),caption=document.querySelector('#caption');function load(){video.src=clip.value;video.playbackRate=Number(speed.value);caption.textContent=clip.value.startsWith('game_')?'真实游戏近景：包含位移、状态衔接、武器切换结果与三连输入。':clip.value==='gameplay_native_2k.mp4'?'真实游戏原生2K画面，三武器与左右朝向依次回放。':'离线无特效样片：单独检查身体、握持和刀口。';video.play().catch(()=>{})}clip.onchange=load;speed.onchange=()=>video.playbackRate=Number(speed.value);document.querySelector('#play').onclick=()=>video.paused?video.play():video.pause();for(const [id,d]of[['previous',-1],['next',1]])document.querySelector('#'+id).onclick=()=>{video.pause();video.currentTime=Math.max(0,video.currentTime+d/60)};video.onloadedmetadata=()=>video.playbackRate=Number(speed.value);load();</script></html>'''
 (OUT/'index.html').write_text(html,encoding='utf-8',newline='\n')
 evidence={'package_sha256':sha(PACKAGE/'manifest.json'),'clips':list(manifest['clips']),'review_files':{p.name:sha(p)for p in OUT.iterdir()if p.suffix in ['.png','.mp4','.html']},'game_evidence':'gameplay_native_2k.json','detail_evidence':'detail_crops.json','artwork_approved':False,'runtime_user_approved':False}
 (OUT/'review_manifest.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')

if __name__=='__main__':main()
