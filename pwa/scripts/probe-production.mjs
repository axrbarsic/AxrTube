// Read-only bounded production probe. Never print signed media URLs.
const origin='https://axrtube.axrbarsic.workers.dev';
const id=process.argv[2]||'dQw4w9WgXcQ';
if(!/^[\w-]{11}$/.test(id))throw Error('Invalid video ID');
async function read(url,options={}){return fetch(url,{...options,signal:AbortSignal.timeout(20000)})}
for(const mode of ['video','audio']){
  const checks=[];
  try{
    const r=await read(origin+'/api/resolve?id='+id+'&mode='+mode);
    checks.push({step:'resolve',status:r.status});
    const data=await r.json();
    if(!r.ok||data.id!==id||!/^\/(media|audio-master)\?/.test(data.source||''))throw Error('Resolver failed');
    let path=data.source,segment;
    if(data.kind==='file')segment=path;
    for(let depth=0;!segment&&depth<4;depth++){
      const response=await read(new URL(path,origin));
      const text=await response.text();
      checks.push({step:'manifest-'+depth,status:response.status,hls:text.startsWith('#EXTM3U')});
      if(!response.ok||!text.startsWith('#EXTM3U'))throw Error('Manifest unavailable');
      const lines=text.split('\n').map(s=>s.trim());
      const next=lines.find(s=>s&&!s.startsWith('#'));
      if(!next?.startsWith('/media?'))throw Error('Manifest has no relayed entries');
      if(lines.some(s=>s.startsWith('#EXTINF:'))){segment=next;break}
      path=next;
    }
    if(!segment)throw Error('Media playlist missing');
    const rseg=await read(new URL(segment,origin),{headers:{Range:'bytes=0-255'}});
    const reader=rseg.body.getReader();const first=await reader.read();await reader.cancel();
    const bytes=first.value?.byteLength||0;
    const type=rseg.headers.get('content-type');
    const prefix=first.value;
    const valid=rseg.ok&&bytes>0&&!/text|json|html/.test(type||'')&&
      (data.kind!=='file'||(type?.startsWith('audio/mp4')&&Buffer.from(prefix.slice(4,8)).toString()==='ftyp'));
    checks.push({step:'segment',status:rseg.status,type,bytesRead:bytes,valid});
    if(!valid)throw Error('Media segment rejected');
    console.log(JSON.stringify({mode,ok:true,checks}));
  }catch{console.log(JSON.stringify({mode,ok:false,checks}));process.exitCode=1}
}
