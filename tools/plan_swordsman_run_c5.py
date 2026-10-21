"""Whole-person motion blueprint, never exported as game artwork or a limb rig.

Analytic joints only specify drawing reference. ImageGen redraws complete people.
"""
from pathlib import Path
import math
import json
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'art/animations/players/swordsman/v7/sources/whole_body_gait_c9/run_motion_c5'

def foot(t):
    points = [(0, 65, 0), (.30, -28, 0), (.40, -65, -4), (.50, -70, -58),
              (.65, -24, -118), (.78, 36, -100), (.90, 70, -45), (1, 65, 0)]
    for (a,x,y),(b,u,v) in zip(points,points[1:]):
        if a <= t <= b:
            s=(t-a)/(b-a)
            return x+(u-x)*s,y+(v-y)*s
    raise ValueError(t)

def knee(hip, ankle, length=110):
    dx,dy=ankle[0]-hip[0],ankle[1]-hip[1]
    distance=math.hypot(dx,dy)
    assert 0 < distance < length*2
    side=math.sqrt(length*length-distance*distance/4)
    return ((hip[0]+ankle[0])/2+dy/distance*side,
            (hip[1]+ankle[1])/2-dx/distance*side)

def main():
    im=Image.new('RGB',(2560,1440),'#f4f1e8'); d=ImageDraw.Draw(im)
    records=[]
    for i in range(12):
        ox,oy=i%4*640,i//4*480
        t=i/12
        bob=12*math.sin(4*math.pi*t)
        hip=(365,260+bob)
        shoulder=(405,153+bob*.8)
        head=(423,108+bob*.7)
        def p(a):return (round(a[0]+ox),round(a[1]+oy))
        d.line((p((20,440)),p((620,440))),fill='#aaa69c',width=2)
        d.text(p((16,12)),str(i+1).zfill(2)+'   RIGHT / NEAR = ORANGE',fill='#303030')
        legs=[]
        for side,phase,color in [('far',(t+.5)%1,'#3a7da0'),('near',t,'#e36b2c')]:
            fx,fy=foot(phase); ankle=(hip[0]+fx,430+fy)
            kn=knee(hip,ankle)
            d.line([p(hip),p(kn),p(ankle),p((ankle[0]+23,ankle[1]+6))],fill=color,width=17)
            for q in [hip,kn,ankle]:
                x,y=p(q); d.ellipse((x-9,y-9,x+9,y+9),fill=color,outline='#333333',width=2)
            legs.append({'side':side,'phase':phase,'hip':hip,'knee':kn,'ankle':ankle,'support':phase<.4})
        d.line([p(hip),p(shoulder),p((417,133+bob*.75))],fill='#333333',width=23)
        hx,hy=p(head);d.ellipse((hx-25,hy-33,hx+25,hy+33),fill='#bbbbbb',outline='#333333',width=3)
        # The carrying arm moves with the complete torso; the free arm counter-swings.
        grip=(310,244+bob*.8)
        elbow=(355,190+bob*.8)
        d.line([p(shoulder),p(elbow),p(grip)],fill='#555555',width=14)
        swing=30*math.cos(2*math.pi*t)
        d.line([p(shoulder),p((419+swing,205+bob)),p((453+swing,174+bob))],fill='#888888',width=13)
        d.line([p((grip[0]+18,grip[1]-5)),p((82,grip[1]+60))],fill='#586067',width=7)
        records.append({'frame':i,'hip':hip,'head':head,'legs':legs})
    im.save(OUT/'motion_blueprint.png')
    (OUT/'motion_blueprint.json').write_text(json.dumps({'purpose':'drawing reference only; never game raster or independently assembled limb animation','canvas':[2560,1440],'cells':[4,3],'frames':records},indent=2)+'\n',encoding='utf-8',newline='\n')

if __name__=='__main__':main()
