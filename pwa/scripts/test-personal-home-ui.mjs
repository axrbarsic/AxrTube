import assert from 'node:assert/strict';
import vm from 'node:vm';
import {appClient} from '../worker/app-client.js';
const elements=new Map(),calls=[],messages=[];
function element(tag='',cls='',text=''){
 const n={tag,cls,text,children:[],classList:{add(){}},append(...items){this.children.push(...items)},replaceChildren(...items){this.children=items},remove(){this.removed=true},querySelector(selector){const cls=selector.slice(1);for(const child of this.children){if(!child.removed&&child.cls===cls)return child;const found=child.querySelector?.(selector);if(found)return found}return null}};
 Object.defineProperty(n,'id',{set(value){elements.set(value,n)}});return n;
}
let reply={videos:[{id:'zzzzzzzzzzz'},{id:'aaaaaaaaaaa'},{id:'sssssssssss',isShort:true}],continuation:'page-two',visitor:'visitor-one',source:'youtube-personal-home',personalized:true},status=200;
const context=vm.createContext({t:s=>s,URLSearchParams,AbortController,Date,Map,Set,Error,
 state:{route:'home',request:0,videos:[],controller:null},account:{signedIn:true,recommendationsAuthorized:true},library:{hideShorts:true},i18n:{locale:'uk'},
 el:id=>{if(!elements.has(id))elements.set(id,element());return elements.get(id)},node:element,button:(text,action,cls)=>Object.assign(element('button',cls,text),{action}),empty:(title,text,action)=>Object.assign(element('div','empty',text),{title,action}),grid:videos=>({videos:videos.filter(v=>!context.library.hideShorts||!v.isShort)}),cleanVideo:v=>v,refreshHome(){},home(){},toast:s=>messages.push(s),catalog(){},subscriptionHome(){throw Error('Must not rotate subscriptions')},
 fetch:async(url,options)=>{calls.push({url,options});return Response.json(reply,{status})}
});
new vm.Script(appClient.slice(appClient.indexOf('function renderPersonalHome(){'),appClient.indexOf('async function subscriptionHome('))).runInContext(context);
new vm.Script(appClient.slice(appClient.indexOf('async function refreshHome(){'),appClient.indexOf('function renderPersonalHome(){'))).runInContext(context);
assert.equal(await context.personalHome(),true);
assert.deepEqual(Array.from(context.state.videos,v=>v.id),['zzzzzzzzzzz','aaaaaaaaaaa','sssssssssss']);
assert.deepEqual(Array.from(elements.get('personal-videos').children[0].videos,v=>v.id),['zzzzzzzzzzz','aaaaaaaaaaa']);
assert.equal(new URL(calls[0].url,'https://test').searchParams.get('lang'),'uk');
assert.equal(calls[0].options.cache,'no-store');assert(calls[0].options.signal);
reply={...reply,videos:[{id:'aaaaaaaaaaa'},{id:'bbbbbbbbbbb'}],continuation:null};
await context.personalHome('page-two',true);
assert.deepEqual(Array.from(context.state.videos,v=>v.id),['zzzzzzzzzzz','aaaaaaaaaaa','sssssssssss','bbbbbbbbbbb']);
const page=new URL(calls[1].url,'https://test');assert.equal(page.searchParams.get('continuation'),'page-two');assert.equal(page.searchParams.get('visitor'),'visitor-one');
reply={...reply,videos:[{id:'nnnnnnnnnnn'}],continuation:'fresh-next'};
await context.refreshHome();const refresh=new URL(calls[2].url,'https://test');assert.equal(refresh.searchParams.has('continuation'),false);assert.equal(refresh.searchParams.get('visitor'),'visitor-one');
assert.deepEqual(Array.from(context.state.videos,v=>v.id),['nnnnnnnnnnn']);assert.equal(messages.pop(),'Рекомендации обновлены');
status=502;reply={code:'PERSONAL_HOME_UNAVAILABLE'};await context.refreshHome();assert.deepEqual(Array.from(context.state.videos,v=>v.id),['nnnnnnnnnnn']);assert.equal(context.state.homeLoading,false);assert.equal(context.state.homeRefreshing,false);
// A late response after navigation must never replace another screen.
status=200;let complete;context.fetch=()=>new Promise(resolve=>complete=resolve);const pending=context.personalHome('',false,true);context.state.request++;context.state.route='search';const before=elements.get('content').children;complete(Response.json({videos:[{id:'xxxxxxxxxxx'}],source:'youtube-personal-home',personalized:true}));await pending;assert.equal(elements.get('content').children,before);
console.log('PASS: shipped personal-home provider order, dedupe, Shorts filter, continuation/visitor/language, refresh from first page, retained cards on error, stale response guard');
