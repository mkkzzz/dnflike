"""Feature-aligned native raster inbetweens, with rigid head/hand landmarks.

Numerical landmarks constrain the geometry; they do not approve motion quality.
Creative source drawings remain separate and immutable. The residual flow is
estimated only after aligning the head, grip and ground, to avoid double heads
when a crouched drawing rises. Weapon pixels never enter the body flow solve.
"""
from __future__ import annotations
import math
import numpy as np
import cv2
import os

cv2.setNumThreads(4)

def mix(a,b,t):return np.asarray(a)*(1-t)+np.asarray(b)*t

def shortest(a,b):return a+(b-a+math.pi)%(2*math.pi)-math.pi

def geometry(a,b,t):
    out={}
    for k in ['head_center','grip','root']:
        out[k]=mix(a[k],b[k],t).tolist()
    if 'secondary_grip' in a and 'secondary_grip' in b:out['secondary_grip']=mix(a['secondary_grip'],b['secondary_grip'],t).tolist()
    out['head_angle']=float(a['head_angle']+(shortest(a['head_angle'],b['head_angle'])-a['head_angle'])*t)
    out['head_size']=float(a['head_size']*(1-t)+b['head_size']*t)
    if 'joints' in a and 'joints' in b:
        out['joints']=mix(a['joints'],b['joints'],t).tolist()
    return out

def controls(m,limbs=True,arms=False):
    c=np.asarray(m['head_center']);angle=m['head_angle'];h=m['head_size']
    down=np.array([math.sin(angle),math.cos(angle)]);right=np.array([down[1],-down[0]])
    # Head corners travel rigidly, instead of stretching a whole crouched image.
    points=[c+down*h*y+right*h*x for x,y in [(-.48,-.5),(.48,-.5),(-.48,.5),(.48,.5)]]
    points.extend([np.asarray(m['grip']),np.asarray(m['root'])])
    if 'secondary_grip' in m:points.append(np.asarray(m['secondary_grip']))
    # Wrist coordinates from the drafting model may be several pixels away
    # from the manually calibrated hilt. Do not constrain the same hand twice.
    if limbs:points.extend(np.asarray(p)for i,p in enumerate(m.get('joints',[])) if i not in [4,5])
    elif arms:points.extend(np.asarray(p)for p in m.get('joints',[])[:4])
    points.extend([np.array(v) for v in [[0,0],[1024,0],[0,1080],[1024,1080]]])
    return np.asarray(points,dtype=np.float64)/512

def tps_fit(dst,src):
    delta=dst[:,None,:]-dst[None,:,:];r2=(delta*delta).sum(axis=2)
    k=r2*np.log(r2+1e-9);p=np.c_[np.ones(len(dst)),dst]
    matrix=np.block([[k+np.eye(len(dst))*1e-6,p],[p.T,np.zeros((3,3))]])
    return np.linalg.lstsq(matrix,np.r_[src,np.zeros((3,2))],rcond=1e-9)[0]

def tps_map(dst,src,size,origin=(0,0)):
    w,h=size;coeff=tps_fit(dst,src)
    yy,xx=np.mgrid[:h,:w].astype(np.float32);points=np.dstack([xx+origin[0],yy+origin[1]])/512
    mapped=np.ones((h,w,2))*coeff[-3]+points[:,:,0:1]*coeff[-2]+points[:,:,1:2]*coeff[-1]
    for point,weight in zip(dst,coeff):
        r2=((points-point)**2).sum(axis=2);mapped+=(r2*np.log(r2+1e-9))[:,:,None]*weight
    return (mapped[:,:,0]*512-origin[0]).astype(np.float32),(mapped[:,:,1]*512-origin[1]).astype(np.float32)

def surface_map(dst,src,size,origin=(0,0)):
    """Local triangular skinning; distant hand constraints cannot bend a knee.

    All coordinates describe native pixels. No raster is enlarged. The head
    quad and manually bound grip are actual vertices of the deformation mesh.
    """
    dp=np.asarray(dst,dtype=np.float32)*512;sp=np.asarray(src,dtype=np.float32)*512
    low=np.floor(dp.min(axis=0)-2).astype(int);high=np.ceil(dp.max(axis=0)+2).astype(int)
    subdiv=cv2.Subdiv2D((int(low[0]),int(low[1]),int(high[0]-low[0]),int(high[1]-low[1])))
    for p in dp:subdiv.insert(tuple(map(float,p)))
    w,h=size;yy,xx=np.mgrid[:h,:w].astype(np.float32);mx=xx.copy();my=yy.copy()
    for tri in subdiv.getTriangleList().reshape(-1,3,2):
        ids=np.argmin(((tri[:,None,:]-dp[None,:,:])**2).sum(axis=2),axis=1)
        if len(set(ids))<3 or np.max(np.linalg.norm(tri-dp[ids],axis=1))>.1:continue
        d=dp[ids]-origin;s=sp[ids]-origin
        x0=max(0,int(np.floor(d[:,0].min())));x1=min(w,int(np.ceil(d[:,0].max()))+1)
        y0=max(0,int(np.floor(d[:,1].min())));y1=min(h,int(np.ceil(d[:,1].max()))+1)
        if x1<=x0 or y1<=y0:continue
        matrix=cv2.getAffineTransform(d.astype(np.float32),s.astype(np.float32))
        mask=np.zeros((y1-y0,x1-x0),np.uint8);cv2.fillConvexPoly(mask,np.rint(d-[x0,y0]).astype(np.int32),255)
        tx=xx[y0:y1,x0:x1];ty=yy[y0:y1,x0:x1];use=mask>0
        mx[y0:y1,x0:x1][use]=(matrix[0,0]*tx+matrix[0,1]*ty+matrix[0,2])[use]
        my[y0:y1,x0:x1][use]=(matrix[1,0]*tx+matrix[1,1]*ty+matrix[1,2])[use]
    return mx,my

def remap(image,mapping):
    return cv2.remap(image,*mapping,cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)

def protect_head_map(mapping,destination,source,size,origin=(0,0)):
    """Constrain the head interior, not only four unconstrained mesh vertices.

    Delaunay edges can cross a head quad when a nearby wrist changes sides.
    The whole head must follow its own affine transform in that region.
    """
    yy,xx=np.mgrid[:size[1],:size[0]].astype(np.float32)
    dx=xx+origin[0]-destination['head_center'][0];dy=yy+origin[1]-destination['head_center'][1]
    a=destination['head_angle'];right=np.array([math.cos(a),-math.sin(a)]);down=np.array([math.sin(a),math.cos(a)])
    lx=dx*right[0]+dy*right[1];ly=dx*down[0]+dy*down[1];h=destination['head_size']
    distance=np.maximum(np.abs(lx)/(h*.65),np.abs(ly)/(h*.52))
    edge=np.clip((distance-.92)/.08,0,1);weight=1-edge*edge*(3-2*edge)
    a=source['head_angle'];right=np.array([math.cos(a),-math.sin(a)]);down=np.array([math.sin(a),math.cos(a)]);scale=source['head_size']/h
    sx=source['head_center'][0]+scale*(lx*right[0]+ly*down[0])-origin[0]
    sy=source['head_center'][1]+scale*(lx*right[1]+ly*down[1])-origin[1]
    return ((mapping[0]*(1-weight)+sx*weight).astype(np.float32),(mapping[1]*(1-weight)+sy*weight).astype(np.float32))

def premultiply(image):
    pm=np.asarray(image).astype(np.float32)/255
    pm[:,:,:3]*=pm[:,:,3:4]
    return pm

def straight(pm):
    out=pm.copy();out[:,:,:3]/=np.maximum(1e-7,out[:,:,3:4])
    return np.rint(np.clip(out,0,1)*255).astype(np.uint8)

def guide(pm):
    # Ignore arbitrary RGB under alpha zero. Include silhouette in the solve.
    gray=cv2.cvtColor(pm[:,:,:3],cv2.COLOR_RGB2GRAY)
    return np.clip((gray*.7+pm[:,:,3]*.28)*255,0,255).astype(np.uint8)

class Tween:
    def __init__(self,a,b,marks_a,marks_b,fingers_a=None,fingers_b=None,arms=False,protect_head=False,opaque_silhouette=False):
        self.arms=arms
        self.protect_head=protect_head
        self.opaque_silhouette=opaque_silhouette
        self.original_a=np.asarray(a);self.original_b=np.asarray(b);self.ma=marks_a;self.mb=marks_b
        self.original_fa=np.zeros_like(self.original_a) if fingers_a is None else np.asarray(fingers_a)
        self.original_fb=np.zeros_like(self.original_b) if fingers_b is None else np.asarray(fingers_b)
        self.full_size=(self.original_a.shape[1],self.original_a.shape[0]);self.same=np.array_equal(self.original_a,self.original_b) and marks_a==marks_b
        yy,xx=np.where(np.maximum(self.original_a[:,:,3],self.original_b[:,:,3])>0)
        x0=max(0,int(xx.min())-48);y0=max(0,int(yy.min())-48);x1=min(self.full_size[0],int(xx.max())+49);y1=min(self.full_size[1],int(yy.max())+49)
        self.origin=(x0,y0);self.box=(x0,y0,x1,y1);self.size=(x1-x0,y1-y0)
        self.a=self.original_a[y0:y1,x0:x1];self.b=self.original_b[y0:y1,x0:x1]
        self.fa=self.original_fa[y0:y1,x0:x1];self.fb=self.original_fb[y0:y1,x0:x1]
        if self.same:return
        # A walk cycle exchanges occlusion between the two shins. Forcing drafted
        # knee identities through that crossing folds the texture triangles.
        # Align only rigid head, actual hands and ground; learned correspondence
        # handles limb occlusion, rather than treating a pose draft as a rig.
        self.middle=geometry(marks_a,marks_b,.5)
        cm=controls(self.middle,False,arms)
        map_a=surface_map(cm,controls(marks_a,False,arms),self.size,self.origin);map_b=surface_map(cm,controls(marks_b,False,arms),self.size,self.origin)
        if self.protect_head:
            map_a=protect_head_map(map_a,self.middle,marks_a,self.size,self.origin)
            map_b=protect_head_map(map_b,self.middle,marks_b,self.size,self.origin)
        self.na=remap(premultiply(self.a),map_a);self.nb=remap(premultiply(self.b),map_b)
        self.nfa=remap(premultiply(self.fa),map_a);self.nfb=remap(premultiply(self.fb),map_b)
        self.neural=bool(os.environ.get('SWORDSMAN_RIFE_MODEL'))
        if self.neural:
            yy,xx=np.mgrid[:self.size[1],:self.size[0]].astype(np.float32);self.x=xx;self.y=yy
            return
        dis=cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
        dis.setFinestScale(0);dis.setGradientDescentIterations(40);dis.setVariationalRefinementIterations(8)
        ga,gb=guide(self.na),guide(self.nb)
        self.ab=dis.calc(ga,gb,None);self.ba=dis.calc(gb,ga,None)
        # The grip/head anchors must remain exact after the residual solve.
        yy,xx=np.mgrid[:self.size[1],:self.size[0]].astype(np.float32)
        self.x=xx;self.y=yy
        center=np.asarray(self.middle['head_center'])-self.origin;h=self.middle['head_size']
        protect=np.exp(-(((xx-center[0])/(h*.8))**4+((yy-center[1])/(h*.85))**4))
        grip=np.asarray(self.middle['grip'])-self.origin;protect=np.maximum(protect,np.exp(-(((xx-grip[0])/22)**4+((yy-grip[1])/22)**4)))
        for px,py in self.middle.get('joints',[]):
            px-=self.origin[0];py-=self.origin[1]
            protect=np.maximum(protect,np.exp(-(((xx-px)/16)**4+((yy-py)/16)**4)))
        self.ab*=1-protect[:,:,None];self.ba*=1-protect[:,:,None]
        if not np.isfinite(self.ab).all() or not np.isfinite(self.ba).all():raise ValueError('Nonfinite motion field')

    def sample(self,t,geometry_override=None):
        if t<=1e-8 or t>=1-1e-8:
            body,fingers,marks=(self.original_a,self.original_fa,self.ma)if t<=1e-8 else(self.original_b,self.original_fb,self.mb)
            if geometry_override is not None and geometry_override!=marks:
                field=surface_map(controls(geometry_override,False,self.arms),controls(marks,False,self.arms),self.full_size)
                return straight(remap(premultiply(body),field)),straight(remap(premultiply(fingers),field)),geometry_override
            return body.copy(),fingers.copy(),marks
        marks=geometry(self.ma,self.mb,t) if geometry_override is None else geometry_override
        if self.same:return self.original_a.copy(),self.original_fa.copy(),marks
        if self.neural:
            from motion_neural import engine
            flow,weight=engine().fields(self.na,self.nb,t)
            if self.protect_head:
                # The head is already registered to the same rigid native
                # rectangle. Residual neural flow may mistake a passing arm
                # for occlusion and erase it. Keep that residual at zero in
                # the head core; the final geometric map still translates
                # and rotates the whole head along the authored body path.
                center=np.asarray(self.middle['head_center'])-self.origin;h=self.middle['head_size']
                protect=np.exp(-(((self.x-center[0])/(h*.72))**8+((self.y-center[1])/(h*.70))**8)).astype(np.float32)
                flow=flow*(1-protect[None,:,:])
                weight=weight*(1-protect)+(1-t)*protect
            ma=(self.x+flow[0],self.y+flow[1]);mb=(self.x+flow[2],self.y+flow[3])
        def blend(a,b,solid=False):
            if self.neural:
                aw=remap(a,ma);bw=remap(b,mb);mixed=aw*weight[:,:,None]+bw*(1-weight[:,:,None])
            else:
                aw=remap(a,(self.x-self.ab[:,:,0]*t,self.y-self.ab[:,:,1]*t))
                bw=remap(b,(self.x-self.ba[:,:,0]*(1-t),self.y-self.ba[:,:,1]*(1-t)))
                mixed=aw*(1-t)+bw*t
            if solid and (not self.neural or self.arms or self.opaque_silhouette):
                def distance(alpha):
                    mask=(alpha>.5).astype(np.uint8)
                    return cv2.distanceTransform(mask,cv2.DIST_L2,5)-cv2.distanceTransform(1-mask,cv2.DIST_L2,5)
                alpha=np.clip((distance(aw[:,:,3])*(1-t)+distance(bw[:,:,3])*t)*.75+.5,0,1)[:,:,None]
                mixed[:,:,:3]*=alpha/np.maximum(1e-7,mixed[:,:,3:4]);mixed[:,:,3:4]=alpha
            return mixed
        mapping=surface_map(controls(marks,False,self.arms),controls(self.middle,False,self.arms),self.size,self.origin)
        if self.protect_head:mapping=protect_head_map(mapping,marks,self.middle,self.size,self.origin)
        body=np.zeros_like(self.original_a);fingers=np.zeros_like(body);x0,y0,x1,y1=self.box
        body[y0:y1,x0:x1]=straight(remap(blend(self.na,self.nb,True),mapping));fingers[y0:y1,x0:x1]=straight(remap(blend(self.nfa,self.nfb),mapping))
        return body,fingers,marks
