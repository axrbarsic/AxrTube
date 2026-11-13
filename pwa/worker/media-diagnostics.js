// Local, bounded lifecycle journal. Never records cookies, tokens, media URLs,
// query strings, titles or arbitrary exception text. No network uploads.
export function createMediaDiagnostics({window,document,navigator,getMedia,getContext=()=>({}),build,mode='app'}){
  const key='axrtube.pwa.media-diagnostics.v1';let storageOK=true;
  const stamp=()=>new Date().toISOString();
  const safeTime=value=>typeof value==='string'&&value.length<40&&Number.isFinite(Date.parse(value))?value:null;
  function cleanEvent(raw){
    if(!raw||!/^[a-z0-9-]{1,70}$/.test(raw.event||''))return null;
    const entry={at:safeTime(raw.at),event:raw.event};
    for(const field of ['time','duration','rate','readyState','networkState','errorCode'])if(Number.isFinite(raw[field]))entry[field]=raw[field];
    for(const field of ['paused','ended','muted','hasSource','persisted'])if(typeof raw[field]==='boolean')entry[field]=raw[field];
    if(['visible','hidden','prerender'].includes(raw.visibility))entry.visibility=raw.visibility;
    if(['video','audio','none'].includes(raw.mode))entry.mode=raw.mode;
    if(['youtube','control','local-control','none'].includes(raw.source))entry.source=raw.source;
    if(['native-hls','mse-hls','file'].includes(raw.transport))entry.transport=raw.transport;
    if(/^[\w-]{11}$/.test(raw.videoId||''))entry.videoId=raw.videoId;
    return entry;
  }
  function read(){
    try{const raw=JSON.parse(window.localStorage.getItem(key)||'null');if(raw?.schema!==1)return {schema:1,runs:[],observations:[]};
      const runs=(Array.isArray(raw.runs)?raw.runs:[]).slice(-4).filter(r=>r&&/^[\w-]{1,60}$/.test(r.id||'')&&['app','native-control'].includes(r.mode)).map(r=>({id:r.id,mode:r.mode,build:/^\d{1,5}$/.test(r.build||'')?r.build:'unknown',createdAt:safeTime(r.createdAt),standalone:r.standalone===true,ua:typeof r.ua==='string'?r.ua.slice(0,400):'',events:(Array.isArray(r.events)?r.events:[]).slice(-240).map(cleanEvent).filter(Boolean)}));
      const observations=(Array.isArray(raw.observations)?raw.observations:[]).slice(-10).filter(o=>o&&['correct-app','wrong-app','audio-stopped','not-tested'].includes(o.value)).map(o=>({at:safeTime(o.at),value:o.value,run:/^[\w-]{1,60}$/.test(o.run||'')?o.run:null}));
      return {schema:1,runs,observations};
    }catch{storageOK=false;return {schema:1,runs:[],observations:[]}}
  }
  const id=window.crypto?.randomUUID?.()||String(Date.now())+'-'+Math.random().toString(36).slice(2);
  const run={id,mode,build:String(build),createdAt:stamp(),standalone:!!navigator.standalone||!!window.matchMedia?.('(display-mode: standalone)').matches,ua:String(navigator.userAgent||'').slice(0,400),events:[]};
  function persist(){try{const data=read();data.runs=[...data.runs.filter(r=>r.id!==id),run].slice(-4);window.localStorage.setItem(key,JSON.stringify(data))}catch{storageOK=false}}
  function record(event,detail={}){
    const media=getMedia(),context=getContext();
    const entry=cleanEvent({event,at:stamp(),visibility:document.visibilityState,time:Math.round((media?.currentTime||0)*1000)/1000,duration:media?.duration,rate:media?.playbackRate,readyState:media?.readyState,networkState:media?.networkState,errorCode:media?.error?.code||0,paused:media?.paused,ended:media?.ended,muted:media?.muted,hasSource:!!(media?.currentSrc||media?.getAttribute?.('src')),mode:context.mode,source:context.source,transport:context.transport,videoId:context.videoId,persisted:detail.persisted});
    if(entry){run.events.push(entry);run.events=run.events.slice(-240);persist()}
  }
  for(const event of ['pageshow','pagehide','focus','blur'])window.addEventListener(event,e=>record('window-'+event,{persisted:!!e.persisted}));
  for(const event of ['visibilitychange','freeze','resume'])document.addEventListener(event,()=>record('document-'+event));
  record('document-start');
  return {record,report(){persist();const data=read();data.runs=[...data.runs.filter(r=>r.id!==id),run].slice(-4);return {...data,storageOK,scope:'local-only',limitation:'iOS does not expose the identity of another launched app or the native Now Playing owner to this page'}},observe(value){
    if(!['correct-app','wrong-app','audio-stopped','not-tested'].includes(value))return;
    persist();try{const data=read(),target=[...data.runs].reverse().find(r=>r.mode==='native-control'&&r.events.some(e=>e.event==='media-playing'))||run;data.observations.push({at:stamp(),run:target.id,value});data.observations=data.observations.slice(-10);window.localStorage.setItem(key,JSON.stringify(data))}catch{storageOK=false}
  }};
}

// Opt-in only, on the separate control page. Does not configure AudioSession,
// change the source/rate or retry interrupted playback.
export function bindControlMediaSession({session,Metadata,media,record}){
  if(!session||!Metadata)return 'unsupported';
  try{session.metadata=new Metadata({title:'AxrTube Check: тест 2',artist:'AxrTube Check'});}
  catch{record('session-metadata-error');return 'failed'}
  let handlers=0;
  for(const [name,handler] of Object.entries({
    play:()=>{record('session-remote-play');media.play().catch(()=>record('session-play-rejected'))},
    pause:()=>{record('session-remote-pause');media.pause()}
  }))try{session.setActionHandler(name,handler);handlers++}catch{record('session-handler-unsupported')}
  const update=()=>{try{session.playbackState=media.paused||media.ended?'paused':'playing'}catch{record('session-state-error')}};
  for(const event of ['play','playing','pause','ended'])media.addEventListener(event,update);
  update();record('session-binding-enabled');return handlers===2?'enabled':'metadata-only';
}

export function systemPlayerPage(build,{identityTest=false}={}){
  const appName=identityTest?'AxrTube Check':'AxrTube';
  const manifestPath=identityTest?'/pwa-identity-test/manifest.webmanifest':'/manifest.webmanifest';
  const steps=identityTest?'<li>Открой эту страницу в Safari. Поделиться → На экран «Домой». Оставь включённым «Открывать как веб-приложение», если такой переключатель показан.</li><li>Закрой страницу и запусти новую иконку AxrTube Check. Основной AxrTube не удаляй.</li>':'';
  return `<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="apple-mobile-web-app-capable" content="yes"><meta name="theme-color" content="#101012"><meta name="apple-mobile-web-app-title" content="${appName}"><link rel="manifest" href="${manifestPath}"><title>${appName}: системный тест</title><style>*{box-sizing:border-box}body{margin:0;background:#101012;color:#fafafa;font:17px system-ui;line-height:1.5}main{max-width:640px;margin:auto;padding:24px 20px calc(30px + env(safe-area-inset-bottom))}h1{font-size:27px}audio,video{width:100%;margin:20px 0}video{min-height:180px;max-height:320px;background:#000}button,select,a{font:inherit}button,select{width:100%;min-height:48px;border-radius:12px;padding:12px;margin:8px 0;border:1px solid #555;background:#29292d;color:white}a{color:#a5c9ff}p,li{color:#ccc}#saved{font-size:14px;overflow-wrap:anywhere}pre{white-space:pre-wrap;max-height:160px;overflow:auto;font-size:12px}</style></head><body><main><a href="/#settings">Вернуться в AxrTube</a><h1>${identityTest?'AxrTube Check: отдельный ярлык':'Тест экрана блокировки'}</h1><p>Версия ${build}. Обычный аудиоплеер: без YouTube, HLS.js и нашего восстановления фона. По умолчанию без настройки Media Session / Audio Session.</p>${identityTest?'<p>Эксперименты 1 и 2 не устранили сбой. Эксперимент 3 меняет audio на video, сохраняя источник MP3 и системную медиасессию. Изображения не будет: проверяем элемент плеера, не видеокодек. Основной AxrTube и его данные не изменяются. Входить в Google не нужно.</p>':''}<p id="launch"></p><ol>${steps}<li>Нажми Play в плеере ниже и подожди 10 секунд.</li><li>Заблокируй iPhone, затем нажми карточку воспроизведения, чтобы открыть приложение.</li><li>Если открылся чужой ярлык, вернись через иконку ${appName}${identityTest?'':' и снова открой этот тест в настройках'}.</li><li>Выбери результат и скачай отчёт. Предыдущие события сохраняются локально даже после повторного запуска.</li></ol>${identityTest?'<button id="video-control">Включить эксперимент 3: video</button><button id="bind-session">Включить эксперимент 2</button><p id="session-state">Эксперименты выключены. Для новой проверки сначала выбери нужный эксперимент, затем нажми Play.</p><button onclick="location.reload()">Обновить тест</button>':''}<audio id="control" controls preload="none" src="/control.mp3"></audio><label for="result">Что произошло?</label><select id="result"><option value="not-tested">Ещё не проверял</option><option value="correct-app">Открылся ${appName}</option><option value="wrong-app">Открылся чужой ярлык</option><option value="audio-stopped">Звук остановился</option></select><button id="download">Скачать отчёт теста</button><p id="saved"></p><p>Отчёт не отправляется автоматически. iOS не сообщает странице название открывшегося чужого приложения. В отчёте нет cookies, токенов, истории аккаунта или подписанных медиассылок.</p><details><summary>Последние события</summary><pre id="trace"></pre></details></main><script>
let media=document.getElementById('control');
let sessionBinding='off',mediaElement='audio',started=false;
const diagnostics=(${createMediaDiagnostics.toString()})({window,document,navigator,getMedia:()=>media,getContext:()=>({source:'control',mode:mediaElement}),build:${JSON.stringify(String(build))},mode:'native-control'});
const draw=()=>{const data=diagnostics.report();document.getElementById('saved').textContent=data.storageOK?'Журнал сохраняется на этом устройстве. Записей запусков: '+data.runs.length:'Хранилище недоступно. Скачай отчёт до закрытия страницы.';document.getElementById('trace').textContent=data.runs.flatMap(r=>r.events.slice(-12).map(e=>e.at+' '+e.event+' '+e.visibility)).slice(-25).join(String.fromCharCode(10))};
let bucket=-1;
function observeMedia(){
  for(const event of ['play','playing','pause','waiting','stalled','ended','error','loadedmetadata','seeking','seeked'])media.addEventListener(event,()=>{if(event==='play'){started=true;const button=document.getElementById('video-control');if(button)button.disabled=true}diagnostics.record('media-'+event);draw()});
  media.addEventListener('timeupdate',()=>{const next=Math.floor(media.currentTime/5);if(next!==bucket){bucket=next;diagnostics.record('media-progress')}});
}
observeMedia();
${identityTest?`const bindSession=${bindControlMediaSession.toString()};
const bindingButton=document.getElementById('bind-session');
const videoButton=document.getElementById('video-control');
function enableSession(){sessionBinding=bindSession({session:navigator.mediaSession,Metadata:window.MediaMetadata,media,record:event=>diagnostics.record(event)});bindingButton.disabled=true;videoButton.disabled=true;document.getElementById('session-state').textContent={enabled:(mediaElement==='video'?'Эксперимент 3 включён: video + системная медиасессия.':'Эксперимент 2 включён: audio + системная медиасессия.')+' Нажми Play и повтори блокировку.',unsupported:'Браузер не поддерживает эту проверку.',failed:'Не удалось включить системную привязку.',"metadata-only":'Зарегистрировано только название, команды недоступны.'}[sessionBinding];draw()}
bindingButton.onclick=enableSession;
videoButton.onclick=()=>{
  if(started||sessionBinding!=='off'){document.getElementById('session-state').textContent='Для эксперимента 3 сначала нажми «Обновить тест». Текущий звук не прерывался.';return}
  const next=document.createElement('video');next.id='control';next.controls=true;next.preload='none';next.playsInline=true;next.setAttribute('playsinline','');next.setAttribute('src',media.getAttribute('src'));media.replaceWith(next);media=next;mediaElement='video';observeMedia();diagnostics.record('control-video-selected');enableSession();
};
`:''}
document.getElementById('launch').textContent=(navigator.standalone||matchMedia('(display-mode: standalone)').matches)?'Тест открыт внутри установленной PWA.':${JSON.stringify(identityTest?'Сейчас это вкладка Safari. Сначала добавь отдельную иконку AxrTube Check и открой её.':'Внимание: сейчас это вкладка браузера. Для проверки открой тест из настроек установленной PWA.')};
document.getElementById('result').onchange=e=>{diagnostics.observe(e.target.value);draw()};
document.getElementById('download').onclick=()=>{diagnostics.record('report-download');const blob=new Blob([JSON.stringify({type:'axrtube-media-isolation-v1',variant:${JSON.stringify(identityTest?'separate-identity':'existing-identity')},build:${JSON.stringify(String(build))},sessionBinding,mediaElement,diagnostics:diagnostics.report()},null,2)],{type:'application/json'});const url=URL.createObjectURL(blob),link=document.createElement('a');link.href=url;link.download=${JSON.stringify(identityTest?'axrtube-identity-test-report.json':'axrtube-system-player-report.json')};link.click();setTimeout(()=>URL.revokeObjectURL(url),1000)};draw();
</script></body></html>`;}

// A separate installation identity, not a migration of the main PWA.
// Full origin-qualified URLs rule out ambiguous relative launch metadata.
export function identityTestManifest(origin){
  const base=new URL('/pwa-identity-test/',origin);
  if(base.protocol!=='https:')throw Error('HTTPS required');
  return {name:'AxrTube Check',short_name:'AxrTube Check',id:base.href,start_url:base.href,scope:base.href,display:'standalone',background_color:'#101012',theme_color:'#101012',icons:[{src:new URL('icon.svg',base).href,sizes:'any',type:'image/svg+xml',purpose:'any maskable'}]};
}
