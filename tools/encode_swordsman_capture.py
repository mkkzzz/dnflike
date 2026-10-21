"""Encode actual framebuffer PNGs without resizing; verify native size first.

Godot MovieWriter can lock its size before a script changes window dimensions.
This path consumes consecutive frame_post_draw PNGs and records their hashes.
"""
from pathlib import Path
import argparse,hashlib,json,subprocess
from PIL import Image
import imageio_ffmpeg

def main():
 p=argparse.ArgumentParser();p.add_argument('frames',type=Path);p.add_argument('output',type=Path);p.add_argument('--proves',default='instant facing, actual monster hit and scripted heavy hit presentation only; not rewritten gait/combo approval');args=p.parse_args()
 timeline=json.loads((args.frames/'timeline.json').read_text(encoding='utf-8'))
 assert timeline and [v['frame'] for v in timeline]==list(range(len(timeline)))
 assert all(b['render_frame']==a['render_frame']+1 for a,b in zip(timeline,timeline[1:])), 'Missing rendered frames'
 sources={}
 for i in range(len(timeline)):
  file=args.frames/f'f{i:05d}.png'
  with Image.open(file)as im:assert im.size==(2560,1440),f'Not native 2K: {file}: {im.size}'
  sources[file.name]=hashlib.sha256(file.read_bytes()).hexdigest()
 args.output.parent.mkdir(parents=True,exist_ok=True)
 subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(),'-y','-framerate','60','-i',str(args.frames/'f%05d.png'),'-frames:v',str(len(timeline)),'-an','-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuv420p',str(args.output)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
 probe=subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(),'-i',str(args.output)],capture_output=True,text=True)
 stream=next(line.strip()for line in probe.stderr.splitlines()if 'Video:'in line)
 assert '2560x1440'in stream and '60 fps'in stream,stream
 evidence={'source':'actual Godot frame_post_draw framebuffer PNGs','native_size':[2560,1440],'fps':60,'frames':len(timeline),'scaled':False,'stream_probe':stream,'frame_hashes':sources,'movie_sha256':hashlib.sha256(args.output.read_bytes()).hexdigest(),'timeline':timeline,'proves':args.proves}
 if (args.frames/'packages.json').exists():evidence['packages']=json.loads((args.frames/'packages.json').read_text(encoding='utf-8'))
 args.output.with_suffix('.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
 print(stream);print('Encoded',len(timeline),'native frames without scaling')

if __name__=='__main__':main()
