// Temporary signed URL arrives on hidden stdin only. Never log or persist it.
import {createInterface} from 'node:readline';
const lines=createInterface({input:process.stdin,terminal:false});
console.log('Ready for media probe JSON on hidden stdin.');
let input;for await(const line of lines){input=JSON.parse(line);break}lines.close();process.stdin.pause();
const u=new URL(input.url);
if(u.protocol!=='https:'||!u.hostname.endsWith('.googlevideo.com'))throw Error('Invalid media host');
const target=input.relay?'https://axrtube.axrbarsic.workers.dev/media?u='+encodeURIComponent(u.href):u;
for(const range of ['bytes=0-1','bytes=0-65535','bytes=1048576-1114111','bytes=20000000-20065535','bytes=0-20481661']){
  try{
    const r=await fetch(target,{headers:{range},signal:AbortSignal.timeout(15000)});
    const reader=r.body.getReader();const first=await reader.read();await reader.cancel();
    console.log(JSON.stringify({range,status:r.status,type:r.headers.get('content-type'),contentRange:r.headers.get('content-range'),firstChunk:first.value?.length}));
  }catch{console.log(JSON.stringify({range,error:'network'}))}
}
