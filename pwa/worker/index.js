import {catalogResponse,suggestionResponse,sponsorResponse,parseCatalog} from './catalog.js';
import {appPage,appStyle,preferenceStyle} from './app-shell.js';
import {appClient} from './app-client.js';
import {createBackgroundPlayback} from './background-playback.js';
import {createUpdateClient,serviceWorkerSource} from './app-updates.js';
import {youtubeAccountResponse} from './youtube-account.js';
import {i18nClient} from './i18n.js';
import {transcriptResponse} from './transcript.js';
import {transcriptClient,transcriptStyle} from './transcript-ui.js';
import {personalHomeResponse} from './personal-home.js';
import {createMediaDiagnostics,systemPlayerPage,identityTestManifest} from './media-diagnostics.js';
const APP_BUILD='38';
// AxrTube PWA. No advertising iframe, cookies, account or ad-player fallback.
const headers = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer' };
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...headers, 'content-type': 'application/json' } });
export function mediaURL(raw) {
  const u = new URL(raw);
  if (u.protocol !== 'https:' || u.username || u.password || u.port ||
      !(u.hostname === 'googlevideo.com' || u.hostname.endsWith('.googlevideo.com'))) throw new Error('Media host rejected');
  return u;
}
const relayURL = raw => '/media?u=' + encodeURIComponent(mediaURL(raw).href);
export function hlsAttributes(line) {
  const attrs={};
  for(const m of line.slice(line.indexOf(':')+1).matchAll(/([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))(?:,|$)/g))attrs[m[1]]=m[2]??m[3];
  return attrs;
}
export function selectAudioRendition(text,base) {
  if(text.length>1000000||!text.startsWith('#EXTM3U'))throw failure('INVALID_HLS');
  const lines=text.split(/\r?\n/);
  const variants=lines.filter(l=>l.startsWith('#EXT-X-STREAM-INF:')).map(hlsAttributes);
  const tracks=lines.filter(l=>l.startsWith('#EXT-X-MEDIA:')).map(hlsAttributes)
    .filter(a=>a.TYPE==='AUDIO'&&a.URI).map(a=>{
      const codecs=variants.filter(v=>v.AUDIO===a['GROUP-ID']).flatMap(v=>(v.CODECS||'').split(','));
      const codec=codecs.find(c=>c==='mp4a.40.2')||codecs.find(c=>/^mp4a\.40\.(5|29)$/.test(c));
      const name=a.NAME||'';
      const priority=/\boriginal\b/i.test(name)?0:a.DEFAULT==='YES'?1:!/dubbed/i.test(name)?2:3;
      return {raw:mediaURL(new URL(a.URI,base).href).href,language:a.LANGUAGE||'',name,codec,group:a['GROUP-ID']||'',priority};
    }).filter(t=>t.codec);
  tracks.sort((a,b)=>a.priority-b.priority||Number(b.codec==='mp4a.40.2')-Number(a.codec==='mp4a.40.2'));
  if(!tracks.length)throw failure('NO_SUPPORTED_AUDIO_RENDITION');
  return tracks[0];
}
export function audioMaster(raw,codec) {
  if(!/^mp4a\.40\.(2|5|29)$/.test(codec||''))throw failure('INVALID_AUDIO_CODEC');
  return '#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-STREAM-INF:BANDWIDTH=256000,CODECS="'+codec+'"\n'+mediaURL(raw).href+'\n';
}
export function rewriteManifest(text, base) {
  return text.split('\n').map(line => {
    if (!line.trim()) return line;
    if (line.startsWith('#')) return line.replace(/URI="([^"]+)"/g, (_, uri) => 'URI="' + relayURL(new URL(uri, base).href) + '"');
    return relayURL(new URL(line.trim(), base).href);
  }).join('\n');
}
async function upstream(raw, range) {
  let u = mediaURL(raw);
  for (let hop = 0; hop < 4; hop++) {
    const r = await fetch(u, { headers: range ? { Range: range } : {}, redirect: 'manual', signal: AbortSignal.timeout(20000) });
    if ([301,302,303,307,308].includes(r.status)) { u = mediaURL(new URL(r.headers.get('location'), u).href); continue; }
    return { response: r, url: u.href };
  }
  throw new Error('Redirect limit');
}
function isManifestURL(raw){const p=mediaURL(raw).pathname;return p.includes('/manifest/')||p.endsWith('.m3u8')}
export function manifestResponse(text,base,range,head=false){
  if(text.length>1000000||!text.startsWith('#EXTM3U'))throw failure('INVALID_HLS');
  const bytes=new TextEncoder().encode(rewriteManifest(text,base));
  const h={...headers,'content-type':'application/vnd.apple.mpegurl','accept-ranges':'bytes'};
  let start=0,end=bytes.length-1;
  if(range){
    const m=/^bytes=(\d*)-(\d*)$/.exec(range);
    if(!m||(!m[1]&&!m[2]))return new Response(null,{status:416,headers:{...h,'content-range':'bytes */'+bytes.length}});
    if(m[1]){start=Number(m[1]);if(m[2])end=Math.min(Number(m[2]),end)}
    else start=Math.max(0,bytes.length-Number(m[2]));
    if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start>end||start>=bytes.length)
      return new Response(null,{status:416,headers:{...h,'content-range':'bytes */'+bytes.length}});
    h['content-range']='bytes '+start+'-'+end+'/'+bytes.length;
  }
  h['content-length']=String(end-start+1);
  return new Response(head?null:bytes.slice(start,end+1),{status:range?206:200,headers:h});
}
const clients = [
  { clientName: 'IOS', clientVersion: '21.02.3', deviceMake: 'Apple', deviceModel: 'iPhone16,2', osName: 'iPhone', osVersion: '18.3.2', hl: 'en', gl: 'US' },
  { clientName: 'VISIONOS', clientVersion: '1.02', deviceMake: 'Apple', deviceModel: 'RealityDevice17,1', osName: 'visionOS', osVersion: '26.5.23O471', hl: 'en', gl: 'US' }
];
const fallbackClient={ clientName: 'ANDROID_VR', clientVersion: '1.65.10', deviceMake: 'Oculus', deviceModel: 'Quest 3', androidSdkVersion: 32, osName: 'Android', osVersion: '12L', hl: 'en', gl: 'US',
  userAgent: 'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip', headerName: '28' };
export function directVideoFormat(data) {
  return (data.streamingData?.formats || [])
    .filter(f => f.url && f.mimeType?.startsWith('video/mp4') && f.audioQuality && !f.drmFamilies?.length)
    .sort((a,b) => (b.height || 0) - (a.height || 0))[0];
}
export function directAudioFormat(data) {
  return (data.streamingData?.adaptiveFormats || [])
    .filter(f => f.url && f.mimeType?.startsWith('audio/mp4') && !f.drmFamilies?.length)
    .sort((a,b) => (b.bitrate || 0) - (a.bitrate || 0))[0];
}
function failure(code) { return Object.assign(new Error(code), { code }); }
export async function hasMP4Header(body) {
  if (!body) return false;
  const reader=body.getReader();const header=new Uint8Array(8);let offset=0;
  try {
    while(offset<8) {
      const {value,done}=await reader.read();
      if(done)break;
      const part=value.subarray(0,8-offset);header.set(part,offset);offset+=part.length;
    }
    return offset===8 && String.fromCharCode(...header.slice(4,8))==='ftyp';
  } finally { await reader.cancel(); }
}
function diagnostics(error) {
  const errors=error instanceof AggregateError?error.errors:[error];
  return errors.map((e,i)=>({client:e.client||clients[i]?.clientName||fallbackClient.clientName,code:typeof e.code==='string'&&/^[A-Z_0-9]+$/.test(e.code)?e.code:'NETWORK_OR_TIMEOUT'}));
}
async function playerResponse(id, client, i, signal) {
  const userAgent=client.userAgent||(i===0?'com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)':'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15');
  const {userAgent:_ua,headerName,...clientContext}=client;
  let visitor;
  try{
    for(let attempt=0;attempt<2;attempt++){
      const r = await fetch('https://www.youtube.com/youtubei/v1/player?prettyPrint=false', {
        method:'POST',signal,
        headers:{'content-type':'application/json','user-agent':userAgent,origin:'https://www.youtube.com',
          'x-youtube-client-name':headerName||(i===0?'5':'101'),'x-youtube-client-version':client.clientVersion,
          ...(visitor?{'x-goog-visitor-id':visitor}:{})},
        body:JSON.stringify({context:{client:{...clientContext,userAgent,...(visitor?{visitorData:visitor}:{})}},
          videoId:id,contentCheckOk:true,racyCheckOk:true,
          playbackContext:{contentPlaybackContext:{html5Preference:'HTML5_PREF_WANTS'}}})
      });
      if (!r.ok) throw failure('PLAYER_HTTP_'+r.status);
      const data = await r.json();
      const seed=data.responseContext?.visitorData;
      // Match the native resolver's cold-session handshake, not endless retries.
      if(attempt===0&&typeof seed==='string'&&seed.length>0&&seed.length<4096&&
          (data.playabilityStatus?.status!=='OK'||!data.streamingData?.hlsManifestUrl)){
        visitor=seed;continue;
      }
      if (data.playabilityStatus?.status !== 'OK') {
        const status=data.playabilityStatus?.status;
        throw failure(['LOGIN_REQUIRED','UNPLAYABLE','ERROR','LIVE_STREAM_OFFLINE'].includes(status)?'PLAYER_'+status:'PLAYER_UNAVAILABLE');
      }
      if (data.videoDetails?.videoId !== id) throw failure('CONTENT_ID_MISMATCH');
      return data;
    }
  }catch(e){e.client=client.clientName;throw e}
}
async function resolvePrimary(id, mode, poToken) {
  const controllers=clients.map(()=>new AbortController());
  const timer=setTimeout(()=>controllers.forEach(c=>c.abort()),15000);
  const responses=clients.map((client,i)=>playerResponse(id,client,i,controllers[i].signal));
  try{
    // A fast iOS MP4 header must not win over a fully usable HLS response.
    try{
      return await Promise.any(responses.map(async(p,i)=>{
        const data=await p;const hls=data.streamingData?.hlsManifestUrl;
        if(!hls)throw Object.assign(failure('NO_HLS'),{client:clients[i].clientName});
        return {id,title:data.videoDetails.title,kind:'hls',source:relayURL(hls),raw:hls,client:clients[i].clientName};
      }));
    }catch(error){if(mode!=='audio')throw error}
    return await Promise.any(responses.map(async(p,i)=>{
      try{
        const data=await p;const audio=directAudioFormat(data);
        if(!audio)throw failure('NO_COMPATIBLE_FORMAT');
        const fileURL=mediaURL(audio.url);
        if(poToken)fileURL.searchParams.set('pot',poToken);
        // iOS direct media can expose a free header but require proof for playback.
        if(clients[i].clientName==='IOS'&&fileURL.searchParams.get('rqh')==='1'&&!fileURL.searchParams.has('pot'))
          throw failure('PO_TOKEN_REQUIRED');
        // Exercise the actual open-ended playback request, not an exempt 16-byte peek.
        const {response}=await upstream(fileURL.href,'bytes=0-');
        if(!response.ok||!response.headers.get('content-type')?.startsWith('audio/mp4')){
          await response.body?.cancel();throw failure(!response.ok?'AUDIO_HTTP_'+response.status:'AUDIO_WRONG_MIME');
        }
        if(!await hasMP4Header(response.body))throw failure('AUDIO_BAD_HEADER');
        return {id,title:data.videoDetails.title,kind:'file',source:relayURL(fileURL.href),client:clients[i].clientName};
      }catch(e){e.client=clients[i].clientName;throw e}
    }));
  } finally { clearTimeout(timer); controllers.forEach(c => c.abort()); }
}
async function resolveFallback(id, mode) {
  const controller=new AbortController();const timer=setTimeout(()=>controller.abort(),15000);
  try{
    const data=await playerResponse(id,fallbackClient,2,controller.signal);
    const format=mode==='audio'?directAudioFormat(data):directVideoFormat(data);
    if(!format)throw failure('NO_COMPATIBLE_FORMAT');
    const fileURL=mediaURL(format.url);
    const {response}=await upstream(fileURL.href,'bytes=0-');
    const type=response.headers.get('content-type')||'';
    if(!response.ok||!type.startsWith(mode==='audio'?'audio/mp4':'video/mp4')){
      await response.body?.cancel();const kind=mode==='audio'?'AUDIO':'VIDEO';throw failure(!response.ok?kind+'_HTTP_'+response.status:kind+'_WRONG_MIME');
    }
    if(!await hasMP4Header(response.body))throw failure(mode==='audio'?'AUDIO_BAD_HEADER':'VIDEO_BAD_HEADER');
    return {id,title:data.videoDetails.title,kind:'file',source:relayURL(fileURL.href),client:fallbackClient.clientName};
  }catch(e){e.client=fallbackClient.clientName;throw e}
  finally{clearTimeout(timer);controller.abort()}
}
// Temporary bridge: the previous public deployment as a read-only stream source
// when YouTube rejects this host. Fixed origin and paths only; no credentials.
const legacyOrigin='https://axrtube-pwa-playback-lab.axrbarsic.chatgpt.site';
async function resolveLegacy(id, mode) {
  try{
    const r=await fetch(legacyOrigin+'/api/resolve?id='+encodeURIComponent(id)+'&mode='+(mode==='audio'?'audio':'video'),{redirect:'manual',signal:AbortSignal.timeout(20000)});
    if(!r.ok){
      const body=(await r.text()).slice(0,2000);let inner='';
      try{inner=(JSON.parse(body).diagnostics||[]).map(d=>String(d.client||'').replace(/[^A-Z_0-9]/g,'')+':'+String(d.code||'').replace(/[^A-Z_0-9]/g,'')).join(',')}catch{inner='NON_JSON'}
      console.log('LEGACY_FAIL '+JSON.stringify({id,status:r.status,server:r.headers.get('server'),inner}));
      throw failure('LEGACY_HTTP_'+r.status);
    }
    const data=await r.json();
    if(!/^\/(media|audio-master)\?/.test(data.source||'')||!['hls','file'].includes(data.kind))throw failure('LEGACY_INVALID');
    return {id,title:String(data.title||''),kind:data.kind,source:'/legacy'+data.source,audioTrack:data.audioTrack,legacy:true,client:'LEGACY'};
  }catch(e){e.client='LEGACY';if(!/^[A-Z_0-9]+$/.test(e.code||''))e.code='LEGACY_NETWORK';throw e}
}
async function legacyMediaResponse(u, request) {
  const path=u.pathname.slice('/legacy'.length);
  const r=await fetch(legacyOrigin+path+u.search,{method:request.method==='HEAD'?'HEAD':'GET',redirect:'manual',signal:AbortSignal.timeout(30000),
    headers:request.headers.has('range')?{Range:request.headers.get('range')}:{}});
  const type=r.headers.get('content-type')||'';
  const h=new Headers(headers);
  if(type.includes('mpegurl')&&request.method!=='HEAD'){
    const text=(await r.text()).replace(/(^|URI=")\/media\?/gm,'$1/legacy/media?');
    h.set('content-type',type);return new Response(text,{status:r.status,headers:h});
  }
  for(const key of ['content-type','content-length','content-range','accept-ranges'])if(r.headers.has(key))h.set(key,r.headers.get(key));
  return new Response(request.method==='HEAD'?null:r.body,{status:r.status,headers:h});
}
async function resolveVideo(id, mode, poToken, legacyBridge=false) {
  try{return await resolvePrimary(id,mode,poToken)}
  catch(primary){
    try{return await resolveFallback(id,mode)}
    catch(fallback){
      const errors=primary instanceof AggregateError?primary.errors:[primary];
      if(!legacyBridge)throw new AggregateError([...errors,fallback],'All resolvers failed');
      try{return await resolveLegacy(id,mode)}
      catch(legacy){throw new AggregateError([...errors,fallback,legacy],'All resolvers failed')}
    }
  }
}
const manifest = { name: 'AxrTube', short_name: 'AxrTube', id: '/', start_url: '/', scope: '/', display: 'standalone', background_color: '#0f0f0f', theme_color: '#0f0f0f', icons: [{ src: '/icon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any maskable' }] };
const icon = '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512"><rect width="512" height="512" rx="112" fill="#101012"/><rect x="76" y="132" width="360" height="248" rx="68" fill="#ff453a"/><path d="M220 194v124l108-62z" fill="white"/></svg>';
const sw = serviceWorkerSource(APP_BUILD);
const bootScript='window.axrUpdates=('+createUpdateClient.toString()+')({window,document,navigator,fetch,build:'+JSON.stringify(APP_BUILD)+'});window.axrUpdates.start();';
const mobilePage=appPage.replace('href="/app.css"','href="/app.css?release='+APP_BUILD+'"')
  .replace(/<script src="https:\/\/cdn.jsdelivr.net\/npm\/hls.js[^<]+<\/script><script src="\/engine.js"><\/script><script src="\/app.js"><\/script>/,
    '<script src="/boot.js?release='+APP_BUILD+'"></script>');
const page = `<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="theme-color" content="#101012"><meta name="apple-mobile-web-app-capable" content="yes"><link rel="manifest" href="/manifest.webmanifest"><link rel="icon" href="/icon.svg"><title>AxrTube PWA Lab</title>
<style>*{box-sizing:border-box}body{margin:0;background:#101012;color:#fafafa;font:16px system-ui,-apple-system,sans-serif}main{max-width:660px;margin:auto;padding:24px 18px calc(30px + env(safe-area-inset-bottom))}header{display:flex;justify-content:space-between;align-items:center;margin-bottom:28px}header strong{font-size:23px;letter-spacing:-1px}header span{color:#ff7068;font:12px ui-monospace,monospace;border:1px solid #56332f;padding:6px 9px;border-radius:20px}h1{font-size:29px;line-height:1.15;letter-spacing:-.8px;margin:14px 0}p{color:#afafb8;line-height:1.5}video{width:100%;aspect-ratio:16/9;background:#050505;border-radius:14px}audio{width:100%;margin:15px 0}section{background:#1c1c20;padding:18px;margin:16px 0;border:1px solid #303035;border-radius:16px}h2{font-size:16px;margin:0 0 12px}input,button,select{font:inherit;border-radius:10px;min-height:46px}input,select{width:100%;padding:12px;background:#101012;color:white;border:1px solid #494950}button{border:0;background:#f2f2f5;color:#16161a;padding:10px 15px;cursor:pointer;font-weight:600}button:disabled{opacity:.5;cursor:wait}.row{display:flex;flex-wrap:wrap;gap:8px;margin:12px 0}.primary{background:#ff554b;color:#fff}.muted{background:#303036;color:#eee}label{display:block;color:#c6c6d0;font-size:14px;margin:12px 0 6px}.badge{font-size:12px;color:#86d5a5}#status{min-height:46px;margin:12px 0;color:#f0cd87;white-space:pre-wrap}details{margin:15px 0}summary{cursor:pointer;color:#c6c6d0}pre{font:12px ui-monospace,monospace;white-space:pre-wrap;max-height:180px;overflow:auto;color:#a9b9b2}ol{padding-left:22px;color:#c6c6d0;line-height:1.7}small{color:#9999a6}a{color:#9ccaff}#offlineAudio[hidden],video[hidden]{display:none}</style></head>
<body><main><header><strong>AxrTube<span style="border:0;padding-left:6px">LAB</span></strong><span>PWA / EXPERIMENT</span></header><div class="badge">Без официального YouTube iframe</div><h1>Сначала проверим,<br>слышно ли в фоне.</h1><p>Технический стенд, не готовая копия приложения. Фон, очередь и офлайн требуют проверки на твоём телефоне.</p>
<video id="video" controls playsinline preload="metadata"></video><audio id="offlineAudio" controls hidden></audio><div id="status" role="status" aria-live="polite">Выбери источник и нажми «Запустить».</div><div class="row"><button id="play" class="primary">Запустить</button><button id="pause" class="muted">Пауза</button></div>
<section><h2>01 / Источник</h2><label for="source">Сценарий</label><select id="source"><option value="control">Контрольный MP3, без YouTube</option><option value="youtube">YouTube, собственный HLS-плеер</option></select><label for="link">Ссылка YouTube или ID ролика</label><input id="link" type="text" placeholder="https://www.youtube.com/watch?v=..." autocomplete="off"><label for="mode">Воспроизведение</label><select id="mode"><option value="video">Видео</option><option value="audio">Только аудио HLS</option></select><p><small>Контрольный MP3 отделяет ограничения браузера от ошибок YouTube. Для YouTube нет рекламного fallback: ошибка останется ошибкой, а не откроет iframe.</small></p></section>
<section><h2>02 / Локальная копия</h2><p>Проверка идеи Brave на доступных веб-API. Сначала только небольшой контрольный MP3, не скачивание YouTube.</p><div class="row"><button id="save" class="muted">Сохранить контрольный MP3</button><button id="offline" class="muted">Играть локальную копию</button></div><small>Скачивание работает при открытом стенде. Хранилище браузера может быть очищено ОС.</small></section>
<section><h2>03 / Проверка на телефоне</h2><ol><li>Запусти контрольный MP3 и заблокируй экран на минуту.</li><li>Проверь звук, Play/Pause и перемотку на Lock Screen.</li><li>Повтори с YouTube: видео, затем «Только аудио».</li><li>Сохрани контрольный MP3, включи авиарежим и открой локальную копию.</li><li>Повтори после установки PWA на домашний экран.</li></ol><button id="install" class="muted" hidden>Установить PWA</button><p id="installHelp">На iPhone: Safari → Поделиться → На экран «Домой» → Открывать как веб-приложение.</p><button id="report" class="muted">Скачать отчёт проверки</button></section><details><summary>События плеера</summary><pre id="events"></pre></details><small>Нет авторизации YouTube, полной медиатеки, очереди и гарантии фонового режима. <a href="https://community.brave.app/t/notice-playlist-offline-video-on-ios-disallowed-by-apple/654965" rel="noreferrer">Ограничения Brave iOS</a></small></main>
<script src="/hls.js"></script><script>
const $=id=>document.getElementById(id),v=$('video'),a=$('offlineAudio');let active=v,hls,hlsStartCancel,blobURL,installPrompt,busy=false,startupPauseRequested=false,playGeneration=0,playTitle='';const events=[];const control='/control.mp3';
if($('mode').options)$('mode').options[1].text='Только звук';
if($('source').options)$('source').options[1].text='YouTube, собственный плеер';
if(window.location?.href){
  const preset=new URL(window.location.href);const id=preset.searchParams.get('video');
  if(/^[a-zA-Z0-9_-]{11}$/.test(id||'')){
    $('source').value='youtube';$('link').value=id;
    $('mode').value=preset.searchParams.get('mode')==='video'?'video':'audio';
  }
}
function tr(value){return window.axrI18n?.t(value)||value}
const build='youtube-path-v38';let playbackKey=null,context={source:'none',mode:'none'},lastProgress=-1;
function rememberResolver(r,data){
  if(r.ok){delete context.failure;return}
  context.failure={stage:'resolve',httpStatus:r.status,codes:(data.diagnostics||[]).slice(0,4).map(d=>d.code).filter(c=>typeof c==='string'&&/^[A-Z_0-9]{1,80}$/.test(c))};
}
function temporaryResolverFailure(r,data){
  const codes=(data.diagnostics||[]).map(d=>d.code);
  // One provider can omit HLS while the other rejects access. This mixed
  // result deserves the same single bounded retry, not an immediate failure.
  // NO_HLS alone is not an access denial and must not create a retry loop.
  return r.status===502&&codes.some(c=>['PLAYER_LOGIN_REQUIRED','PLAYER_HTTP_403'].includes(c))&&codes.every(c=>['PLAYER_LOGIN_REQUIRED','PLAYER_HTTP_403','NO_HLS'].includes(c));
}
function resolverMessage(r,data){
  if(temporaryResolverFailure(r,data))return tr('YouTube временно отклонил запрос нашего сервера. Это не запрос входа в ваш аккаунт. Попробуйте позже или откройте другой ролик.');
  return tr('Не удалось получить поток этого ролика. Он может быть ограничен или временно недоступен.');
}
function phoneProof(id){return new Promise((resolve,reject)=>{
  const frame=document.createElement('iframe');frame.sandbox='allow-scripts';frame.hidden=true;
  const nonce=crypto.randomUUID();let timeout;
  function done(error,token){clearTimeout(timeout);window.removeEventListener('message',receive);frame.remove();error?reject(Error(error)):resolve(token)}
  function receive(e){if(e.source!==frame.contentWindow||e.data?.nonce!==nonce)return;
    if(e.data.token&&/^[a-zA-Z0-9_=-]{16,8192}$/.test(e.data.token))done(null,e.data.token);
    else if(e.data.error)done(tr('Проверка Google в браузере не пройдена: ')+e.data.error);
  }
  window.addEventListener('message',receive);frame.src='/phone-proof#'+encodeURIComponent(JSON.stringify({id,nonce}));
  timeout=setTimeout(()=>done(tr('Истекло время проверки Google')),35000);document.body.appendChild(frame);
})}
const selectionKey=()=>JSON.stringify([$('source').value,$('mode').value,$('link').value.trim()]);
const diagnostics=(${createMediaDiagnostics.toString()})({window,document,navigator,getMedia:()=>active,getContext:()=>context,build:build.replace('youtube-path-v','')});
function log(event){diagnostics.record(event);events.push({at:new Date().toISOString(),event,...context,element:active.tagName,visibility:document.visibilityState,time:Math.round(active.currentTime||0),rate:active.playbackRate,defaultRate:active.defaultPlaybackRate,paused:active.paused,readyState:active.readyState,errorCode:active.error?.code||null,audioSessionState:navigator.audioSession?.state||'unavailable',audioSessionType:navigator.audioSession?.type||'unavailable'});if(events.length>180)events.shift();$('events').textContent=events.map(e=>e.at.slice(11,19)+' '+e.event+' @'+e.time+' '+e.visibility).join('\\n')}
const background=(${createBackgroundPlayback.toString()})({document,navigator,elements:[v,a],getMedia:()=>active,log});
function normalSpeed(m){m.defaultPlaybackRate=1;m.playbackRate=1;if('preservesPitch'in m)m.preservesPitch=true}
function waitForStartupMetadata(media){
  if(media.readyState>=1)return Promise.resolve();
  return new Promise((resolve,reject)=>{
    let timer,settled=false;const cancel=()=>done(Error('Playback cancelled'));
    const done=error=>{if(settled)return;settled=true;clearTimeout(timer);if(hlsStartCancel===cancel)hlsStartCancel=null;media.removeEventListener('loadedmetadata',ready);media.removeEventListener('error',failed);error?reject(error):resolve()};
    const ready=()=>done(),failed=()=>done(Error(tr('Не удалось подготовить поток. Повторите запуск.')));
    hlsStartCancel=cancel;media.addEventListener('loadedmetadata',ready);media.addEventListener('error',failed);
    timer=setTimeout(failed,20000);
  });
}
function status(s){$('status').textContent=s}function reset(){background.reset();playbackKey=null;hlsStartCancel?.();v.pause();a.pause();hls?.destroy();hls=null;v.removeAttribute('src');a.removeAttribute('src');v.load();a.load();normalSpeed(v);normalSpeed(a);if(blobURL)URL.revokeObjectURL(blobURL);blobURL=null;active=v;v.hidden=false;a.hidden=true}
function metadata(title){if('mediaSession'in navigator){navigator.mediaSession.metadata=new MediaMetadata({title,artist:'AxrTube',artwork:[{src:location.origin+'/icon.svg',sizes:'512x512',type:'image/svg+xml'}]});for(const [action,fn]of Object.entries({play:()=>{background.userPlay();log('remote-play');active.play().catch(()=>status(tr('Нужен тап для возобновления')))},pause:()=>{startupPauseRequested=true;background.userPause();log('remote-pause');active.pause()},seekto:d=>{log('remote-seek');if(Number.isFinite(d.seekTime))active.currentTime=d.seekTime},seekbackward:d=>{active.currentTime=Math.max(0,active.currentTime-(d.seekOffset||10))},seekforward:d=>{active.currentTime=Math.min(active.duration||0,active.currentTime+(d.seekOffset||10))}})){try{navigator.mediaSession.setActionHandler(action,fn)}catch{}}}}
for(const m of[v,a]){
  m.addEventListener('loadedmetadata',()=>{if(m===active){normalSpeed(m);log('speed-initialized')}});
  m.addEventListener('ratechange',()=>{if(m===active){log('ratechange');if(!m.paused)status(tr('Воспроизводится · ')+m.playbackRate+'×')}});
  for(const event of['pointerdown','touchstart','keydown'])m.addEventListener(event,()=>{if(busy)startupPauseRequested=true});
  for(const event of['playing','pause','waiting','stalled','ended','error','loadedmetadata'])m.addEventListener(event,()=>{log(event);if(event==='playing'){delete context.failure;status(tr('Воспроизводится · ')+m.playbackRate+'×')}if(event==='error')status(tr('Ошибка медиапотока ')+(m.error?.code||'')+tr('. Рекламный fallback не используется.'))});
}
document.addEventListener('visibilitychange',()=>log('visibilitychange'));window.addEventListener('pagehide',()=>log('pagehide'));
for(const m of[v,a])m.addEventListener('timeupdate',()=>{if(m!==active)return;const bucket=Math.floor(m.currentTime/15);if(bucket!==lastProgress){lastProgress=bucket;log('progress')}});
$('play').onclick=async()=>{
  if(busy)return;
  const key=selectionKey();
  if(playbackKey===key&&!active.error){background.userPlay();log('button-resume');try{await active.play()}catch{status(tr('Нажми Play на самом плеере.'))}return}
  const generation=++playGeneration;busy=true;startupPauseRequested=false;$('play').disabled=true;playbackKey=null;reset();lastProgress=-1;
  context={source:$('source').value,mode:$('source').value==='control'?'audio':$('mode').value};background.userPlay();log('button-start');
  try{
    if(context.source==='control'){
      v.hidden=true;a.hidden=false;active=a;a.src=control;playbackKey=key;metadata(tr('Контрольный MP3'));await a.play();
    }else{
      const raw=$('link').value.trim();let id=raw;
      if(!/^[a-zA-Z0-9_-]{11}$/.test(id)){
        const u=new URL(raw);
        if(!['youtube.com','www.youtube.com','m.youtube.com','youtu.be'].includes(u.hostname))throw Error(tr('Нужна ссылка YouTube'));
        id=u.hostname==='youtu.be'?u.pathname.slice(1):u.searchParams.get('v')||u.pathname.split('/').pop();
      }
      if(!/^[a-zA-Z0-9_-]{11}$/.test(id))throw Error(tr('Некорректная ссылка на ролик'));
      context.videoId=id;
      status(tr('Получаем поток YouTube...'));
      let r=await fetch('/api/resolve?id='+encodeURIComponent(id)+'&mode='+context.mode);let data=await r.json();
      if(generation!==playGeneration)return;
      rememberResolver(r,data);
      if(temporaryResolverFailure(r,data)){
        context.retry={attempt:1,codes:context.failure.codes};log('resolve-retry');
        status(tr('YouTube временно отклонил запрос. Повторяем один раз...'));
        await new Promise(resolve=>setTimeout(resolve,600));
        if(generation!==playGeneration)return;
        r=await fetch('/api/resolve?id='+encodeURIComponent(id)+'&mode='+context.mode);data=await r.json();
        if(generation!==playGeneration)return;
        rememberResolver(r,data);log('resolve-retry-result');
      }
      if(!r.ok&&data.diagnostics?.some(d=>d.code==='PO_TOKEN_REQUIRED')){
        status(tr('Google проверяет браузер телефона...'));log('phone-proof-start');
        const token=await phoneProof(id);
        if(generation!==playGeneration)return;
        r=await fetch('/api/resolve',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({id,mode:context.mode,poToken:token})});data=await r.json();rememberResolver(r,data);log('phone-proof-resolve');
      }
      if(generation!==playGeneration)return;
      if(!r.ok)throw Error(resolverMessage(r,data));
      context.kind=data.kind;
      playTitle=data.title;
      if(data.audioTrack)context.audioTrack=data.audioTrack;
      metadata(data.title);status(data.title+tr(' · нажми Запустить, если браузер запросит жест'));
      if(context.mode==='audio'){active=a;v.hidden=true;a.hidden=false}
      const nativeHls=!!active.canPlayType('application/vnd.apple.mpegurl'),mseHls=!!window.Hls?.isSupported();
      const applePlayback=navigator.vendor==='Apple Computer, Inc.'||/iPhone|iPad|iPod/.test(navigator.userAgent||'');
      if(data.kind==='file'){context.transport='file';active.src=data.source}
      else if(nativeHls&&(applePlayback||!mseHls)){context.transport='native-hls';active.src=data.source}
      else if(mseHls){
        context.transport='mse-hls';
        hls=new Hls();const instance=hls;
        instance.on(Hls.Events.ERROR,(_,d)=>{if(d.fatal&&hls===instance){playbackKey=null;context.failure={stage:'hls',code:String(d.type||'HLS_ERROR').replace(/[^A-Za-z_]/g,'').slice(0,60)};log('hls-fatal');status('HLS: '+d.type+tr('. Нет рекламного fallback.'))}});
        // Chromium has no playable source until MSE attachment and manifest
        // parsing complete. Calling play() before that can reject immediately.
        await new Promise((resolve,reject)=>{
          let timer,settled=false;const cancel=()=>done(Error('Playback cancelled'));const done=error=>{if(settled)return;settled=true;clearTimeout(timer);if(hlsStartCancel===cancel)hlsStartCancel=null;instance.off(Hls.Events.MANIFEST_PARSED,ready);instance.off(Hls.Events.ERROR,failed);error?reject(error):resolve()};
          const ready=()=>done(),failed=(_,d)=>{if(d.fatal)done(Error('HLS: '+d.type))};
          instance.on(Hls.Events.MANIFEST_PARSED,ready);instance.on(Hls.Events.ERROR,failed);
          hlsStartCancel=cancel;timer=setTimeout(()=>done(Error(tr('Не удалось подготовить поток. Повторите запуск.'))),20000);
          instance.loadSource(data.source);instance.attachMedia(active);
        });
        if(generation!==playGeneration)return;
      }else throw Error(tr('В этом браузере HLS не поддерживается'));
      // Android can abort an early play while its pipeline initializes. Wait
      // for metadata (not a full download); saved-position listeners run first.
      if(!applePlayback&&data.kind!=='file'){log('startup-metadata-wait');await waitForStartupMetadata(active);if(generation!==playGeneration)return;log('startup-metadata-ready')}
      playbackKey=key;log('source-ready');
      if(startupPauseRequested)return;
      try{await active.play()}catch(error){
        if(error.name!=='AbortError'||startupPauseRequested||generation!==playGeneration||document.visibilityState!=='visible'||active.error||context.failure?.stage==='hls')throw error;
        // One same-source retry only. Never override explicit Pause or restart
        // a source after Stop, navigation or a background transition.
        log('startup-play-interrupted');await waitForStartupMetadata(active);
        if(startupPauseRequested||generation!==playGeneration||document.visibilityState!=='visible')return;
        background.userPlay();log('startup-play-retry');await active.play();
      }
    }
  }catch(e){if(generation!==playGeneration)return;if(!context.failure)context.failure={stage:'start',code:e.name==='NotAllowedError'?'USER_GESTURE_REQUIRED':e.name==='AbortError'?'PLAY_INTERRUPTED':e instanceof TypeError?'NETWORK_OR_INPUT':'START_FAILED'};status((e.name==='AbortError'?tr('Запуск прерван. Нажмите Play для продолжения.'):e.message)+(context.failure.stage==='resolve'?tr(' Используйте «Повторить запуск».'):tr(' Нажмите Play на плеере или повторите запуск.')));log('start-failed')}
  finally{if(generation===playGeneration){busy=false;$('play').disabled=false}}
};
$('pause').onclick=()=>{startupPauseRequested=true;background.userPause();log('button-pause');active.pause()};$('save').onclick=async()=>{const b=$('save');b.disabled=true;try{status(tr('Сохраняем контрольный MP3 при открытом приложении...'));const r=await fetch(control);if(!r.ok)throw Error(tr('Не удалось скачать'));const blob=await r.blob();if(blob.size>20000000)throw Error(tr('Слишком большой контрольный файл'));const db=await openDB();await new Promise((resolve,reject)=>{const tx=db.transaction('media','readwrite');tx.objectStore('media').put(blob,'control');tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error)});db.close();status(tr('Контрольный MP3 сохранён. Можно включить авиарежим.'))}catch(e){status(tr('Офлайн: ')+e.message)}finally{b.disabled=false}};
function openDB(){return new Promise((resolve,reject)=>{const r=indexedDB.open('axrtube-lab',1);r.onupgradeneeded=()=>r.result.createObjectStore('media');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)})}
$('offline').onclick=async()=>{try{const db=await openDB();const blob=await new Promise((resolve,reject)=>{const r=db.transaction('media').objectStore('media').get('control');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});db.close();if(!blob)throw Error(tr('Сначала сохрани контрольный MP3'));reset();context={source:'local-control',mode:'audio'};lastProgress=-1;v.hidden=true;a.hidden=false;active=a;blobURL=URL.createObjectURL(blob);a.src=blobURL;metadata(tr('Локальный контрольный MP3'));await a.play();log('offline-blob')}catch(e){status(e.message)}};
window.addEventListener('beforeinstallprompt',e=>{e.preventDefault();installPrompt=e;$('install').hidden=false});$('install').onclick=async()=>{await installPrompt?.prompt();installPrompt=null;$('install').hidden=true};
$('report').onclick=()=>{const url=URL.createObjectURL(new Blob([JSON.stringify({build,ua:navigator.userAgent,standalone:matchMedia('(display-mode: standalone)').matches,context,events,diagnostics:diagnostics.report()},null,2)],{type:'application/json'}));const link=document.createElement('a');link.href=url;link.download='axrtube-pwa-report.json';link.click();setTimeout(()=>URL.revokeObjectURL(url),1000)};
if(!window.axrUpdates&&'serviceWorker'in navigator)navigator.serviceWorker.register('/sw.js',{updateViaCache:'none'}).then(r=>r.update()).catch(()=>log('service-worker-unavailable'));
</script></body></html>`;
const engineScript=page.match(/<script>([\s\S]*?)<\/script>/)[1]+`
window.axrPlayer={
 build:'${APP_BUILD}',
 get busy(){return busy},get media(){return active},get title(){return playTitle},
 async start(id,mode){if(busy)return;$('source').value='youtube';$('link').value=id;$('mode').value=mode;playTitle='';await $('play').onclick()},
 stop(){background.stop();++playGeneration;reset();busy=false;$('play').disabled=false;window.dispatchEvent(new Event('axr-player-idle'))},
 toggle(){if(active.paused){background.userPlay();active.play().catch(()=>status('Нажмите Play на плеере'))}else{startupPauseRequested=true;background.userPause();active.pause()}},
 setRate(rate){if([0.75,1,1.25,1.5,2].includes(rate)){active.playbackRate=rate;active.defaultPlaybackRate=rate}}
};`;
// BgUtils 4.0.3 (MIT), LuanRT. The Google VM runs in an opaque sandbox,
// never with access to the parent PWA's storage, cookies or media library.
const phonePage=`<!doctype html><meta charset="utf-8"><script type="module">
import {BotGuardClient,getChallenge} from 'https://cdn.jsdelivr.net/npm/bgutils-js@4.0.3/dist/exports/botguard.js';
import {WebPoMinter} from 'https://cdn.jsdelivr.net/npm/bgutils-js@4.0.3/dist/exports/webpo.js';
import {buildURL,getHeaders} from 'https://cdn.jsdelivr.net/npm/bgutils-js@4.0.3/dist/exports/utils.js';
const {id,nonce}=JSON.parse(decodeURIComponent(location.hash.slice(1)));
try{
 const requestKey='O43z0dpjhgX20SCx4KAo';
 const challenge=await getChallenge({fetchFunction:fetch,requestKey});
 const js=challenge.interpreterJavascript?.privateDoNotAccessOrElseSafeScriptWrappedValue;
 if(!js)throw Error('NO_INTERPRETER');
 new Function(js)();
 const client=await BotGuardClient.create({program:challenge.program,globalName:challenge.globalName,globalObject:globalThis});
 const output=[];const snapshot=await client.snapshot({webPoSignalOutput:output});
 const r=await fetch(buildURL('GenerateIT',true),{method:'POST',headers:getHeaders(),body:JSON.stringify([requestKey,snapshot])});
 if(!r.ok)throw Error('INTEGRITY_HTTP_'+r.status);
 const [integrityToken,estimatedTtlSecs,mintRefreshThreshold]=await r.json();
 if(!integrityToken)throw Error('NO_INTEGRITY_TOKEN');
 const minter=await WebPoMinter.create({integrityToken,estimatedTtlSecs,mintRefreshThreshold},output);
 const token=await minter.mintAsWebsafeString(id);parent.postMessage({nonce,token},'*');
}catch{parent.postMessage({nonce,error:'ATTESTATION_FAILED'},'*')}
</script>`;
// Diagnostics only: which Cloudflare egress address YouTube accepted or refused.
async function egressTrace(){try{const t=await (await fetch('https://www.cloudflare.com/cdn-cgi/trace',{signal:AbortSignal.timeout(3000)})).text();const g=k=>(t.match(new RegExp('^'+k+'=(.*)$','m'))||[])[1]||'';return {egress:g('ip'),egressColo:g('colo')}}catch{return {}}}
export default { async fetch(request,env={},ctx) {
  const u = new URL(request.url);
  try {
    const accountResponse=await youtubeAccountResponse(request,env,catalogResponse,(token,url)=>personalHomeResponse(token,url,parseCatalog));if(accountResponse)return accountResponse;
    let proofRequest;
    if(request.method==='POST'&&u.pathname==='/api/resolve'){
      if(request.headers.get('origin')!==u.origin)return json({error:'Origin rejected'},403);
      const body=await request.text();if(body.length>12000)return json({error:'Request too large'},413);
      proofRequest=JSON.parse(body);
      if(!/^[a-zA-Z0-9_=-]{16,8192}$/.test(proofRequest.poToken||''))return json({error:'Invalid proof'},400);
    }else if (!['GET','HEAD'].includes(request.method)) return new Response('Method not allowed',{status:405});
    if(u.pathname==='/api/version')return json({version:APP_BUILD});
    if(u.pathname==='/api/transcript')return transcriptResponse(u);
    if(['/boot.js','/engine.js','/app.js','/app.css','/hls.js'].includes(u.pathname)&&u.searchParams.has('release')&&u.searchParams.get('release')!==APP_BUILD)return json({error:'Версия приложения изменилась',version:APP_BUILD},409);
    if(u.pathname==='/hls.js'){
      // Fixed package/version only. No user input, credentials or redirects.
      for(const host of ['https://cdn.jsdelivr.net/npm/','https://unpkg.com/']){
        try{const r=await fetch(host+'hls.js@1.7.4/dist/hls.min.js',{redirect:'manual',signal:AbortSignal.timeout(4000)});if(!r.ok){await r.body?.cancel();continue}const body=await r.text();if(body.length>1500000||!body.includes('Hls'))continue;return new Response(body,{headers:{...headers,'content-type':'application/javascript; charset=utf-8','cache-control':'public, max-age=86400'}})}catch{}
      }
      return new Response('HLS library unavailable',{status:503,headers});
    }
    if(u.pathname==='/phone-proof')return new Response(phonePage,{headers:{...headers,'content-type':'text/html; charset=utf-8','content-security-policy':"sandbox allow-scripts"}});
    if(u.pathname==='/api/catalog'){const r=await catalogResponse(u);return json(r.body,r.status)}
    if(u.pathname==='/api/suggest')return json(await suggestionResponse(u));
    if(u.pathname==='/api/sponsor')return json(await sponsorResponse(u));
    if (u.pathname === '/control.mp3') {
      const r = await fetch('https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3', {
        headers: request.headers.has('range') ? { Range: request.headers.get('range') } : {},
        // workerd supports manual/follow only; reject redirects explicitly.
        redirect: 'manual', signal: AbortSignal.timeout(20000)
      });
      if (!r.ok || !r.headers.get('content-type')?.toLowerCase().startsWith('audio/')) {
        await r.body?.cancel();
        return json({ error: 'Контрольный MP3 недоступен на источнике' }, 502);
      }
      const h = new Headers(headers);
      for (const key of ['content-type','content-length','content-range','accept-ranges']) if(r.headers.has(key))h.set(key,r.headers.get(key));
      return new Response(request.method === 'HEAD' ? null : r.body, { status:r.status, headers:h });
    }
    if (u.pathname === '/api/resolve') {
      const id = proofRequest?.id||u.searchParams.get('id');
      if (!/^[a-zA-Z0-9_-]{11}$/.test(id || '')) return json({ error: 'Некорректный ID YouTube' },400);
      try {
        const mode=proofRequest?.mode||u.searchParams.get('mode');
        const item = await resolveVideo(id, mode, proofRequest?.poToken, env?.LEGACY_STREAM_BRIDGE==='true');
        if (mode === 'audio' && item.kind === 'hls' && !item.legacy) {
          const { response, url } = await upstream(item.raw);
          if (!response.ok) throw new Error('HLS unavailable');
          const text = await response.text();
          const audio = selectAudioRendition(text,url);
          item.source = '/audio-master?u='+encodeURIComponent(audio.raw)+'&codec='+encodeURIComponent(audio.codec);
          item.audioTrack = {language:audio.language,name:audio.name,codec:audio.codec,group:audio.group};
        }
        ctx?.waitUntil?.(egressTrace().then(e=>console.log('RESOLVE_OK '+JSON.stringify({id,mode,client:item.client,kind:item.kind,...e}))));
        return json({ id:item.id, title:item.title, source:item.source, kind:item.kind, audioTrack:item.audioTrack });
      } catch(error) {
        const attempts=diagnostics(error);
        ctx?.waitUntil?.(egressTrace().then(e=>console.log('RESOLVE_FAIL '+JSON.stringify({id,attempts,...e}))));
        return json({error:'Поток недоступен. '+attempts.map(a=>a.client+': '+a.code).join('; '),diagnostics:attempts},502);
      }
    }
    if ((u.pathname==='/legacy/media'||u.pathname==='/legacy/audio-master')&&env?.LEGACY_STREAM_BRIDGE==='true') return legacyMediaResponse(u,request);
    if (u.pathname === '/audio-master') {
      const raw=u.searchParams.get('u');
      if(!raw||raw.length>12000)return new Response('Invalid media URL',{status:400});
      return manifestResponse(audioMaster(raw,u.searchParams.get('codec')),raw,request.headers.get('range'),request.method==='HEAD');
    }
    if (u.pathname === '/media') {
      const raw = u.searchParams.get('u');
      if (!raw || raw.length>12000) return new Response('Invalid media URL',{status:400});
      const range=request.headers.get('range');
      // Rewrite the complete playlist first, then apply Safari's byte probe to
      // the representation actually served. Never parse a two-byte HLS fragment.
      let {response:r,url} = await upstream(raw,isManifestURL(raw)?null:range);
      if (!r.ok) return new Response('Media upstream unavailable',{status:r.status});
      const type = r.headers.get('content-type') || '';
      if (type.toLowerCase().includes('mpegurl') || isManifestURL(url)) {
        if(range&&!isManifestURL(raw)){
          await r.body?.cancel();({response:r,url}=await upstream(raw));
          if(!r.ok)return new Response('Manifest upstream unavailable',{status:r.status});
        }
        return manifestResponse(await r.text(),url,range,request.method==='HEAD');
      }
      const h = new Headers(headers);
      for(const key of ['content-type','content-length','content-range','accept-ranges']) if(r.headers.has(key))h.set(key,r.headers.get(key));
      return new Response(request.method==='HEAD'?null:r.body,{status:r.status,headers:h});
    }
    const assets = { '/':[mobilePage,'text/html; charset=utf-8'], '/boot.js':[bootScript,'text/javascript; charset=utf-8'], '/system-player':[systemPlayerPage(APP_BUILD),'text/html; charset=utf-8'], '/lab':[page,'text/html; charset=utf-8'], '/app.css':[appStyle+preferenceStyle+transcriptStyle,'text/css; charset=utf-8'], '/app.js':[i18nClient+transcriptClient+appClient,'text/javascript; charset=utf-8'], '/engine.js':[engineScript,'text/javascript; charset=utf-8'], '/manifest.webmanifest':[JSON.stringify(manifest),'application/manifest+json'], '/icon.svg':[icon,'image/svg+xml'], '/sw.js':[sw,'text/javascript'] };
    assets['/pwa-identity-test/']=[systemPlayerPage(APP_BUILD,{identityTest:true}),'text/html; charset=utf-8'];
    assets['/pwa-identity-test/manifest.webmanifest']=[JSON.stringify(identityTestManifest(u.origin)),'application/manifest+json'];
    assets['/pwa-identity-test/icon.svg']=[icon.replace('#ff453a','#2979ff'),'image/svg+xml'];
    if (!assets[u.pathname]) return new Response('Not found',{status:404});
    // Form POSTs inherit the document policy: no-referrer makes Origin null.
    // Keep same-site forms verifiable without disclosing a referrer externally.
    // OAuth callback/API responses retain their separate no-referrer policy.
    const [body,type]=assets[u.pathname];return new Response(request.method==='HEAD'?null:body,{headers:{...headers,'content-type':type,...(type.startsWith('text/html')?{'referrer-policy':'same-origin'}:{})}});
  } catch { return json({error:'Источник недоступен или отклонён'},400); }
} };
