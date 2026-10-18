"""Download/hash-check only the official MIT RIFE 4.6 correspondence model.

Usage: python tools/setup_motion_model.py [--proxy http://127.0.0.1:7890]
Python dependencies: python -m pip install -r tools/requirements-motion.txt
No executable, weights or downloaded archive is committed to the game.
"""
from pathlib import Path
import argparse,hashlib,urllib.request,zipfile
ROOT=Path(__file__).resolve().parents[1]
URL='https://github.com/nihui/rife-ncnn-vulkan/releases/download/20221029/rife-ncnn-vulkan-20221029-windows.zip'
ARCHIVE_SHA='d8e4d772d26cd8006ef0ad0bc82eb191b53c68677d1ae2f42506d74cbbbea606'
FILES={'flownet.bin':'f334ed2260149ce0188a6dcf049844e8b0cdd912e01cbcfb63553157d2508958','flownet.param':'28df14d57a225725ee5386f52eba422488450d37c9f40800ed4f62e8ba846692'}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser();p.add_argument('--proxy');p.add_argument('--destination',type=Path,default=ROOT/'temp/motion_model/rife-v4.6');args=p.parse_args()
 dest=args.destination.resolve();dest.mkdir(parents=True,exist_ok=True)
 if all((dest/f).is_file()and sha(dest/f)==s for f,s in FILES.items()):print(dest);return
 archive=ROOT/'temp/rife-official.zip';archive.parent.mkdir(exist_ok=True)
 if not archive.exists()or sha(archive)!=ARCHIVE_SHA:
  opener=urllib.request.build_opener(urllib.request.ProxyHandler({'http':args.proxy,'https':args.proxy})if args.proxy else urllib.request.ProxyHandler())
  with opener.open(URL,timeout=60)as source,archive.open('wb')as target:
   while chunk:=source.read(1024*1024):target.write(chunk)
 if sha(archive)!=ARCHIVE_SHA:raise ValueError('Official archive hash mismatch')
 prefix='rife-ncnn-vulkan-20221029-windows/rife-v4.6/'
 with zipfile.ZipFile(archive)as z:
  for file,expected in FILES.items():
   content=z.read(prefix+file)
   if hashlib.sha256(content).hexdigest()!=expected:raise ValueError('Official model hash mismatch: '+file)
   (dest/file).write_bytes(content)
 print(dest)
if __name__=='__main__':main()
