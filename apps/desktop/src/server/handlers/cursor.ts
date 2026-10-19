/** X11 cursor hints only: no focused text, document content or keystrokes. */
export const cursorProbe = String.raw`
import ctypes as C, json, sys
try:
    x=C.CDLL('libX11.so.6'); f=C.CDLL('libXfixes.so.3')
    x.XOpenDisplay.argtypes=[C.c_char_p]; x.XOpenDisplay.restype=C.c_void_p
    x.XCloseDisplay.argtypes=[C.c_void_p]
    x.XFree.argtypes=[C.c_void_p]
    d=x.XOpenDisplay(None)
    if not d: raise RuntimeError('display unavailable')
    class Cursor(C.Structure):
        _fields_=[('x',C.c_short),('y',C.c_short),('width',C.c_ushort),('height',C.c_ushort),('xhot',C.c_ushort),('yhot',C.c_ushort),('serial',C.c_ulong),('pixels',C.POINTER(C.c_ulong)),('atom',C.c_ulong),('name',C.c_char_p)]
    f.XFixesQueryVersion.argtypes=[C.c_void_p,C.POINTER(C.c_int),C.POINTER(C.c_int)]
    major=C.c_int(2); minor=C.c_int(0)
    if not f.XFixesQueryVersion(d,C.byref(major),C.byref(minor)) or major.value<2: raise RuntimeError('XFixes unavailable')
    f.XFixesGetCursorImage.argtypes=[C.c_void_p]; f.XFixesGetCursorImage.restype=C.POINTER(Cursor)
    x.XGetInputFocus.argtypes=[C.c_void_p,C.POINTER(C.c_ulong),C.POINTER(C.c_int)]
    focused=C.c_ulong(); revert=C.c_int(); x.XGetInputFocus(d,C.byref(focused),C.byref(revert))
    belongs=True
    if sys.argv[1]:
        target=int(sys.argv[1],0); window=focused.value; belongs=False
        x.XQueryTree.argtypes=[C.c_void_p,C.c_ulong,C.POINTER(C.c_ulong),C.POINTER(C.c_ulong),C.POINTER(C.POINTER(C.c_ulong)),C.POINTER(C.c_uint)]
        for _ in range(32):
            if window==target: belongs=True; break
            if window<=1: break
            root=C.c_ulong(); parent=C.c_ulong(); children=C.POINTER(C.c_ulong)(); count=C.c_uint()
            if not x.XQueryTree(d,window,C.byref(root),C.byref(parent),C.byref(children),C.byref(count)): break
            if children: x.XFree(children)
            if parent.value==window: break
            window=parent.value
    p=f.XFixesGetCursorImage(d)
    if not p: raise RuntimeError('cursor unavailable')
    c=p.contents; name=(c.name or b'').decode('utf-8','replace').lower()
    print(json.dumps({'supported':True,'textCursor':belongs and name in ['text','xterm','ibeam','i-beam','vertical-text'],'x':c.x,'y':c.y,'focus':str(focused.value)}))
    x.XFree(p); x.XCloseDisplay(d)
except Exception:
    print(json.dumps({'supported':False,'textCursor':False}))
`;
export type CursorHint = {supported:boolean;textCursor:boolean;x?:number;y?:number;focus?:string};
const pending=new Map<string,Promise<CursorHint>>();
const cache=new Map<string,{at:number;value:CursorHint}>();
export async function getCursorHint(display=process.env.DISPLAY || ':0',windowId=''):Promise<CursorHint> {
  const key=display+':'+windowId;
  const saved=cache.get(key);
  if(saved && Date.now()-saved.at<(saved.value.supported?500:30000))return saved.value;
  if(pending.has(key))return pending.get(key)!;
  const work=(async()=>{
    let value:CursorHint={supported:false,textCursor:false};
    try {
      const child=Bun.spawn(['python3','-c',cursorProbe,windowId],{env:{...process.env,DISPLAY:display},stdout:'pipe',stderr:'ignore'});
      const timeout=setTimeout(()=>child.kill(),1200);
      try {
        const [output,code]=await Promise.all([new Response(child.stdout).text(),child.exited]);
        if(code===0)value=JSON.parse(output);
      } finally {clearTimeout(timeout);}
    } catch { /* Unsupported hosts retain the phone's floating keyboard button. */ }
    cache.set(key,{at:Date.now(),value});
    while(cache.size>32)cache.delete(cache.keys().next().value!);
    return value;
  })();
  pending.set(key,work);
  try{return await work;}finally{pending.delete(key);}
}
