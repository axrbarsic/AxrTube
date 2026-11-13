import assert from 'node:assert/strict';
import vm from 'node:vm';
import {createUpdateClient,serviceWorkerSource} from '../worker/app-updates.js';
import app from '../worker/index.js';
function fixture({version='17',offline=false,playing=false}={}){
  const listeners=new Map(),storage=new Map(),replacements=[],messages=[];
  const document={visibilityState:'visible',addEventListener:(name,fn)=>listeners.set(name,fn),getElementById:()=>null,body:{prepend:n=>messages.push(n)},createElement:()=>({style:{},setAttribute(){},append(){}})};
  const window={location:{href:'https://lab.test/?video=abcdefghijk#you',replace:url=>replacements.push(url),reload(){}},Event:class{constructor(type){this.type=type}},dispatchEvent(){},addEventListener:(name,fn)=>listeners.set(name,fn),setTimeout,clearTimeout,sessionStorage:{getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v),removeItem:k=>storage.delete(k)}};
  if(playing)window.axrPlayer={busy:false,media:{currentSrc:'https://lab.test/media?private',getAttribute:()=>'/media?private'}};
  const fetch=async()=>{if(offline)throw Error('Offline');return new Response(JSON.stringify({version}))};
  const client=createUpdateClient({window,document,navigator:{},fetch,build:'17'});
  return {client,window,document,storage,replacements,messages,listeners};
}
let f=fixture();await f.client.check();assert.equal(f.client.state.status,'current');assert.equal(f.replacements.length,0);
f=fixture({version:'18'});await f.client.check();assert.equal(f.replacements.length,1);assert(f.replacements[0].includes('v=18'));assert(f.replacements[0].endsWith('#you'));
f=fixture({version:'18',playing:true});await f.client.check();assert.equal(f.client.state.status,'pending');assert.equal(f.replacements.length,0);f.window.axrPlayer.media={currentSrc:'',getAttribute:()=>null};f.listeners.get('axr-player-idle')();assert.equal(f.replacements.length,1);
f=fixture({version:'16'});await f.client.check();assert.equal(f.replacements.length,0);
f=fixture({offline:true});await f.client.check();assert.equal(f.client.state.status,'offline');assert.equal(f.replacements.length,0);
f=fixture({version:'18'});f.storage.set('axrtube-update-reload',JSON.stringify({version:'18',at:Date.now()}));await f.client.check();assert.equal(f.replacements.length,0);assert.equal(f.client.state.status,'rollout');
f=fixture({version:'https://evil.test'});await f.client.check();assert.equal(f.replacements.length,0);assert.equal(f.client.state.status,'offline');
// Simulate a whole SW lifecycle. Cleanup may touch ONLY app-owned shell caches.
const handlers=new Map(),deleted=[],added=[];
const scope=vm.createContext({self:{location:{origin:'https://lab.test'},addEventListener:(e,fn)=>handlers.set(e,fn),skipWaiting:async()=>{},clients:{claim:async()=>{}}},caches:{keys:async()=>['axrtube-shell-r16','axrtube-lab-shell-v15','axrtube-shell-r17','axrtube-media-v1','other-app'],delete:async k=>deleted.push(k),open:async()=>({addAll:async paths=>added.push(...paths),match:async key=>new Response('cached:'+key)})},URL,Response,fetch:async()=>{throw Error('Offline')}});
new vm.Script(serviceWorkerSource('17')).runInContext(scope);
let operation;handlers.get('install')({waitUntil:p=>operation=p});await operation;assert(added.includes('/app.js?release=17'));
handlers.get('activate')({waitUntil:p=>operation=p});await operation;assert.deepEqual(deleted,['axrtube-shell-r16','axrtube-lab-shell-v15']);
let intercepted=false;handlers.get('fetch')({request:new Request('https://lab.test/api/version'),respondWith(){intercepted=true}});assert(!intercepted);
handlers.get('fetch')({request:new Request('https://lab.test/?v=old'),respondWith:p=>operation=p});assert.equal(await(await operation).text(),'cached:/');
assert.equal((await app.fetch(new Request('https://lab.test/api/version'))).headers.get('cache-control'),'no-store');
assert.equal((await app.fetch(new Request('https://lab.test/app.js?release=16'))).status,409);
const release=(await(await app.fetch(new Request('https://lab.test/api/version'))).json()).version;
const html=await(await app.fetch(new Request('https://lab.test/'))).text();assert(html.includes('/boot.js?release='+release));assert(!html.includes('<script src="/app.js">'));
const boot=await(await app.fetch(new Request('https://lab.test/boot.js?release='+release))).text();new vm.Script(boot);
console.log('PASS: cold/resume version check, playback-safe deferral, downgrade/loop guard, offline fallback, version-pinned assets and shell-only cache cleanup');
