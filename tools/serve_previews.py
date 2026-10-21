"""Loopback-only art previews with byte ranges for native video frame stepping.

SimpleHTTPServer's non-range responses can leave a browser's media seekable
range at [0,0], even after the complete short MP4 is buffered. That makes an
otherwise correct next-frame control repeatedly return to the first frame.
"""
from pathlib import Path
from http.server import SimpleHTTPRequestHandler,ThreadingHTTPServer
import argparse,re

ROOT=Path(__file__).resolve().parents[1]/'docs/previews'

class PreviewHandler(SimpleHTTPRequestHandler):
 def __init__(self,*args,**kwargs):super().__init__(*args,directory=str(ROOT),**kwargs)
 def end_headers(self):
  self.send_header('Accept-Ranges','bytes');super().end_headers()
 def send_head(self):
  self._range=None;path=Path(self.translate_path(self.path)).resolve()
  if not path.is_relative_to(ROOT.resolve()):self.send_error(403);return None
  header=self.headers.get('Range')
  if not header or not path.is_file():return super().send_head()
  size=path.stat().st_size;match=re.fullmatch(r'bytes=(\d*)-(\d*)',header)
  if not match or not any(match.groups()):self.send_error(400,'Single byte range required');return None
  a,b=match.groups();start=int(a)if a else max(0,size-int(b));end=min(size-1,int(b))if a and b else size-1
  if start>=size or start>end or size==0:
   self.send_response(416);self.send_header('Content-Range',f'bytes */{size}');self.send_header('Content-Length','0');self.end_headers();return None
  file=path.open('rb');file.seek(start);self._range=end-start+1
  self.send_response(206);self.send_header('Content-Type',self.guess_type(str(path)));self.send_header('Content-Range',f'bytes {start}-{end}/{size}');self.send_header('Content-Length',str(self._range));self.send_header('Last-Modified',self.date_time_string(path.stat().st_mtime));self.end_headers();return file
 def copyfile(self,source,outputfile):
  if self._range is None:return super().copyfile(source,outputfile)
  left=self._range
  while left:
   chunk=source.read(min(left,64*1024))
   if not chunk:break
   outputfile.write(chunk);left-=len(chunk)

def main():
 p=argparse.ArgumentParser();p.add_argument('--port',type=int,default=8768);args=p.parse_args()
 server=ThreadingHTTPServer(('127.0.0.1',args.port),PreviewHandler)
 print(f'Range-enabled previews: http://127.0.0.1:{args.port}/',flush=True)
 try:server.serve_forever()
 except KeyboardInterrupt:pass
 finally:server.server_close()

if __name__=='__main__':main()
