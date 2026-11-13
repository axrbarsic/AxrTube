// Browser bootstrap: coherent versioned assets, no reload during a media session.
export function createUpdateClient({window,document,navigator,fetch,build}) {
  let registration,checking,reloading=false;
  const state={build,latest:build,status:'checking'};
  const idle=()=>{const p=window.axrPlayer,m=p?.media;return !p||(!p.busy&&!m?.currentSrc&&!m?.getAttribute?.('src'));};
  function announce(){window.dispatchEvent(new window.Event('axr-update-state'));}
  function message(text,retry=false){
    let box=document.getElementById('startup-status');
    if(!box){box=document.createElement('div');box.id='startup-status';box.setAttribute('role','status');box.style.cssText='padding:16px;color:#ddd;background:#202020;font:15px system-ui';document.body.prepend(box);}
    box.textContent=text;
    if(retry){const b=document.createElement('button');b.textContent='Повторить';b.onclick=()=>{try{window.sessionStorage.removeItem('axrtube-update-reload')}catch{}window.location.reload()};box.append(b);}
  }
  function apply(){
    if(state.latest===build||reloading)return false;
    if(!idle()){state.status='pending';announce();return false;}
    try{
      const last=JSON.parse(window.sessionStorage.getItem('axrtube-update-reload')||'null');
      if(last?.version===state.latest&&Date.now()-last.at<120000){state.status='rollout';announce();message('Сервер ещё переключается на новую версию. Повторите открытие немного позже.',true);return false;}
      window.sessionStorage.setItem('axrtube-update-reload',JSON.stringify({version:state.latest,at:Date.now()}));
    }catch{}
    reloading=true;state.status='updating';announce();
    const url=new URL(window.location.href);url.searchParams.set('v',state.latest);
    window.location.replace(url.href);return true;
  }
  async function check(){
    if(checking)return checking;
    checking=(async()=>{
      registration?.update().catch(()=>{});
      const controller=new AbortController();const timer=window.setTimeout(()=>controller.abort(),4500);
      try{
        const r=await fetch('/api/version',{cache:'no-store',signal:controller.signal});
        if(!r.ok)throw Error('Version unavailable');const data=await r.json();
        if(!/^\d{1,6}$/.test(data.version||''))throw Error('Invalid version');
        // During a rollout, an older edge must never downgrade an open client.
        if(Number(data.version)>Number(state.latest))state.latest=data.version;
        if(Number(state.latest)>Number(build)){apply();}
        else{state.status='current';if(state.latest===build){try{window.sessionStorage.removeItem('axrtube-update-reload')}catch{}}}
      }catch{if(state.status!=='pending')state.status='offline';}
      finally{window.clearTimeout(timer);announce();}
      return state.status;
    })();
    try{return await checking}finally{checking=null}
  }
  function loadScript(src,optional=false){return new Promise((resolve,reject)=>{
    const script=document.createElement('script');script.src=src;script.async=false;
    let done=false;const finish=error=>{if(done)return;done=true;window.clearTimeout(timer);if(error&&!optional)reject(error);else resolve()};
    const timer=window.setTimeout(()=>finish(Error('Script timeout')),10000);
    script.onload=()=>finish();script.onerror=()=>finish(Error('Script unavailable'));document.head.append(script);
  })}
  async function start(){
    message('Проверяем обновления приложения...');
    await check();if(reloading||state.status==='rollout')return;
    try{
      // Same-origin delivery works when a mobile network blocks the CDN.
      await loadScript('/hls.js?release='+build,!!document.createElement('video').canPlayType?.('application/vnd.apple.mpegurl'));
      await loadScript('/engine.js?release='+build);
      if(window.axrPlayer?.build!==build)throw Error('Engine version mismatch');
      await loadScript('/app.js?release='+build);
      if(state.status==='offline')message('Нет связи с сервером обновлений. Открыта сохранённая версия '+build+'.');
      else document.getElementById('startup-status')?.remove();
    }catch{await check();if(!reloading)message('Не удалось загрузить согласованную версию приложения. Проверьте соединение.',true);}
    if('serviceWorker'in navigator){try{registration=await navigator.serviceWorker.register('/sw.js',{updateViaCache:'none'});registration.update().catch(()=>{});}catch{}}
  }
  document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')check();});
  window.addEventListener('pageshow',e=>{if(e.persisted)check();});
  window.addEventListener('axr-player-idle',()=>{if(state.latest!==build)apply();});
  return {start,check,get state(){return {...state}}};
}

export function serviceWorkerSource(build) {
  return `const BUILD=${JSON.stringify(build)},CACHE='axrtube-shell-r'+BUILD;
const SHELL=['/','/boot.js?release='+BUILD,'/app.js?release='+BUILD,'/app.css?release='+BUILD,'/engine.js?release='+BUILD,'/hls.js?release='+BUILD,'/icon.svg','/manifest.webmanifest'];
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting())));
self.addEventListener('activate',e=>e.waitUntil((async()=>{for(const name of await caches.keys()){if((name.startsWith('axrtube-shell-r')||name.startsWith('axrtube-lab-shell-v'))&&name!==CACHE)await caches.delete(name)}await self.clients.claim()})()));
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(u.origin!==self.location.origin||e.request.method!=='GET')return;
const key=u.pathname==='/'?'/':u.pathname+u.search;if(!SHELL.includes(key))return;
e.respondWith(fetch(e.request,{cache:'no-store'}).catch(async()=>{const cached=await(await caches.open(CACHE)).match(key);return cached||new Response('Offline asset unavailable',{status:503})}));});`;
}
