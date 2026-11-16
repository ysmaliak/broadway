import sys,os,time,json,subprocess,uuid,threading
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
(ROOT / '.context').mkdir(exist_ok=True)
sys.path.insert(0, str(ROOT / 'Tests'))
import split_view as sv
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
class Page(BaseHTTPRequestHandler):
 def do_GET(self):
  name=self.path.strip('/')
  color='#347291' if name=='Work' else '#864837'
  body=f'<html style="background:{color};color:white;font:48px system-ui"><title>{name}</title><h1>{name}</h1><div style="height:800px;border:8px solid white">Local test page</div></html>'.encode()
  self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def log_message(self,*a):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Page);threading.Thread(target=server.serve_forever,daemon=True).start()
base=f'http://127.0.0.1:{server.server_port}'
sv.use('fold-film-'+uuid.uuid4().hex[:8])
phase=sys.argv[1] if len(sys.argv)>1 else 'motion'; dark=sys.argv[2] if len(sys.argv)>2 else 'dark'
filming = os.getenv('SEARCH_FILM') == '1'
policy = sys.argv[3] if len(sys.argv)>3 else 'normal'
if filming:
 subprocess.run(['swiftc','-parse-as-library','Tests/WindowCapture.swift','-o','.context/capture'],check=True)
if os.getenv('FILM_APP'):sv.APP=os.environ['FILM_APP']
for key,value in {'bench':True,'spaces':True,'tabs.groups':True,'tabs.aiGroups':False,'ai':False,'ai.groups':False,'tabs.cards':False,'sidebar':True,'start.fresh':False,'tabs.newAtBottom':True,'split':False}.items():
 subprocess.run(['defaults','write',sv.SUITE,key,'-bool',str(value).lower()],check=True)
subprocess.run(['defaults','write',sv.SUITE,'look','-string',dark],check=True)
subprocess.run(['defaults','write',sv.SUITE,'sidebar.width','-float','252'],check=True)
for key,value in {'motion.testReduced':policy=='reduced','motion.testLowPower':policy=='power'}.items():
 subprocess.run(['defaults','write',sv.SUITE,key,'-bool',str(value).lower()],check=True)
subprocess.run(['open','-n','-g','--env',f'SEARCH_PROBE={sv.W}','--env','SEARCH_SHOWN=1',sv.APP],check=True)
for _ in range(200):
 if os.path.exists(sv.SOCK):break
 time.sleep(.1)
time.sleep(2)
pid=next(iter(sv.holding() & sv.running()))
out=Path('.context')/(phase+'-'+dark);out.mkdir(exist_ok=True)
(out/'world.json').write_text(json.dumps({'pid':pid,'world':sv.W,'support':sv.SUPPORT,'suite':sv.SUITE}))
log=[]
t = sv.T()
def cmd(**r):return sv.cmd(r)
def film(name,action,seconds=1.4):
 if not filming:
  result=action();time.sleep(.6);return result
 folder=out/name
 if (folder/"ready").exists():(folder/"ready").unlink()
 if (folder/"times.json").exists():(folder/"times.json").unlink()
 posture=cmd(do='idle',action='unhide')
 p=subprocess.Popen([str(Path('.context/capture').resolve()),pid,str(folder.resolve()),str(seconds),str(posture['number'])],stdout=subprocess.PIPE,text=True)
 for _ in range(200):
  if (folder/'ready').exists() or p.poll()!=None:break
  time.sleep(.025)
 if p.poll()!=None:raise RuntimeError(p.communicate()[0])
 time.sleep(.15)
 start=time.time();a=action();log.append({'name':name,'action':a,'wall':start})
 print(name,p.communicate()[0],flush=True)
 times=json.loads((folder/'times.json').read_text())
 t.ok(name+' has complete window frames',len(times)>=2,{'count':len(times),'window':posture['number']})
 time.sleep(.5)
 return a
try:
 cmd(do='resize',width=1120,height=760,steps=1)
 if filming:
  posture=cmd(do='idle',action='front')
  log.append({'posture':posture})
  t.ok('test window is available for window capture',posture['visible'] and not posture['hidden'],posture)
 ids=[sv.sp('open',url=base+'/'+n)['resultID'] for n in ['Pinned A','Pinned B','Pinned C','List A','List B','List C','Below','Personal']]
 for id in ids:cmd(do='wait',id=id,seconds=10)
 cmd(do='group',id=ids[0],new=True,name='Pinned')
 for id in ids[1:3]:cmd(do='group',id=id,name='Pinned')
 cmd(do='group',name='Pinned',pinned=True)
 cmd(do='group',id=ids[3],new=True,name='List')
 for id in ids[4:6]:cmd(do='group',id=id,name='List')
 sv.sp('select',id=ids[-1]);time.sleep(1)
 for group in ['List','Pinned']:
  folded=film(group+'-fold',lambda:cmd(do='group',name=group,fold=True))
  t.ok(group+' folds',next(g for g in folded['groups'] if g['name']==group)['collapsed'])
  opened=film(group+'-unfold',lambda:cmd(do='group',name=group,fold=True))
  t.ok(group+' unfolds',not next(g for g in opened['groups'] if g['name']==group)['collapsed'])
 film('pin-to-list',lambda:cmd(do='group',name='Pinned',pinned=False))
 film('pin-to-top',lambda:cmd(do='group',name='Pinned',pinned=True))
 t.ok('pinning keeps the folder members',len(next(g for g in cmd(do='group')['groups'] if g['name']=='Pinned')['tabs'])==3)
 for n in range(6):
  id=sv.sp('open',url=base+f'/Tall{n}')['resultID']
  cmd(do='group',id=id,name='Pinned')
 for n in range(8):
  id=sv.sp('open',url=base+f'/Loose{n}')['resultID']
  cmd(do='group',id=id,name='none')
 sv.sp('select',id=ids[-1])
 cmd(do='resize',width=1120,height=500,steps=1);time.sleep(1)
 column=cmd(do='columnscroll')
 list_y=column['height']-33-column['measured']['room']/2
 column=cmd(do='columnscroll',wheel=80,y=list_y);time.sleep(.3)
 t.ok('overflowing list scrolls',column['scrolls'] and column.get('offset',0)>0,column)
 print('  skip  the pinned cap: pinned folders scroll with the list since 2026-11-06, so there is no cap')
 for group in ['List','Pinned']:
  film(group+'-scrolled-fold',lambda:cmd(do='group',name=group,fold=True))
  film(group+'-scrolled-unfold',lambda:cmd(do='group',name=group,fold=True))
 cmd(do='resize',width=1120,height=760,steps=1);time.sleep(.8)
 column=cmd(do='columnscroll')
 list_y=column['height']-33-column['measured']['room']/2
 cmd(do='columnscroll',wheel=-2000,y=list_y)
 cmd(do='columnscroll',wheel=120,y=list_y);time.sleep(.3)
 before_column=cmd(do='columnscroll')
 before_rows=cmd(do='rowframes')['rows']
 cmd(do='space',action='new',name='Work'); work=sv.sp('open',url=base+'/Work')['resultID'];cmd(do='wait',id=work,seconds=10)
 cmd(do='space',action='go',index=1);time.sleep(1)
 first_column=cmd(do='columnscroll')
 first_rows=cmd(do='rowframes')['rows']
 log.append({'restoration':{'before':before_column,'firstReturn':first_column}})
 t.ok('first return restores the list offset',abs(first_column.get('offset',0)-before_column.get('offset',0))<1,(before_column,first_column))
 t.ok('first return restores the pinned offset',abs(first_rows[ids[0]][1]-before_rows[ids[0]][1])<1,(before_rows[ids[0]],first_rows[ids[0]]))
 film('space-key',lambda:cmd(do='press',code=19,chars='2',mods=['ctrl']))
 t.ok('Control 2 lands on Work',cmd(do='space')['current']=='Work')
 film('space-key-back',lambda:cmd(do='press',code=18,chars='1',mods=['ctrl']))
 t.ok('Control 1 lands on Personal',cmd(do='space')['current']=='Personal')
 after_column=cmd(do='columnscroll')
 after_rows=cmd(do='rowframes')['rows']
 t.ok('returning restores the list offset',abs(after_column.get('offset',0)-before_column.get('offset',0))<1,(before_column,after_column))
 t.ok('returning restores the pinned offset',abs(after_rows[ids[0]][1]-before_rows[ids[0]][1])<1,(before_rows[ids[0]],after_rows[ids[0]]))
 cmd(do='space',action='go',index=2);time.sleep(.6)
 film('space-click',lambda:cmd(do='space',action='foot',index=1),2.5)
 t.ok('foot icon lands on Personal',cmd(do='space')['current']=='Personal')
 cmd(do='space',action='go',index=1);time.sleep(1)
 film('space-swipe',lambda:cmd(do='space',action='trackpad',stops=[-240],speed=700),2)
 t.ok('trackpad lands on Work',cmd(do='space')['current']=='Work')
 cmd(do='space',action='go',index=1);time.sleep(.6)
 film('space-cancel',lambda:cmd(do='space',action='trackpad',stops=[-110],speed=700,cancel=True),2)
 t.ok('cancelled trackpad returns to Personal',cmd(do='space')['current']=='Personal')
 film('space-reverse',lambda:cmd(do='space',action='trackpad',stops=[-110,-15],speed=700,momentum=False),2)
 t.ok('reversed trackpad returns to Personal',cmd(do='space')['current']=='Personal')
 cmd(do='columnscroll',wheel=70,y=160);time.sleep(.3)
 scrolled_column=cmd(do='columnscroll')
 scrolled_rows=cmd(do='rowframes')['rows']
 cmd(do='space',action='go',index=2);time.sleep(.6)
 film('space-scrolled-return',lambda:cmd(do='press',code=18,chars='1',mods=['ctrl']),2)
 returned_column=cmd(do='columnscroll')
 returned_rows=cmd(do='rowframes')['rows']
 t.ok('scrolled return keeps the list offset',abs(returned_column.get('offset',0)-scrolled_column.get('offset',0))<1,(scrolled_column,returned_column))
 t.ok('scrolled return keeps the pinned offset',abs(returned_rows[ids[0]][1]-scrolled_rows[ids[0]][1])<1,(scrolled_rows[ids[0]],returned_rows[ids[0]]))
 t.ok('scrolled return keeps the cap',abs(returned_column['measured'].get('cap',-1)-scrolled_column['measured'].get('cap',-1))<1,(scrolled_column['measured'],returned_column['measured']))
 draft_column=cmd(do='columnscroll')
 draft_rows=cmd(do='rowframes')['rows']
 film('space-draft',lambda:cmd(do='space',action='ask'),2)
 t.ok('new space draft opens',cmd(do='space')['making'])
 film('space-draft-cancel',lambda:cmd(do='space',action='leave'),2)
 t.ok('draft cancellation returns to Personal',not cmd(do='space')['making'] and cmd(do='space')['current']=='Personal')
 t.ok('draft cancellation keeps the list offset',abs(cmd(do='columnscroll').get('offset',0)-draft_column.get('offset',0))<1,(draft_column,cmd(do='columnscroll')))
 t.ok('draft cancellation keeps the pinned offset',abs(cmd(do='rowframes')['rows'][ids[0]][1]-draft_rows[ids[0]][1])<1,(draft_rows[ids[0]],cmd(do='rowframes')['rows'][ids[0]]))
 (out/'log.json').write_text(json.dumps(log,indent=2))
finally:
 try:cmd(do='quit')
 except Exception:subprocess.run(['kill',pid])
 print('own test world retained:',sv.W,flush=True)

t.done()
sys.exit(1 if t.failed else 0)
