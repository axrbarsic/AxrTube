import assert from 'node:assert/strict';
import vm from 'node:vm';
import {orderedChannels,visibleVideos,installStandaloneUI,appClient} from '../worker/app-client.js';
import {parseCatalog} from '../worker/catalog.js';
const a={id:'UC'+'a'.repeat(22),name:'Альфа'},b={id:'UC'+'b'.repeat(22),name:'Бета'},c={id:'UC'+'c'.repeat(22),name:'Гамма'};
assert.deepEqual(orderedChannels([c,b,a,b,{id:'bad'}],[]),[a,b,c]);
assert.deepEqual(orderedChannels([a,b,c],[c.id,b.id]),[c,b,a]);
assert.deepEqual(orderedChannels([a,b,c],[c.id]),[c,a,b]);
const videos=[{id:'abcdefghijk',duration:'0:15',isShort:false},{id:'lmnopqrstuv',isShort:true},{id:'12345678901'}];
assert.deepEqual(visibleVideos(videos,true),[videos[0],videos[2]]);assert.equal(visibleVideos(videos,false),videos);
const known=parseCatalog({videoRenderer:{videoId:'abcdefghijk',title:{simpleText:'Short'},thumbnailOverlays:[{thumbnailOverlayTimeStatusRenderer:{style:'SHORTS'}}]}});assert.equal(known.videos[0].isShort,true);
// Only the installed PWA gets page-zoom suppression. Single-finger scrolling
// and browser accessibility controls outside standalone remain unchanged.
function nativeFixture(active){const listeners=new Map();let viewport='',added='';const doc={documentElement:{classList:{add:value=>added=value}},querySelector:()=>({setAttribute:(key,value)=>viewport=value}),addEventListener:(name,fn,options)=>{assert.equal(options.passive,false);listeners.set(name,fn)}};const result=installStandaloneUI({matchMedia:()=>({matches:active})},doc,{});return {result,listeners,get viewport(){return viewport},get added(){return added}}}
let f=nativeFixture(false);assert.equal(f.result,false);assert.equal(f.listeners.size,0);assert.equal(f.viewport,'');
f=nativeFixture(true);assert.equal(f.result,true);assert.equal(f.added,'axr-standalone');assert(f.viewport.includes('user-scalable=no'));let prevented=0;
f.listeners.get('touchmove')({touches:[{}],cancelable:true,preventDefault:()=>prevented++});assert.equal(prevented,0);
f.listeners.get('touchmove')({touches:[{},{}],cancelable:true,preventDefault:()=>prevented++});assert.equal(prevented,1);
f.listeners.get('gesturestart')({cancelable:true,preventDefault:()=>prevented++});assert.equal(prevented,2);
// Actual local-library hydration preserves previous data, filters invalid pins,
// and restores the preference across launch without migrating/deleting storage.
const hydration=appClient.slice(appClient.indexOf('const storeKey='),appClient.indexOf('const state='));
const stored={history:videos,later:[videos[0]],queue:[videos[1]],pinnedChannels:[c.id,c.id,'bad',b.id],hideShorts:true,sponsorBlock:true};
let persisted;const scope=vm.createContext({t:value=>value,localStorage:{getItem:()=>JSON.stringify(stored),setItem:(key,value)=>persisted=JSON.parse(value)},toast(){},storageOK:true});
new vm.Script(hydration+';globalThis.read=library;'+appClient.slice(appClient.indexOf('function persist(){'),appClient.indexOf('let toastTimer;'))+'persist();').runInContext(scope);
assert.deepEqual([...scope.read.pinnedChannels],[c.id,b.id]);assert.equal(scope.read.hideShorts,true);assert.equal(scope.read.history.length,3);assert.equal(persisted.queue.length,1);assert.equal(persisted.sponsorBlock,true);
// Pin buttons execute the shipped event handler and re-render without fetching.
function elem(tag,cls,text){return {tag,cls,text,children:[],attrs:{},append(...items){this.children.push(...items)},replaceChildren(...items){this.children=items},setAttribute(key,value){this.attrs[key]=value}}}
const ui=vm.createContext({t:value=>value,node:elem,button:(text,onclick,cls)=>({...elem('button',cls,text),onclick}),orderedChannels,library:{pinnedChannels:[]},persist:()=>true,renderChannels(){},toast(){},location:{hash:''}});
new vm.Script(appClient.slice(appClient.indexOf('function channelRows('),appClient.indexOf('function renderChannels('))).runInContext(ui);
let rows=ui.channelRows([b,a]);rows.children[2].children[1].onclick();assert.deepEqual([...ui.library.pinnedChannels],[b.id]);rows=ui.channelRows([a,b]);assert.equal(rows.children[0].text,'Закреплённые');assert.equal(rows.children[1].children[0].text,'Бета');assert.equal(rows.children[1].children[1].attrs['aria-pressed'],'true');rows.children[1].children[1].onclick();assert.equal(ui.library.pinnedChannels.length,0);
let pages=0;Object.assign(ui,{AbortController,URLSearchParams,state:{request:0,controller:null},account:{signedIn:true},el:()=>elem('div'),fetch:async url=>{pages++;return Response.json(pages===1?{items:[b],nextPage:'second'}:{items:[a,b],nextPage:null})}});
new vm.Script(appClient.slice(appClient.indexOf('async function subscriptions(){'),appClient.indexOf('function home(){'))).runInContext(ui);
await ui.subscriptions();assert.equal(pages,2);assert.deepEqual([...ui.state.subChannels].map(c=>c.id),[a.id,b.id]);
console.log('PASS: known Shorts filtering without duration guessing, pinned order/toggle, preference persistence, existing-library preservation and standalone-only zoom/scroll policy');
