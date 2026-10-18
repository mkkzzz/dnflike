"""Native-resolution RGBA motion from RIFE 4.6 correspondence/occlusion.

Uses the MIT-licensed official ncnn model; no artwork synthesis or enlargement.
The same predicted backward fields warp premultiplied color, alpha and fingers.
Model inputs are kept alive explicitly: ncnn.Mat may borrow a NumPy buffer.
"""
from pathlib import Path
import os
import cv2,numpy as np

_engine=None

class Correspondence:
 def __init__(self,folder):
  import ncnn
  self.ncnn=ncnn;self.layers=[]
  class Warp(ncnn.Layer):
   def __init__(self):
    super().__init__();self.one_blob_only=False;self.support_inplace=False
   def forward(self,bottoms,tops,opt):
    src=np.array(bottoms[0]);flow=np.array(bottoms[1]);h,w=src.shape[1:];yy,xx=np.mgrid[:h,:w].astype(np.float32)
    value=cv2.remap(src.transpose(1,2,0),xx+flow[0],yy+flow[1],cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)
    value=np.ascontiguousarray(value.transpose(2,0,1));tops[0].clone_from(ncnn.Mat(value));return 0
  def create():
   layer=Warp();self.layers.append(layer);return layer
  self.net=ncnn.Net();self.net.opt.num_threads=4;self.net.opt.use_packing_layout=False
  self.net.register_custom_layer('rife.Warp',create,lambda layer:self.layers.remove(layer))
  for kind in ['param','bin']:
   p=Path(folder)/('flownet.'+kind)
   code=self.net.load_param(str(p)) if kind=='param' else self.net.load_model(str(p))
   if code:raise RuntimeError('RIFE model load failed: '+str(p))

 def fields(self,a,b,t):
  h,w=a.shape[:2];inputs=[];buffers=[]
  for image in [a,b]:
   # Same neutral matte for both inputs. Arbitrary RGB under alpha zero ignored.
   rgb=image[:,:,:3]+(1-image[:,:,3:4])*.145
   rgb=np.pad(rgb,((0,(-h)%32),(0,(-w)%32),(0,0)),mode='edge')
   buffers.append(np.ascontiguousarray(rgb.transpose(2,0,1),dtype=np.float32))
  buffers.append(np.full((1,*buffers[0].shape[1:]),t,np.float32))
  for array in buffers:inputs.append(self.ncnn.Mat(array).clone())
  ex=self.net.create_extractor()
  for i,value in enumerate(inputs):ex.input('in'+str(i),value)
  code,flow=ex.extract('328')
  if code:raise RuntimeError('RIFE flow extraction failed')
  code,mask=ex.extract('333')
  if code:raise RuntimeError('RIFE occlusion extraction failed')
  return np.array(flow)[:,:h,:w].copy(),np.array(mask)[0,:h,:w].copy()

def engine():
 global _engine
 if _engine is None:
  folder=os.environ.get('SWORDSMAN_RIFE_MODEL','')
  if not folder:raise ValueError('Set SWORDSMAN_RIFE_MODEL to the audited official rife-v4.6 model folder')
  _engine=Correspondence(folder)
 return _engine
