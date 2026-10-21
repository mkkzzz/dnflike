"""Cut and replay whole-person source-study cells without deformation/interpolation.

This is deliberately not a production actor export: the sheet lacks the neutral
proportion ruler and is below the requested native 2K canvas. Runtime is blocked.
"""
from pathlib import Path
import hashlib
import json
import subprocess
from PIL import Image, ImageDraw
import imageio_ffmpeg

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT/'art/animations/players/swordsman/v7/sources/whole_body_gait_c9/run_motion_c5'
VIEW = ROOT/'docs/previews/v7_c9_whole_body'
OUT = VIEW/'run_motion_c5'

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,data): p.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    source=Image.open(SRC/'source_c2.png').convert('RGBA')
    assert source.size==(1672,941), 'Recalibrate a changed sheet instead of guessing cells'
    # Visually checked whole-figure cells, pelvis x and a shared virtual floor per row.
    # Translation only. Do not pin airborne shoes, stretch heads, or move limbs.
    hip_x=[267,675,1096,1500,259,672,1095,1520,263,675,1095,1517]
    floor=[306]*4+[614]*4+[924]*4
    durations=[3,4,3,2,3,3]*2
    names=['near_contact','near_load','near_passing','near_late_support',
           'near_push','far_precontact','far_contact','far_load','far_passing',
           'far_late_support','far_push','near_precontact']
    panels=[]; records=[]; ticks=[]
    for i in range(12):
        col,row=i%4,i//4
        rect=(col*418,round(row*941/3),(col+1)*418,round((row+1)*941/3))
        cell=source.crop(rect)
        shift=(280-(hip_x[i]-rect[0]),320-(floor[i]-rect[1]))
        actor=Image.new('RGBA',(460,340))
        bounds=cell.getchannel('A').point(lambda a:255 if a>16 else 0).getbbox()
        assert bounds and bounds[0]>0 and bounds[2]<418, (i,'cell edge')
        assert min(bounds[0]+shift[0],bounds[1]+shift[1])>=0
        assert bounds[2]+shift[0]<=460 and bounds[3]+shift[1]<=340
        actor.paste(cell,shift)  # Copy RGBA, never apply alpha twice.
        file=f'frame_{i:02d}.png';actor.save(OUT/file)
        panel=Image.new('RGB',actor.size,'#222a31');panel.paste(actor,(0,0),actor)
        d=ImageDraw.Draw(panel);d.line((0,320,460,320),fill='#77848d')
        d.text((10,8),f'C5  {i+1:02d}/12',fill='#f1eadc')
        panels.append(panel);ticks.extend([panel]*durations[i])
        records.append({'file':file,'sha256':sha(OUT/file),'source_rect':rect,
            'source_pelvis_x':hip_x[i],'source_virtual_ground_y':floor[i],
            'translation':shift,'phase_intent':names[i],
            'start_tick':sum(durations[:i]),'duration_ticks':durations[i],
            'bounds':actor.getbbox()})
    sheet=Image.new('RGB',(1840,1020),'#222a31')
    for i,panel in enumerate(panels):sheet.paste(panel,(i%4*460,i//4*340))
    sheet.save(OUT/'contact_sheet.png')
    target=OUT/'cycle.mp4'
    process=subprocess.Popen([imageio_ffmpeg.get_ffmpeg_exe(),'-y','-f','rawvideo','-vcodec','rawvideo',
        '-pix_fmt','rgb24','-s','460x340','-r','60','-i','-','-an','-c:v','libx264','-pix_fmt','yuv420p',
        '-crf','16',str(target)],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    for _ in range(6):
        for panel in ticks:process.stdin.write(panel.tobytes())
    process.stdin.close();error=process.stderr.read()
    if process.wait():raise RuntimeError(error.decode(errors='replace'))
    # Exact same cut cells are the only review source; no alternate dense export.
    manifest={'asset_id':'actor.player.base.run','revision':'v7_c9_c5_motion_study',
        'status':'source_review','runtime_install_allowed':False,'production_G1_passed':False,
        'reason':'Source motion study lacks neutral ruler and requested native 2K size; not a production actor export.',
        'source':str((SRC/'source_c2.png').relative_to(ROOT)).replace('\\','/'),
        'source_sha256':sha(SRC/'source_c2.png'),'source_size':source.size,
        'canvas':[460,340],'anchor':[280,320],'scale':1,'raster_upscaled':False,
        'whole_body_only':True,'limb_transforms':False,'interpolation':False,
        'includes_painted_weapon':True,'weapon_switching_delivery':False,
        'fps':60,'cycle_ticks':len(ticks),'frames':records,'recipe_sha256':sha(Path(__file__)),
        'media':{p.name:sha(p) for p in [target,OUT/'contact_sheet.png']}}
    write(OUT/'manifest.json',manifest)
    print(json.dumps({'source':source.size,'drawings':len(records),'ticks':len(ticks),'media':str(target)}))

if __name__=='__main__':main()
