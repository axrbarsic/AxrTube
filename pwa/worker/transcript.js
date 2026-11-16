// Caption text only. No media downloads, account cookies, tokens or ad fallback.
const transcriptHeaders={'content-type':'application/json; charset=utf-8','cache-control':'no-store','x-content-type-options':'nosniff'};
const transcriptFailure=code=>Object.assign(Error(code),{code});
async function captionBody(response,limit=8_000_000){
  if(!response.ok)throw transcriptFailure('TRANSCRIPT_SOURCE_UNAVAILABLE');
  if(Number(response.headers.get('content-length'))>limit){await response.body?.cancel();throw transcriptFailure('TRANSCRIPT_TOO_LARGE')}
  const reader=response.body?.getReader();if(!reader)throw transcriptFailure('TRANSCRIPT_SOURCE_UNAVAILABLE');let size=0;const chunks=[];
  try{for(;;){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>limit)throw transcriptFailure('TRANSCRIPT_TOO_LARGE');chunks.push(value)}}finally{await reader.cancel()}
  const joined=new Uint8Array(size);let at=0;for(const chunk of chunks){joined.set(chunk,at);at+=chunk.length}return new TextDecoder().decode(joined);
}
export function captionText(raw){
  const entities={amp:'&',lt:'<',gt:'>',quot:'"',apos:"'",nbsp:' '};
  return String(raw).replace(/<[^>]*>/g,'').replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi,(whole,value)=>{
    if(value[0]!=='#')return entities[value.toLowerCase()]||whole;
    const code=value[1]?.toLowerCase()==='x'?parseInt(value.slice(2),16):Number(value.slice(1));return code>0&&code<=0x10ffff&&!(code>=0xd800&&code<=0xdfff)?String.fromCodePoint(code):'';
  }).replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g,'').replace(/\s+/g,' ').trim();
}
function captionTime(value){const parts=value.replace(',','.').split(':');if(parts.length<2||parts.length>3)return NaN;return parts.reduce((seconds,part)=>seconds*60+Number(part),0)}
export function parseCaptionVTT(text){
  if(!text.trimStart().startsWith('WEBVTT'))throw transcriptFailure('TRANSCRIPT_INVALID');
  const lines=text.replace(/\r/g,'').split('\n'),parsed=[];let hasInline=false;
  for(let i=0;i<lines.length;i++){
    const times=lines[i].match(/^(\d{1,3}:\d{2}(?::\d{2})?[.,]\d+)\s+-->\s+(\d{1,3}:\d{2}(?::\d{2})?[.,]\d+)/);if(!times)continue;
    const start=captionTime(times[1]),end=captionTime(times[2]),payload=[];
    while(i+1<lines.length&&!lines[i+1].includes('-->')){const next=lines[++i].trim();if(!next){if(payload.length)break;continue}payload.push(next)}
    const inline=payload.some(line=>/<\d{1,3}:\d{2}/.test(line));hasInline||=inline;
    if(Number.isFinite(start)&&Number.isFinite(end)&&start>=0&&end>start)parsed.push({start,end,payload,inline});
  }
  // Match iOS: roll-up service snapshots are not independent spoken content.
  return parsed.filter(c=>!(hasInline&&!c.inline&&c.end-c.start<=0.05)).map(c=>({start:c.start,end:c.end,text:captionText((c.inline?c.payload.slice(-1):c.payload).join(' '))})).filter(c=>c.text).sort((a,b)=>a.start-b.start);
}
function normalizeWord(word){return word.toLowerCase().replace(/^[\p{P}\p{S}]+|[\p{P}\p{S}]+$/gu,'')}
export function transcriptDocument(cues){
  // Same readable-text overlap and 35/75/120-word paragraph policy as iOS.
  const readable=[];let previous=[];
  for(const cue of cues){const words=cue.text.split(/\s+/);let overlap=0;for(let n=Math.min(32,previous.length,words.length);n>0;n--){if(previous.slice(-n).map(normalizeWord).join(' ')===words.slice(0,n).map(normalizeWord).join(' ')){overlap=n;break}}
    const novel=words.slice(overlap).join(' ');if(novel){readable.push({...cue,text:novel});previous=words}}
  const paragraphs=[];let group=[],count=0;
  const flush=()=>{if(group.length)paragraphs.push({start:group[0].start,end:group.at(-1).end,text:group.map(c=>c.text).join(' ')});group=[];count=0};
  for(const cue of readable){const words=cue.text.split(/\s+/).length;if(group.length){const first=group[0],last=group.at(-1),natural=count>=35&&/[.!?;:…]$/.test(last.text)&&cue.start-first.start>=20;
    if(cue.start-last.end>4||Math.floor(first.start/300)!==Math.floor(cue.start/300)||count+words>120||(count>=75&&natural)||(natural&&cue.start-first.start>=45))flush()}
    group.push(cue);count+=words}
  flush();const sections=[];for(const paragraph of paragraphs){const bucket=Math.floor(paragraph.start/300);if(sections.at(-1)?.bucket!==bucket)sections.push({bucket,start:paragraph.start,paragraphs:[]});sections.at(-1).paragraphs.push(paragraph)}return sections;
}
export function safeCaptionURL(raw,id){const u=new URL(raw);if(u.protocol!=='https:'||!['www.youtube.com','youtube.com','m.youtube.com','video.google.com'].includes(u.hostname)||u.port||u.username||u.password||!['/api/timedtext','/timedtext'].includes(u.pathname)||u.searchParams.get('v')!==id)throw transcriptFailure('TRANSCRIPT_SOURCE_UNAVAILABLE');u.searchParams.set('fmt','vtt');return u}
const captionClients=[
  {client:{clientName:'IOS',clientVersion:'21.02.3',deviceMake:'Apple',deviceModel:'iPhone16,2',osName:'iPhone',osVersion:'18.3.2'},name:'5',ua:'com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)'},
  {client:{clientName:'ANDROID',clientVersion:'20.10.38',androidSdkVersion:30,osName:'Android',osVersion:'11'},name:'3',ua:'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip'},
  {client:{clientName:'WEB',clientVersion:'2.20260206.01.00'},name:'1',ua:'Mozilla/5.0'}];
async function captionClientTracks(id,c,signal){
  const response=await fetch('https://www.youtube.com/youtubei/v1/player?prettyPrint=false',{method:'POST',redirect:'manual',signal,headers:{'content-type':'application/json','user-agent':c.ua,'x-youtube-client-name':c.name,'x-youtube-client-version':c.client.clientVersion,origin:'https://www.youtube.com'},body:JSON.stringify({videoId:id,context:{client:{...c.client,hl:'en',gl:'US'}},contentCheckOk:true,racyCheckOk:true})});
  const data=JSON.parse(await captionBody(response,4_000_000));if(data.videoDetails?.videoId!==id)throw transcriptFailure('TRANSCRIPT_SOURCE_UNAVAILABLE');
  const tracks=(data.captions?.playerCaptionsTracklistRenderer?.captionTracks||[]).filter(t=>typeof t.languageCode==='string'&&/^[a-zA-Z0-9-]{2,35}$/.test(t.languageCode)&&typeof t.baseUrl==='string').filter(t=>{try{safeCaptionURL(t.baseUrl,id);return true}catch{return false}});
  return {client:c.client.clientName,tracks,title:String(data.videoDetails.title||id),channel:String(data.videoDetails.author||''),duration:Number(data.videoDetails.lengthSeconds)||0};
}
// App clients first: their caption URLs do not need a browser proof (exp=xpe).
async function captionMetadata(id,report=null){
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),12000);
  try{
    const settled=await Promise.allSettled(captionClients.map(c=>captionClientTracks(id,c,controller.signal)));
    if(report)settled.forEach((r,i)=>report.push({client:captionClients[i].client.clientName,ok:r.status==='fulfilled',tracks:r.value?.tracks.length??0,proof:r.value?.tracks.some(t=>t.baseUrl.includes('exp=xpe'))??false,code:r.reason?.code||(r.reason?String(r.reason.name||'ERROR'):undefined)}));
    const ok=settled.filter(r=>r.status==='fulfilled').map(r=>r.value);
    const best=ok.find(d=>d.tracks.length&&!d.tracks.some(t=>t.baseUrl.includes('exp=xpe')))||ok.find(d=>d.tracks.length);
    if(best)return best;
    throw transcriptFailure(ok.length?'TRANSCRIPT_UNAVAILABLE':'TRANSCRIPT_SOURCE_UNAVAILABLE');
  }finally{clearTimeout(timer);controller.abort()}
}
const trackName=t=>t.name?.simpleText||t.name?.runs?.map(r=>r.text||'').join('')||t.languageCode;
// Second source: the watch page "Show transcript" panel (next -> get_transcript).
// Independent from the player endpoint that YouTube bot-checks on datacenter IPs.
const panelVersion='2.20260311.01.00';
function panelContext(language){return {client:{clientName:'WEB',clientVersion:panelVersion,hl:/^[a-z]{2}/.test(language||'')?language.slice(0,2):'ru',gl:'US'}}}
async function panelCall(endpoint,body,signal){
  const r=await fetch('https://www.youtube.com/youtubei/v1/'+endpoint+'?prettyPrint=false',{method:'POST',redirect:'manual',signal,
    headers:{'content-type':'application/json','user-agent':'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',origin:'https://www.youtube.com','x-youtube-client-name':'1','x-youtube-client-version':panelVersion},
    body:JSON.stringify(body)});
  if(!r.ok){await r.body?.cancel();throw Object.assign(transcriptFailure('PANEL_HTTP_'+r.status),{step:endpoint})}
  return JSON.parse(await captionBody(r,8_000_000));
}
function findKey(node,key,depth=0){
  if(!node||typeof node!=='object'||depth>40)return undefined;
  if(Object.hasOwn(node,key))return node[key];
  for(const value of Object.values(node)){const found=findKey(value,key,depth+1);if(found!==undefined)return found}
  return undefined;
}
function findAll(node,key,out=[],depth=0){
  if(!node||typeof node!=='object'||depth>40||out.length>20000)return out;
  if(Object.hasOwn(node,key))out.push(node[key]);
  for(const value of Object.values(node))findAll(value,key,out,depth+1);
  return out;
}
const runsText=v=>typeof v==='string'?v:v?.simpleText||v?.runs?.map(r=>r.text||'').join('')||'';
export function panelSegments(data){
  return findAll(data,'transcriptSegmentRenderer').map(s=>({start:Number(s.startMs)/1000,end:Number(s.endMs)/1000,text:captionText(runsText(s.snippet))}))
    .filter(c=>Number.isFinite(c.start)&&Number.isFinite(c.end)&&c.end>=c.start&&c.text).sort((a,b)=>a.start-b.start);
}
export function panelLanguages(data){
  const items=findKey(findKey(data,'transcriptFooterRenderer'),'subMenuItems')||[];
  return items.map(i=>({name:runsText(i.title),selected:i.selected===true,params:i.continuation?.reloadContinuationData?.continuation||''})).filter(i=>i.name&&i.params);
}
export async function panelTranscript(id,language=''){
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),20000);
  try{
    const watch=await panelCall('next',{context:panelContext(language),videoId:id},controller.signal);
    const params=findKey(watch,'getTranscriptEndpoint')?.params;
    const primary=findKey(watch,'videoPrimaryInfoRenderer'),owner=findKey(watch,'videoOwnerRenderer');
    const meta={title:runsText(primary?.title)||id,channel:runsText(owner?.title)};
    if(typeof params!=='string'||!params)throw transcriptFailure('TRANSCRIPT_UNAVAILABLE');
    let data=await panelCall('get_transcript',{context:panelContext(language),params},controller.signal);
    let languages=panelLanguages(data);
    // Prefer the requested language, then Russian, then the panel default.
    const wanted=languages.find(l=>!l.selected&&language&&l.name.toLowerCase().startsWith(language.toLowerCase()))||
      (!language&&!languages.find(l=>l.selected&&/рус|russian/i.test(l.name))?languages.find(l=>/рус|russian/i.test(l.name)):null);
    if(wanted){try{data=await panelCall('get_transcript',{context:panelContext(language),params:wanted.params},controller.signal);languages=panelLanguages(data)}catch{}}
    const cues=panelSegments(data);if(!cues.length)throw transcriptFailure('TRANSCRIPT_UNAVAILABLE');
    const selected=languages.find(l=>l.selected);
    return {...meta,cues,languageName:selected?.name||'',autoGenerated:/авто|auto/i.test(selected?.name||''),languages:languages.map(l=>l.name)};
  }finally{clearTimeout(timer);controller.abort()}
}
// Diagnostics: which transcript source works from this host right now.
export async function transcriptLab(id){
  const out={id,clients:[]};
  try{await captionMetadata(id,out.clients)}catch{}
  const t0=Date.now();const r=await transcriptResponse(new URL('https://lab.invalid/api/transcript?id='+id));const d=await r.json();
  out.full={status:r.status,source:d.source||null,code:d.code||null,language:d.languageName||null,paragraphs:d.sections?.reduce((n,s)=>n+s.paragraphs.length,0)||0,ms:Date.now()-t0};
  const t1=Date.now();try{const p=await panelTranscript(id);out.panel={ok:true,segments:p.cues.length,ms:Date.now()-t1}}catch(e){out.panel={ok:false,code:e.code||String(e?.name||'ERROR'),step:e.step||null,ms:Date.now()-t1}}
  return out;
}
export async function transcriptResponse(u){
  const id=u.searchParams.get('id'),language=u.searchParams.get('lang')||'';
  if(!/^[\w-]{11}$/.test(id||'')||(language&&!/^[a-zA-Z0-9-]{2,35}$/.test(language)))return new Response(JSON.stringify({code:'TRANSCRIPT_INVALID'}),{status:400,headers:transcriptHeaders});
  try{
    const data=await captionMetadata(id);const rank=t=>{const base=t.languageCode.split('-')[0];return (t.languageCode===language?0:base==='ru'?10:base==='en'?20:30)+(t.kind==='asr'?1:0)};
    const tracks=[...data.tracks].sort((a,b)=>rank(a)-rank(b));let error;
    for(const track of tracks){try{
      const r=await fetch(safeCaptionURL(track.baseUrl,id),{redirect:'manual',headers:{accept:'text/vtt, */*'},signal:AbortSignal.timeout(12000)});const cues=parseCaptionVTT(await captionBody(r));const sections=transcriptDocument(cues);if(!sections.length)throw transcriptFailure('TRANSCRIPT_SOURCE_UNAVAILABLE');
      return new Response(JSON.stringify({id,title:data.title,channel:data.channel,duration:Math.max(data.duration,sections.at(-1).paragraphs.at(-1).end),generatedAt:new Date().toISOString(),language:track.languageCode,languageName:trackName(track),autoGenerated:track.kind==='asr',languages:data.tracks.map(t=>({code:t.languageCode,name:trackName(t),auto:t.kind==='asr'})),sections,source:'youtube-captions',complete:true}),{headers:transcriptHeaders});
    }catch(e){error=e;if(e.code==='TRANSCRIPT_TOO_LARGE')break}if(error&&tracks.indexOf(track)>=2)break}
    throw error||transcriptFailure('TRANSCRIPT_UNAVAILABLE');
  }catch(error){
    if(error.code!=='TRANSCRIPT_TOO_LARGE')try{
      const p=await panelTranscript(id,language);const sections=transcriptDocument(p.cues);
      if(sections.length)return new Response(JSON.stringify({id,title:p.title,channel:p.channel,duration:sections.at(-1).paragraphs.at(-1).end,generatedAt:new Date().toISOString(),language:language||'',languageName:p.languageName,autoGenerated:p.autoGenerated,sections,source:'youtube-transcript-panel',complete:true}),{headers:transcriptHeaders});
    }catch{}
    const code=['TRANSCRIPT_UNAVAILABLE','TRANSCRIPT_TOO_LARGE','TRANSCRIPT_INVALID'].includes(error.code)?error.code:'TRANSCRIPT_SOURCE_UNAVAILABLE';return new Response(JSON.stringify({code}),{status:code==='TRANSCRIPT_UNAVAILABLE'?404:code==='TRANSCRIPT_TOO_LARGE'?413:502,headers:transcriptHeaders})}
}
