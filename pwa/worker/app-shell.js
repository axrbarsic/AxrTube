// Static shell, styles, manifest, icon and service worker for the AxrTube
// transcript hunter. No inline scripts; CSP allows only same-origin code.
export function appPage(build) {
  return '<!doctype html><html lang="ru"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover,interactive-widget=resizes-content">' +
    '<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)"><meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)">' +
    '<meta name="apple-mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-status-bar-style" content="default"><meta name="apple-mobile-web-app-title" content="AxrTube">' +
    '<title>AxrTube</title><link rel="manifest" href="/manifest.webmanifest"><link rel="icon" href="/icon.svg" type="image/svg+xml"><link rel="apple-touch-icon" href="/icon-180.png">' +
    '<link rel="stylesheet" href="/app.css?v=' + build + '"></head><body>' +
    '<header class="top"><button id="back" class="icon-btn back" aria-label="Назад" hidden>‹</button><div id="title" class="top-title">AxrTube</div><button id="account" class="account" aria-label="Войти"></button></header>' +
    '<main id="main"></main>' +
    '<form id="composer" class="composer" hidden><div id="replychip" class="replychip" hidden></div><div class="composer-row"><textarea id="field" rows="1" maxlength="10000" placeholder="Написать комментарий" aria-label="Комментарий"></textarea><button id="send" class="send" type="submit" disabled aria-label="Отправить">↑</button></div></form>' +
    '<div id="sheet" class="sheet" hidden></div><div id="toast" class="toast" role="status" hidden></div><div id="app" hidden></div>' +
    '<script src="/app.js?v=' + build + '" defer></script></body></html>';
}

export const appCSS = `
:root{--bg:#fff;--fg:#0f1419;--muted:#536471;--line:#eff3f4;--card:#f7f9f9;--accent:#1d9bf0;--accent-fg:#fff;--mark:#ffe58a;--danger:#f4212e;--shadow:0 8px 28px rgba(0,0,0,.12);color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--bg:#000;--fg:#e7e9ea;--muted:#71767b;--line:#2f3336;--card:#16181c;--accent:#1d9bf0;--mark:#7a5d00;--shadow:0 8px 28px rgba(0,0,0,.6)}}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
[hidden]{display:none!important}
img.broken{visibility:hidden}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;padding-bottom:env(safe-area-inset-bottom)}
button,input,select,textarea{font:inherit;color:inherit}
a{color:inherit;text-decoration:none}
.top{position:sticky;top:0;z-index:20;display:flex;align-items:center;gap:8px;height:calc(52px + env(safe-area-inset-top));padding:env(safe-area-inset-top) 12px 0;background:color-mix(in srgb,var(--bg) 85%,transparent);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);border-bottom:1px solid var(--line)}
.top-title{flex:1;font-weight:800;font-size:19px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.icon-btn{border:0;background:none;width:36px;height:36px;border-radius:50%;font-size:24px;line-height:1;display:grid;place-items:center;cursor:pointer;color:var(--muted);flex:none}
.icon-btn:active{background:var(--card)}
.back{font-size:34px;color:var(--fg)}
.account{border:0;background:none;padding:0;cursor:pointer;flex:none}
.signin{display:inline-block;padding:6px 14px;border-radius:999px;background:var(--fg);color:var(--bg);font-weight:700;font-size:15px}
.avatar{width:40px;height:40px;border-radius:50%;flex:none;display:grid;place-items:center;background:var(--accent);color:#fff;font-weight:700;object-fit:cover}
.avatar.small{width:32px;height:32px;font-size:15px}
main{max-width:640px;margin:0 auto;padding:0 0 calc(96px + env(safe-area-inset-bottom))}
.hero{padding:22px 16px 6px}.hero h1{margin:0 0 6px;font-size:26px;line-height:1.15;letter-spacing:-.02em}
.muted{color:var(--muted)}
.search{position:relative;padding:12px 16px 0}
.search-box{display:flex;gap:8px}
.search-box input{flex:1;min-width:0;height:46px;padding:0 16px;border-radius:999px;border:1px solid var(--line);background:var(--card);outline:none;font-size:16px}
.search-box input:focus{border-color:var(--accent);background:var(--bg)}
.suggest{position:absolute;left:16px;right:16px;top:64px;z-index:15;background:var(--bg);border:1px solid var(--line);border-radius:16px;box-shadow:var(--shadow);overflow:hidden}
.suggest-item{display:block;width:100%;text-align:left;border:0;background:none;padding:12px 16px;cursor:pointer}
.suggest-item:active,.suggest-item:hover{background:var(--card)}
.actions{display:flex;gap:8px;padding:10px 16px 4px}
.btn{border:1px solid var(--line);background:var(--bg);border-radius:999px;padding:9px 16px;font-weight:700;font-size:15px;cursor:pointer;white-space:nowrap}
.btn:active{transform:scale(.98)}
.btn.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-fg)}
.btn.icon{width:42px;padding:9px 0}
.btn.wide{display:block;width:100%;margin-top:10px}
.btn:disabled{opacity:.5}
.section-title{padding:18px 16px 6px;font-weight:800;font-size:19px}
.row{display:flex;gap:12px;align-items:flex-start;padding:10px 16px;border-bottom:1px solid var(--line)}
.row:active{background:var(--card)}
.row-thumb{position:relative;width:132px;aspect-ratio:16/9;border-radius:10px;overflow:hidden;background:var(--card);flex:none}
.row-thumb img{width:100%;height:100%;object-fit:cover;display:block}
.badge{position:absolute;right:4px;bottom:4px;padding:1px 5px;border-radius:4px;background:rgba(0,0,0,.8);color:#fff;font-size:12px;font-weight:600}
.row-text{flex:1;min-width:0}
.row-title{font-weight:600;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
.row-meta{color:var(--muted);font-size:14px;margin-top:2px}
.skeleton .row-thumb,.skeleton .line{animation:pulse 1.2s ease-in-out infinite}
.line{height:12px;border-radius:6px;background:var(--card);margin:6px 0}.line.short{width:55%}
@keyframes pulse{50%{opacity:.45}}
.empty{text-align:center;color:var(--muted);padding:28px 16px}
.error{margin:16px;padding:16px;border-radius:16px;background:var(--card);text-align:center}.error p{margin:0 0 10px}
.video-head{display:flex;gap:12px;padding:14px 16px}
.video-thumb{position:relative;width:148px;aspect-ratio:16/9;border-radius:12px;overflow:hidden;flex:none;background:var(--card)}
.video-thumb img{width:100%;height:100%;object-fit:cover;display:block}
.play{position:absolute;inset:auto auto 6px 6px;width:28px;height:28px;border-radius:50%;background:rgba(0,0,0,.65);color:#fff;font-size:12px;display:grid;place-items:center}
.video-text{min-width:0}.video-title{font-weight:800;font-size:17px;line-height:1.25;display:-webkit-box;-webkit-line-clamp:4;-webkit-box-orient:vertical;overflow:hidden}
.tabs{display:flex;border-bottom:1px solid var(--line);position:sticky;top:calc(52px + env(safe-area-inset-top));z-index:10;background:var(--bg)}
.tab{flex:1;text-align:center;padding:14px 4px 12px;color:var(--muted);font-weight:600;position:relative}
.tab.active{color:var(--fg);font-weight:800}
.tab.active::after{content:"";position:absolute;left:50%;bottom:0;width:56px;height:4px;border-radius:2px;background:var(--accent);transform:translateX(-50%)}
.sticky{position:sticky;top:calc(101px + env(safe-area-inset-top));z-index:9;background:color-mix(in srgb,var(--bg) 92%,transparent);backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px);padding:10px 16px;border-bottom:1px solid var(--line)}
.toolbar{display:flex;gap:8px}.toolbar .btn.primary{flex:1}
.findrow{display:flex;gap:8px;align-items:center;margin-top:8px}
.find{flex:1;min-width:0;height:38px;padding:0 14px;border-radius:999px;border:1px solid var(--line);background:var(--card);outline:none}
.find-count{font-size:13px;white-space:nowrap}
.lang{max-width:42%;height:38px;border-radius:999px;border:1px solid var(--line);background:var(--card);padding:0 10px}
.tinfo{padding:12px 16px 0;font-size:14px}
.tbody{padding:4px 16px 24px}
.para{display:flex;gap:10px;padding:10px 0;border-bottom:1px solid var(--line)}
.time{flex:none;border:0;background:var(--card);color:var(--accent);font-weight:700;font-size:13px;border-radius:8px;padding:3px 7px;height:fit-content;cursor:pointer;font-variant-numeric:tabular-nums}
.ptext{margin:0;font-size:17px;line-height:1.55;user-select:text;-webkit-user-select:text}
mark{background:var(--mark);color:inherit;border-radius:3px;padding:0 1px}
.loading{display:grid;place-items:center;gap:10px;padding:40px 16px}
.spinner{width:28px;height:28px;border-radius:50%;border:3px solid var(--line);border-top-color:var(--accent);animation:spin .8s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.gate{margin:24px 16px;padding:22px;border-radius:18px;background:var(--card);text-align:center}.gate p{margin:0 0 14px}
.segmented{display:flex;background:var(--card);border-radius:999px;padding:3px}
.segmented button{flex:1;border:0;background:none;border-radius:999px;padding:7px 10px;font-weight:700;color:var(--muted);cursor:pointer}
.segmented button.on{background:var(--bg);color:var(--fg);box-shadow:0 1px 3px rgba(0,0,0,.12)}
.thread{border-bottom:1px solid var(--line);padding:4px 0}
.comment{display:flex;gap:12px;padding:10px 16px}
.comment.reply{padding-left:68px}
.comment.reply .avatar{width:28px;height:28px;font-size:13px}
.cbody{flex:1;min-width:0}
.chead{font-size:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.cname{font-weight:700}
.ctext{white-space:pre-wrap;overflow-wrap:anywhere;font-size:16px;margin-top:2px;user-select:text;-webkit-user-select:text}
.ctext.clamped{display:-webkit-box;-webkit-line-clamp:7;-webkit-box-orient:vertical;overflow:hidden}
.more,.link{border:0;background:none;padding:0;color:var(--accent);font-weight:600;cursor:pointer;font-size:14px}
.cactions{display:flex;gap:18px;align-items:center;margin-top:6px;font-size:14px}
.cactions .link{color:var(--muted)}
.likes{font-size:14px}
.toggle{margin:2px 0 8px 68px}
.fresh{animation:fresh 2s ease}
@keyframes fresh{from{background:color-mix(in srgb,var(--accent) 18%,transparent)}to{background:transparent}}
.foot{padding:12px 16px}
.composer{position:fixed;left:0;right:0;bottom:0;z-index:25;background:var(--bg);border-top:1px solid var(--line);padding:8px 12px calc(8px + env(safe-area-inset-bottom))}
.composer-row{display:flex;gap:8px;align-items:flex-end;max-width:640px;margin:0 auto}
.composer textarea{flex:1;min-width:0;resize:none;border:1px solid var(--line);background:var(--card);border-radius:20px;padding:9px 14px;max-height:160px;outline:none;font-size:16px;line-height:1.35}
.composer textarea:focus{border-color:var(--accent);background:var(--bg)}
.send{flex:none;width:40px;height:40px;border-radius:50%;border:0;background:var(--accent);color:#fff;font-size:20px;font-weight:800;cursor:pointer}
.send:disabled{opacity:.4}
.replychip{display:flex;align-items:center;justify-content:space-between;max-width:640px;margin:0 auto 6px;padding:2px 4px 2px 14px;border-radius:999px;background:var(--card);color:var(--muted);font-size:14px}
.replychip .icon-btn{width:28px;height:28px;font-size:20px}
.sheet{position:fixed;inset:0;z-index:40}
.sheet-scrim{position:absolute;inset:0;background:rgba(0,0,0,.4)}
.sheet-panel{position:absolute;left:0;right:0;bottom:0;max-width:640px;margin:0 auto;background:var(--bg);border-radius:20px 20px 0 0;padding:8px 20px calc(20px + env(safe-area-inset-bottom));box-shadow:var(--shadow)}
.grabber{width:40px;height:5px;border-radius:3px;background:var(--line);margin:0 auto 14px}
.sheet-title{font-weight:800;font-size:20px}
.toast{position:fixed;left:50%;bottom:calc(90px + env(safe-area-inset-bottom));transform:translate(-50%,12px);opacity:0;z-index:50;background:var(--fg);color:var(--bg);padding:10px 16px;border-radius:999px;font-weight:600;font-size:15px;transition:.22s;width:max-content;max-width:calc(100% - 32px);text-align:center;pointer-events:none}
.toast.show{opacity:1;transform:translate(-50%,0)}
.clip{position:fixed;top:-100px;opacity:0}
@media (min-width:700px){main{border-left:1px solid var(--line);border-right:1px solid var(--line);min-height:100vh}}
`;

export const appManifest = {
  name: 'AxrTube: стенограммы и обсуждения', short_name: 'AxrTube', id: '/', start_url: '/', scope: '/', display: 'standalone',
  background_color: '#000000', theme_color: '#000000', lang: 'ru',
  icons: [{ src: '/icon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any maskable' }],
  share_target: { action: '/share', method: 'GET', params: { title: 'title', text: 'text', url: 'url' } }
};

export const appIcon = '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512"><rect width="512" height="512" rx="112" fill="#0f1419"/><rect x="96" y="120" width="320" height="272" rx="56" fill="#1d9bf0"/><rect x="146" y="186" width="220" height="24" rx="12" fill="#fff"/><rect x="146" y="244" width="180" height="24" rx="12" fill="#fff" opacity=".85"/><rect x="146" y="302" width="130" height="24" rx="12" fill="#fff" opacity=".7"/></svg>';

export function serviceWorkerSource(build) {
  return `const CACHE='axrtube-shell-${build}';const SHELL=['/','/app.js?v=${build}','/app.css?v=${build}','/icon.svg','/manifest.webmanifest'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(e.request.method!=='GET'||u.origin!==location.origin||u.pathname.startsWith('/api/')||u.pathname.startsWith('/oauth/'))return;
e.respondWith(fetch(e.request).then(r=>{if(r.ok&&(e.request.mode==='navigate'||SHELL.includes(u.pathname+u.search))){const copy=r.clone();caches.open(CACHE).then(c=>c.put(e.request.mode==='navigate'?'/':e.request,copy))}return r}).catch(()=>caches.match(e.request.mode==='navigate'?'/':e.request)))});`;
}
