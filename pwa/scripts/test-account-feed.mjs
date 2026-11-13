import assert from 'node:assert/strict';
import vm from 'node:vm';
import {sealAccount,youtubeAccountResponse} from '../worker/youtube-account.js';
import {appClient} from '../worker/app-client.js';
const origin='https://axrtube.axrbarsic.workers.dev';
const env={GOOGLE_OAUTH_ENABLED:'true',GOOGLE_OAUTH_CLIENT_ID:'123-test.apps.googleusercontent.com',GOOGLE_OAUTH_CLIENT_SECRET:'test-only',GOOGLE_OAUTH_COOKIE_KEY:'02'.repeat(32)};
const token='test-only-private-token',epoch='test-only-epoch';
const session=await sealAccount(env,'session',{token,epoch,expires:Date.now()+60000});
const headers={cookie:'__Host-axr-yt-epoch='+epoch+'; __Host-axr-yt-session='+session};
const request=(page='')=>youtubeAccountResponse(new Request(origin+'/api/account/feed?page='+page,{headers}),env);
assert.equal((await youtubeAccountResponse(new Request(origin+'/api/account/feed'),env)).status,401);
const ids=['UC'+'a'.repeat(22),'UC'+'b'.repeat(22)];
const originalFetch=globalThis.fetch;let calls=[],failure='';
try{
  globalThis.fetch=async(url,options)=>{
    const u=new URL(url);calls.push(u);assert.equal(options.headers.authorization,'Bearer '+token);assert.equal(u.origin,'https://www.googleapis.com');
    if(u.pathname.endsWith('/subscriptions')){assert.equal(u.searchParams.get('maxResults'),'6');assert.equal(u.searchParams.get('mine'),'true');assert.equal(u.searchParams.get('order'),'alphabetical');return Response.json({nextPageToken:'next-batch',items:failure==='empty'?[]:ids.map((id,n)=>({snippet:{title:'Channel '+n,resourceId:{channelId:id}}}))})}
    if(u.pathname.endsWith('/channels')){assert.equal(u.searchParams.get('id'),ids.join(','));return Response.json({items:ids.map((id,n)=>({id,contentDetails:{relatedPlaylists:{uploads:'UU'+n}}}))})}
    assert(u.pathname.endsWith('/playlistItems'));assert.equal(u.searchParams.get('maxResults'),'5');
    if(failure==='all'||(failure&&u.searchParams.get('playlistId')==='UU0'))return new Response('',{status:failure==='unauthorized'?401:403});
    const n=u.searchParams.get('playlistId')==='UU0'?0:1;
    return Response.json({items:[{snippet:{title:'Video '+n},contentDetails:{videoId:n?'lmnopqrstuv':'abcdefghijk',videoPublishedAt:n?'2026-11-09T12:00:00Z':'2026-11-08T12:00:00Z'}},{snippet:{title:'Invalid'},contentDetails:{videoId:'bad'}}]});
  };
  const r=await request();assert.equal(r.status,200);assert.equal(r.headers.get('cache-control'),'no-store');assert.equal(r.headers.getSetCookie().length,0);
  const text=await r.text();assert(!text.includes(token));const d=JSON.parse(text);assert.deepEqual(d.videos.map(v=>v.id),['lmnopqrstuv','abcdefghijk']);assert.equal(d.channels.length,2);assert.equal(d.nextPage,'next-batch');assert.equal(d.partial,false);assert.equal(calls.length,4);
  calls=[];await request('next-batch');assert.equal(calls[0].searchParams.get('pageToken'),'next-batch');
  calls=[];let catalogCalls=0;
  const videosOnly=await youtubeAccountResponse(new Request(origin+'/api/account/feed?hideShorts=1',{headers}),env,async url=>{catalogCalls++;assert.equal(url.searchParams.get('feed'),'channel');assert(ids.includes(url.searchParams.get('channel')));assert(!url.href.includes(token));return {status:200,body:{videos:[{id:'abcdefghijk',title:'Regular 15-second video',isShort:false},{id:'lmnopqrstuv',title:'Short',isShort:true}]}}});
  const filtered=await videosOnly.json();assert.equal(filtered.videosOnly,true);assert.equal(filtered.videos.length,1);assert.equal(filtered.videos[0].title,'Regular 15-second video');assert.equal(catalogCalls,2);assert.equal(calls.length,1);
  assert.equal((await youtubeAccountResponse(new Request(origin+'/api/account/feed?hideShorts=1',{headers}),env,async()=>({status:502}))).status,502);
  failure='partial';const partial=await(await request()).json();assert.equal(partial.partial,true);assert.equal(partial.videos.length,1);
  failure='unauthorized';assert.equal((await request()).status,401);
  failure='all';assert.equal((await request()).status,502);
  failure='empty';calls=[];const empty=await(await request()).json();assert.equal(empty.videos.length,0);assert.equal(calls.length,1);
}finally{globalThis.fetch=originalFetch}

// Execute the actual shipped home/auth functions, not a copied routing model.
function element(){return {children:[],append(...items){this.children.push(...items)},replaceChildren(...items){this.children=items},querySelector(){return null},remove(){this.removed=true}}}
function fixture(){
  const elements=new Map();const calls=[];
  const context=vm.createContext({t:value=>value,i18n:null,console,URLSearchParams,Date,Map,Set,JSON,Error,Number,
    node:(tag,cls,text)=>Object.assign(element(),{tag,cls,text}),button:(text,action)=>({text,action}),empty:(title,text,action)=>({title,text,action}),grid:videos=>({videos}),
    el:id=>{if(!elements.has(id))elements.set(id,element());return elements.get(id)},
    state:{route:'home',request:0,controller:null,videos:[]},library:{hideShorts:false},account:{loading:true},accountCheck:null,accountCheckedAt:0,
    catalog:params=>calls.push(params),cleanVideo:v=>v,location:{hash:''},you(){},subscriptions(){},settings(){},
    fetch:async()=>{throw Error('Set fixture response')}
  });
  const refresh=appClient.slice(appClient.indexOf('async function refreshAccount()'),appClient.indexOf('function accountAction('));
  const home=appClient.slice(appClient.indexOf('function home(){'),appClient.indexOf('async function accountList('));
  new vm.Script(refresh+home).runInContext(context);return {context,elements,calls};
}
let f=fixture();f.context.home();assert.equal(f.calls.length,0);assert(f.elements.get('content').children.some(e=>e.text==='Проверяем аккаунт YouTube...'));
f.context.fetch=async url=>url==='/api/account'?Response.json({configured:true,signedIn:true,name:'Test account',expiresAt:Date.now()+60000}):Response.json({channels:[],videos:[]});
await f.context.refreshAccount();await new Promise(resolve=>setImmediate(resolve));assert.equal(f.context.account.signedIn,true);assert.equal(f.calls.length,0);assert(f.elements.get('content').children.some(e=>e.text==='Подключён YouTube: Test account'));
f=fixture();f.context.account={loading:false,configured:true,signedIn:false};f.context.home();assert.equal(f.calls.length,1);assert.equal(f.calls[0].feed,'home');
f=fixture();f.context.account={loading:false,configured:true,signedIn:true,expiresAt:1};f.context.home();assert.equal(f.context.account.signedIn,false);assert.equal(f.calls.length,0);
f=fixture();f.context.account={loading:false,configured:true,signedIn:true,name:'Test'};f.context.fetch=async()=>new Response('{}',{status:401});await f.context.subscriptionHome();assert.equal(f.context.account.signedIn,false);assert.equal(f.calls.length,0);
// A late home response may not overwrite another route.
f=fixture();let finish;f.context.fetch=()=>new Promise(resolve=>finish=resolve);const loading=f.context.subscriptionHome();f.context.state.request++;f.context.state.route='search';finish(Response.json({videos:[],channels:[]}));await loading;assert(!f.elements.has('home-videos'));
console.log('PASS: private bounded subscription feed, date order, pagination, partial/API errors, token isolation, signed-in home, startup auth race, expiry and stale-route guard');
// Renewal outages must not replace a known saved account with guest state.
f=fixture();f.context.state.route='you';f.context.account={configured:true,signedIn:true,name:'Saved account',remembered:true,recommendationsAuthorized:true,expiresAt:1,loading:false};f.context.fetch=async()=>Response.json({code:'ACCOUNT_RETRY'},{status:503});await f.context.refreshAccount();assert.equal(f.context.account.signedIn,true);assert.equal(f.context.account.remembered,true);assert.equal(f.context.account.recommendationsAuthorized,true);assert.equal(f.context.account.name,'Saved account');
let personalLoads=0;f.context.personalHome=()=>personalLoads++;f.context.state.route='home';f.context.home();assert.equal(personalLoads,1);assert.equal(f.context.account.signedIn,true);
f.context.state.route='you';f.context.fetch=async()=>Response.json({configured:true,signedIn:false,code:'SESSION_REVOKED'},{status:401});await f.context.refreshAccount();assert.equal(f.context.account.signedIn,false);
console.log('PASS: remembered token expiry does not sign out frontend, transient account check preserves identity and permissions, real revocation clears UI state');
