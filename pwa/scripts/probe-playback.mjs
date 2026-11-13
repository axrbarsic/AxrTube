// Decode a bounded audio interval via the real relay. Signed URLs stay in memory,
// never in files, process arguments, console output or the ffmpeg command line.
import {createServer} from 'node:http';
import {Readable} from 'node:stream';
import {spawn} from 'node:child_process';
import app from '../worker/index.js';
const id=process.argv[2]||'F1PEICLlEBk';
const production=process.argv.includes('--production');
if(!/^[\w-]{11}$/.test(id))throw Error('Invalid video ID');
const origin='https://axrtube.axrbarsic.workers.dev';
const request=url=>new Request(url);
const dispatch=req=>production?fetch(req):app.fetch(req);
const response=await dispatch(request(origin+'/api/resolve?id='+id+'&mode=audio'));
const item=await response.json();
if(!response.ok||item.id!==id||!/^\/(media|audio-master)\?/.test(item.source||'')){
  console.log(JSON.stringify({production,id,ok:false,stage:'resolve',status:response.status,diagnostics:item.diagnostics}));process.exit(1);
}
const requests=[];const connections=new Set();
const server=createServer(async(req,res)=>{
  try{
    const path=req.url==='/play'?item.source:req.url;
    const upstream=await dispatch(new Request(new URL(path,origin),{headers:req.headers.range?{range:req.headers.range}:{}}));
    requests.push({path:req.url.split('?')[0],range:req.headers.range,status:upstream.status,type:upstream.headers.get('content-type')});
    const headers=Object.fromEntries(upstream.headers);
    delete headers['set-cookie'];delete headers['content-encoding'];delete headers['transfer-encoding'];
    res.writeHead(upstream.status,headers);
    if(!upstream.body){res.end();return}
    const stream=Readable.fromWeb(upstream.body);stream.on('error',()=>res.destroy());
    res.on('close',()=>stream.destroy());stream.pipe(res);
  }catch{if(!res.headersSent)res.writeHead(502);res.end()}
});
server.on('connection',s=>{connections.add(s);s.on('close',()=>connections.delete(s))});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let seconds=0,exitCode=-1,timeout;
try{
  // Reproduce Safari's sniff, not only FFmpeg's open-ended request.
  const start='http://127.0.0.1:'+server.address().port+'/play';
  const sniff=await fetch(start,{headers:{range:'bytes=0-1'},signal:AbortSignal.timeout(20000)});
  const sniffBytes=new Uint8Array(await sniff.arrayBuffer());
  if(sniff.status!==206||sniffBytes.length!==2)throw Error('Safari sniff failed');
  if(item.kind==='hls'){
    if(new TextDecoder().decode(sniffBytes)!=='#E')throw Error('Invalid HLS prefix');
    const length=Number(sniff.headers.get('content-range')?.split('/')[1]);
    const full=await fetch(start,{headers:{range:'bytes=0-'+(length-1)},signal:AbortSignal.timeout(20000)});
    const text=await full.text();
    if(full.status!==206||!text.startsWith('#EXTM3U')||new TextEncoder().encode(text).length!==length)throw Error('Safari playlist failed');
  }
  const child=spawn('ffmpeg',['-nostdin','-hide_banner','-loglevel','error',
    '-protocol_whitelist','http,https,tcp,tls,crypto','-allowed_extensions','ALL',
    '-i','http://127.0.0.1:'+server.address().port+'/play','-t','65',
    '-map','0:a:0','-vn','-progress','pipe:1','-f','null','-'],{stdio:['ignore','pipe','pipe']});
  timeout=setTimeout(()=>child.kill('SIGTERM'),60000);
  child.stdout.on('data',chunk=>{for(const match of chunk.toString().matchAll(/out_time_us=(\d+)/g))seconds=Math.max(seconds,Number(match[1])/1000000)});
  // Decoder error text can embed signed URLs, so deliberately do not print it.
  child.stderr.resume();
  exitCode=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',resolve)});
}finally{
  clearTimeout(timeout);for(const s of connections)s.destroy();await new Promise(resolve=>server.close(resolve));
}
const ok=exitCode===0&&seconds>=64;
console.log(JSON.stringify({production,id,kind:item.kind,audioTrack:item.audioTrack,ok,decodedSeconds:seconds,exitCode,requests}));
if(!ok)process.exitCode=1;
