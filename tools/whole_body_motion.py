"""Whole-raster RIFE correspondence without a body/limb deformation rig.

The same field transports body and foreground fingers. The neural occlusion
selection chooses the visible complete source surface; it does not extrapolate
signed-distance silhouettes, which can turn crossing boots into long spikes.
"""
import numpy as np
import cv2
from actor_motion import premultiply,straight,geometry
from motion_neural import engine

class WholeBodyTween:
 def __init__(self,a,b,ga,gb,fa=None,fb=None,**_):
  self.oa=np.asarray(a);self.ob=np.asarray(b);self.ga=ga;self.gb=gb
  self.ofa=np.zeros_like(self.oa)if fa is None else np.asarray(fa)
  self.ofb=np.zeros_like(self.ob)if fb is None else np.asarray(fb)
  y,x=np.where(np.maximum(self.oa[:,:,3],self.ob[:,:,3])>0)
  self.x0=max(0,int(x.min())-40);self.x1=min(self.oa.shape[1],int(x.max())+41)
  self.y0=max(0,int(y.min())-40);self.y1=min(self.oa.shape[0],int(y.max())+41)
  cut=lambda im:premultiply(im[self.y0:self.y1,self.x0:self.x1])
  self.a,self.b,self.fa,self.fb=map(cut,[self.oa,self.ob,self.ofa,self.ofb])
  h,w=self.a.shape[:2];self.yy,self.xx=np.mgrid[:h,:w].astype(np.float32)
  self.same=np.array_equal(self.oa,self.ob)and np.array_equal(self.ofa,self.ofb)
 def sample(self,t,override=None):
  if t<=1e-8:return self.oa.copy(),self.ofa.copy(),self.ga.copy()
  if t>=1-1e-8:return self.ob.copy(),self.ofb.copy(),self.gb.copy()
  g=geometry(self.ga,self.gb,t)
  if self.same:return self.oa.copy(),self.ofa.copy(),g
  flow,weight=engine().fields(self.a,self.b,t)
  ma=(self.xx+flow[0],self.yy+flow[1]);mb=(self.xx+flow[2],self.yy+flow[3])
  warp=lambda im,m:cv2.remap(im,*m,cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
  def combine(a,b):
   aw,bw=warp(a,ma),warp(b,mb);w=weight[:,:,None]
   blend=aw*w+bw*(1-w);dominant=np.where(w>=.5,aw,bw)
   # Use learned occlusion for edges rather than creating semi-transparent limbs.
   both=(aw[:,:,3:4]>.8)&(bw[:,:,3:4]>.8)
   return np.where(both,blend,dominant)
  body=np.zeros_like(self.oa);fingers=np.zeros_like(body)
  body[self.y0:self.y1,self.x0:self.x1]=straight(combine(self.a,self.b))
  fingers[self.y0:self.y1,self.x0:self.x1]=straight(combine(self.fa,self.fb))
  # Follow the actual transported primary wrist; the weapon is never advanced
  # on an unrelated linear path while its painted hand follows a different arc.
  origin=np.array([self.x0,self.y0]);expected=np.asarray(g['grip'])-origin
  def locate(mark,m,aim):
   distance=(m[0]-(mark[0]-self.x0))**2+(m[1]-(mark[1]-self.y0))**2
   distance+=.015*((self.xx-aim[0])**2+(self.yy-aim[1])**2)
   iy,ix=np.unravel_index(np.argmin(distance),distance.shape)
   return np.array([ix+self.x0,iy+self.y0],float)
  pa=locate(self.ga['grip'],ma,expected);pb=locate(self.gb['grip'],mb,expected)
  g['grip']=(pa*(1-t)+pb*t).tolist()
  if 'secondary_grip'in g:
   aim=np.asarray(g['secondary_grip'])-origin
   sa=locate(self.ga['secondary_grip'],ma,aim);sb=locate(self.gb['secondary_grip'],mb,aim)
   g['secondary_grip']=(sa*(1-t)+sb*t).tolist()
  return body,fingers,g
