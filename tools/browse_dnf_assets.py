from __future__ import annotations
import argparse, csv, functools, io, json, mimetypes, sqlite3, struct, threading, zipfile
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from pathlib import Path
from dnf_asset_reader import parse as img_parse, decode as decode_frame
from dnf_asset_store import LOCK, cache_home

LIB = None
EXPORTS = None

def resolved_frame(parsed,index):
 if index<0 or index>=len(parsed['frames']):raise ValueError('Frame out of range')
 frame=parsed['frames'][index];seen=set()
 while 'link' in frame:
  link=frame['link']
  if link in seen or not 0<=link<len(parsed['frames']):raise ValueError('Invalid IMG frame link')
  seen.add(link);frame=parsed['frames'][link]
 return frame

@functools.lru_cache(maxsize=32)
def load_img(aid):
 with sqlite3.connect(LIB/'catalog.sqlite') as c:
  c.row_factory=sqlite3.Row;row=c.execute('select * from assets where id=?',(aid,)).fetchone()
  if row is None or row['kind']!='img': raise ValueError('未找到图像资源')
  row=dict(row)
 data=(LIB/row['local_path']).read_bytes();parsed=img_parse(data)
 parsed['count']=len(parsed['frames'])
 return row,data,parsed

@functools.lru_cache(maxsize=1)
def string_table():
 with sqlite3.connect(LIB/'pvf_config.sqlite') as c:
  row=c.execute("select content from files where path='stringtable.bin'").fetchone()
 if row is None:return []
 data=row[0];count=struct.unpack_from('<I',data)[0];out=[]
 for i in range(count):
  a,b=struct.unpack_from('<2I',data,4+i*4)
  out.append(data[4+a:4+b].decode('gbk','replace').rstrip('\0'))
 return out

def script_text(raw):
 if not raw.startswith(b'\xb0\xd0'):
  try:return raw.decode('utf-8-sig')
  except UnicodeDecodeError:return raw.decode('gbk','replace')
 strings=string_table();lines=['# PVF token view: localization links retain numeric IDs.'];line=[]
 for p in range(2,len(raw)-4,5):
  kind=raw[p];value=struct.unpack_from('<I',raw,p+1)[0]
  s=strings[value] if value<len(strings) else '#'+str(value)
  if kind==5:
   if line:lines.append('\t'.join(line));line=[]
   lines.append('\n'+s)
  elif kind==7:line.append('`'+s+'`')
  elif kind==4:line.append(str(struct.unpack_from('<f',raw,p+1)[0]))
  elif kind in (2,3):line.append(str(struct.unpack_from('<i',raw,p+1)[0]))
  elif kind==10:line.append('{string-link-name:'+s+'}')
  else:line.append('{token:'+str(kind)+',value:'+str(value)+'}')
 if line:lines.append('\t'.join(line))
 return '\n'.join(lines)

class Handler(SimpleHTTPRequestHandler):
 def __init__(self,*args,**kwargs):super().__init__(*args,directory=str(LIB),**kwargs)
 def log_message(self,fmt,*args):pass
 def send(self,data,ctype='application/json; charset=utf-8',filename=None):
  if not isinstance(data,bytes):data=json.dumps(data,ensure_ascii=False).encode()
  self.send_response(200);self.send_header('Content-Type',ctype);self.send_header('Content-Length',str(len(data)))
  self.send_header('X-Content-Type-Options','nosniff')
  if filename:self.send_header('Content-Disposition','attachment; filename="'+filename+'"')
  self.end_headers();self.wfile.write(data)
 def do_GET(self):
  url=urlsplit(self.path);q={k:v[0] for k,v in parse_qs(url.query).items()};route=url.path
  try:
   if route=='/':self.path='/index.html';return super().do_GET()
   if route=='/api/summary':
    s=json.loads((LIB/'summary.json').read_text(encoding='utf-8'))
    if (LIB/'config_summary.json').exists():s['config']=json.loads((LIB/'config_summary.json').read_text(encoding='utf-8'))
    return self.send(s)
   if route=='/api/list':
    tab=q.get('tab','assets');limit=min(100,int(q.get('limit',36)));page=max(0,int(q.get('page',0)));query=q.get('q','');params=[];where=[]
    dbname='catalog.sqlite' if tab=='assets' else 'pvf_config.sqlite'
    with sqlite3.connect(LIB/dbname) as c:
     c.row_factory=sqlite3.Row
     if tab=='assets':
      table='assets';columns='id,category,kind,container,original_path,local_path,frame_count,validation,bytes'
      if q.get('category'):where.append('category=?');params.append(q['category'])
      if query:where.append('(original_path like ? or container like ?)');params.extend(['%'+query+'%']*2)
      order='category,original_path,container'
     elif tab=='animations':
      table='animations';columns='path,status,frame_count,duration_ms,error'
      if query:where.append('path like ?');params.append('%'+query+'%')
      order='path'
     else:
      table='files';columns='path,extension,bytes,crc_ok'
      if query:where.append('path like ?');params.append('%'+query+'%')
      order='path'
     condition=' where '+' and '.join(where) if where else ''
     total=c.execute('select count(*) from '+table+condition,params).fetchone()[0]
     rows=[dict(r) for r in c.execute('select '+columns+' from '+table+condition+' order by '+order+' limit ? offset ?',params+[limit,page*limit])]
    return self.send(dict(total=total,rows=rows,page=page))
   if route=='/api/asset':
    with sqlite3.connect(LIB/'catalog.sqlite') as c:
     c.row_factory=sqlite3.Row;r=c.execute('select * from assets where id=?',(q['id'],)).fetchone()
     if r is None:raise ValueError('未找到资源')
     r=dict(r);r['detail']=json.loads(r['detail'])
     r['path_variants']=c.execute('select count(*) from assets where lower(original_path)=lower(?)',(r['original_path'],)).fetchone()[0]
    if r['kind']=='img':
     try:
      _,data,parsed=load_img(q['id']);r['frame_count']=parsed['count']
      selected=min(max(0,int(q.get('frame',0))),max(0,parsed['count']-1))
      r['selected_frame']=resolved_frame(parsed,selected)
     except Exception as exc:r['preview_error']=str(exc)
    return self.send(r)
   if route=='/api/animation':
    with sqlite3.connect(LIB/'pvf_config.sqlite') as c:
     c.row_factory=sqlite3.Row;r=c.execute('select * from animations where path=?',(q['path'],)).fetchone()
     if r is None:raise ValueError('未找到动画')
     r=dict(r);r['metadata']=json.loads(r['metadata']) if r['metadata'] else None
     r['references']=[dict(x) for x in c.execute('select * from image_references where animation=?',(q['path'],))]
     r['sound_references']=[dict(x) for x in c.execute('select * from sound_references where animation=?',(q['path'],))]
    return self.send(r)
   if route=='/api/config':
    with sqlite3.connect(LIB/'pvf_config.sqlite') as c:
     r=c.execute('select content,crc_ok from files where path=?',(q['path'],)).fetchone()
    if not r:raise ValueError('未找到配置')
    if q.get('download'):return self.send(r[0],'application/octet-stream','pvf_resource.bin')
    text=script_text(r[0]);return self.send(dict(path=q['path'],crc_ok=bool(r[1]),text=text[:1000000],truncated=len(text)>1000000))
   if route.startswith('/frame/'):
    parts=route.strip('/').split('/');aid=parts[1];n=int(parts[2].split('.')[0])
    _,data,parsed=load_img(aid);im,fr=decode_frame(data,parsed,n)
    out=io.BytesIO();im.save(out,format='PNG')
    return self.send(out.getvalue(),'image/png')
   if route=='/api/frames':
    row,data,parsed=load_img(q['id'])
    meta=dict(source=row,frames=parsed['frames'],note='PNG为原始裁切尺寸；x/y、cw/ch对应原始画布。IMG索引顺序不等同于ANI动作帧序。')
    return self.send(meta,filename=q['id']+'_frames.json')
   if route=='/api/export':
    row,data,parsed=load_img(q['id']);target=EXPORTS/row['category'];target.mkdir(parents=True,exist_ok=True)
    dest=target/(q['id']+'.zip');frames=[];failures=[]
    with zipfile.ZipFile(dest,'w',compression=zipfile.ZIP_STORED) as z:
     for n in range(parsed['count']):
      try:
       im,fr=decode_frame(data,parsed,n);buf=io.BytesIO();im.save(buf,format='PNG')
       z.writestr(f'{n:05d}.png',buf.getvalue());frames.append(dict(index=n,**fr))
      except Exception as exc:failures.append(dict(frame=n,error=str(exc)))
     z.writestr('frames.json',json.dumps(dict(source=row,frames=frames,failures=failures),ensure_ascii=False,indent=2))
    return self.send(dest.read_bytes(),'application/zip',q['id']+'.zip')
   return super().do_GET()
  except (BrokenPipeError,ConnectionResetError):return
  except Exception as exc:
   data=json.dumps(dict(error=str(exc)),ensure_ascii=False).encode()
   self.send_response(422);self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Content-Length',str(len(data)));self.end_headers()
   try:self.wfile.write(data)
   except (BrokenPipeError,ConnectionResetError):pass

if __name__=='__main__':
 parser=argparse.ArgumentParser(description='Browse the external versioned resource library; Pillow required.')
 parser.add_argument('--port',type=int,default=8769)
 parser.add_argument('--library',type=Path)
 args=parser.parse_args()
 lock=json.loads(LOCK.read_text(encoding='utf-8'));home=cache_home()
 LIB=args.library.resolve() if args.library else home/lock['version']/'library_v1'
 EXPORTS=home/'exports'/lock['version']
 if not all((LIB/name).is_file() for name in ['catalog.sqlite','pvf_config.sqlite','index.html']):
  parser.error('Full library missing; run: python tools/dnf_asset_store.py sync --full')
 print('DNF resource library: http://127.0.0.1:'+str(args.port),flush=True)
 print('Export folder: '+str(EXPORTS),flush=True)
 ThreadingHTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
