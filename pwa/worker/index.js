import {catalogResponse,suggestionResponse} from './catalog.js';
import {youtubeAccountResponse} from './youtube-account.js';
import {transcriptResponse,transcriptLab} from './transcript.js';
import {commentsResponse} from './comments.js';
import {appPage,appCSS,appManifest,appIcon,serviceWorkerSource} from './app-shell.js';
import {videoIdFrom,formatClock,transcriptText,countWords,relativeTime,compactNumber,appMain} from './app-client.js';
import {appIconPNG} from './app-icon.js';
// AxrTube: YouTube transcripts and discussion. No video playback, no ads.
const APP_BUILD='40';
const baseHeaders={'cache-control':'no-store','x-content-type-options':'nosniff','referrer-policy':'no-referrer'};
const json=(body,status=200)=>new Response(JSON.stringify(body),{status,headers:{...baseHeaders,'content-type':'application/json; charset=utf-8'}});
const pageCSP="default-src 'self'; img-src 'self' https://i.ytimg.com https://*.ggpht.com https://*.googleusercontent.com data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; object-src 'none'; form-action 'self' https://accounts.google.com";
export const appScript=[videoIdFrom,formatClock,transcriptText,countWords,relativeTime,compactNumber].map(String).join('\n')+'\n('+appMain.toString()+')();';
const asset=(body,type,cache='public, max-age=31536000, immutable')=>new Response(body,{headers:{...baseHeaders,'content-type':type,'cache-control':cache}});
const pngBytes=()=>Uint8Array.from(atob(appIconPNG),c=>c.charCodeAt(0));
async function egressTrace(){try{const t=await (await fetch('https://www.cloudflare.com/cdn-cgi/trace',{signal:AbortSignal.timeout(3000)})).text();const g=k=>(t.match(new RegExp('^'+k+'=(.*)$','m'))||[])[1]||'';return {egress:g('ip'),egressColo:g('colo')}}catch{return {}}}
export async function videoMeta(id){
  // Public oEmbed: title and channel without the player endpoint or an account.
  const r=await fetch('https://www.youtube.com/oembed?format=json&url='+encodeURIComponent('https://www.youtube.com/watch?v='+id),{redirect:'manual',signal:AbortSignal.timeout(8000)});
  if(!r.ok){await r.body?.cancel();return null}
  const text=await r.text();if(text.length>100000)return null;
  const d=JSON.parse(text);return {id,title:String(d.title||'').slice(0,500),channel:String(d.author_name||'').slice(0,200)};
}
export default { async fetch(request,env={}) {
  const u=new URL(request.url);
  try{
    const account=await youtubeAccountResponse(request,env,catalogResponse,null,commentsResponse);
    if(account)return account;
    if(!['GET','HEAD'].includes(request.method))return new Response('Method not allowed',{status:405,headers:baseHeaders});
    switch(u.pathname){
      case '/':return new Response(request.method==='HEAD'?null:appPage(APP_BUILD),{headers:{...baseHeaders,'content-type':'text/html; charset=utf-8','content-security-policy':pageCSP,'referrer-policy':'same-origin'}});
      case '/app.js':return asset(appScript,'application/javascript; charset=utf-8');
      case '/app.css':return asset(appCSS,'text/css; charset=utf-8');
      case '/manifest.webmanifest':return asset(JSON.stringify(appManifest),'application/manifest+json','no-cache');
      case '/icon.svg':return asset(appIcon,'image/svg+xml','public, max-age=86400');
      case '/icon-180.png':return asset(pngBytes(),'image/png','public, max-age=86400');
      case '/sw.js':return new Response(serviceWorkerSource(APP_BUILD),{headers:{...baseHeaders,'content-type':'application/javascript; charset=utf-8'}});
      case '/share':{const id=videoIdFrom([u.searchParams.get('url'),u.searchParams.get('text'),u.searchParams.get('title')].filter(Boolean).join(' '));return new Response(null,{status:303,headers:{...baseHeaders,location:id?'/#v='+id:'/'}})}
      case '/api/version':return json({version:APP_BUILD});
      case '/api/catalog':{if((u.searchParams.get('feed')||'search')!=='search')return json({error:'Неизвестная лента'},400);const r=await catalogResponse(u);return json(r.body,r.status)}
      case '/api/suggest':return json(await suggestionResponse(u));
      case '/api/video':{const id=u.searchParams.get('id');if(!/^[\w-]{11}$/.test(id||''))return json({error:'Некорректный ролик'},400);const meta=await videoMeta(id).catch(()=>null);return meta?json(meta):json({error:'Нет данных о ролике'},404)}
      case '/api/transcript':return transcriptResponse(u);
      case '/api/transcript-lab':{
        const ids=(u.searchParams.get('ids')||'dQw4w9WgXcQ').split(',').filter(x=>/^[\w-]{11}$/.test(x)).slice(0,5);
        const results=[];for(const id of ids)results.push(await transcriptLab(id));
        const e=await egressTrace();console.log('TRANSCRIPT_LAB '+JSON.stringify({...e,results}));return json({...e,results});
      }
    }
    return json({error:'Не найдено'},404);
  }catch(error){return json({error:'Ошибка сервера'},500)}
} };
