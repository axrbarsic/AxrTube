import assert from 'node:assert/strict';
import {personalHomeResponse} from '../worker/personal-home.js';
import {parseCatalog} from '../worker/catalog.js';
import {youtubeAccountResponse,sealAccount} from '../worker/youtube-account.js';
const tile=(id,title,type='TILE_CONTENT_TYPE_VIDEO')=>({tileRenderer:{contentType:type,onSelectCommand:{watchEndpoint:{videoId:id}},metadata:{tileMetadataRenderer:{title:{simpleText:title},lines:[{lineRenderer:{items:[{lineItemRenderer:{text:{simpleText:'Channel'}}}]}}]}},header:{tileHeaderRenderer:{thumbnail:{thumbnails:[{url:'https://i.ytimg.com/vi/'+id+'/hqdefault.jpg'}]}}}}});
const data={contents:[tile('abcdefghijk','First'),{adSlotRenderer:{content:tile('adadadadada','Ad')}},tile('lmnopqrstuv','Second'),tile('badbadbadba','Ad tile','TILE_CONTENT_TYPE_AD'),tile('12345678901','Short','TILE_CONTENT_TYPE_REEL')],continuations:[{nextContinuationData:{continuation:'google-next'}}],responseContext:{visitorData:'visitor-next'}};
assert.deepEqual(parseCatalog(data).videos.map(v=>v.id),['abcdefghijk','lmnopqrstuv','12345678901']);assert.equal(parseCatalog(data).videos[2].isShort,true);
const token='private-test-only-token';const originalFetch=globalThis.fetch;let calls=0,mode='ok';
try{
globalThis.fetch=async(url,options)=>{calls++;assert.equal(String(url),'https://youtubei.googleapis.com/youtubei/v1/browse');assert.equal(options.headers.authorization,'Bearer '+token);assert.equal(options.redirect,'manual');assert(!options.headers.cookie);const body=JSON.parse(options.body);assert.equal(body.context.client.clientName,'TVHTML5');assert.equal(body.context.client.clientVersion,'7.20260311.12.00');if(calls===1)assert.equal(body.browseId,'FEwhat_to_watch');else if(calls===2){assert.equal(body.continuation,'google-next');assert.equal(body.context.client.visitorData,'visitor-next');assert.equal(body.browseId,undefined)}return mode==='ok'?Response.json(data):mode==='guest'?Response.json({...data,responseContext:{mainAppWebResponseContext:{loggedOut:true}}}):new Response('do-not-expose-private-provider-body',{status:401})};
let r=await personalHomeResponse(token,new URL('https://lab.test/?lang=ru'),parseCatalog);assert.equal(r.status,200);assert.equal(r.headers.get('cache-control'),'no-store');let body=await r.text();assert(!body.includes(token));assert.equal(JSON.parse(body).source,'youtube-personal-home');assert.deepEqual(JSON.parse(body).videos.map(v=>v.id),['abcdefghijk','lmnopqrstuv','12345678901']);
r=await personalHomeResponse(token,new URL('https://lab.test/?continuation=google-next&visitor=visitor-next'),parseCatalog);assert.equal(r.status,200);
mode='bad';r=await personalHomeResponse(token,new URL('https://lab.test/'),parseCatalog);assert.equal(r.status,409);assert.equal((await r.json()).code,'PERSONAL_HOME_AUTH_UNSUPPORTED');
mode='guest';assert.equal((await personalHomeResponse(token,new URL('https://lab.test/'),parseCatalog)).status,409);
const env={GOOGLE_OAUTH_ENABLED:'true',GOOGLE_OAUTH_CLIENT_ID:'123-test.apps.googleusercontent.com',GOOGLE_OAUTH_CLIENT_SECRET:'test-only',GOOGLE_OAUTH_COOKIE_KEY:'03'.repeat(32)};
const origin='https://axrtube.axrbarsic.workers.dev',epoch='test-only-epoch',session=await sealAccount(env,'session',{token,epoch,expires:Date.now()+60000});let delegated=false;
assert.equal((await youtubeAccountResponse(new Request(origin+'/api/account/home'),env,null,()=>{delegated=true})).status,401);assert.equal(delegated,false);
r=await youtubeAccountResponse(new Request(origin+'/api/account/home',{headers:{cookie:'__Host-axr-yt-epoch='+epoch+'; __Host-axr-yt-session='+session}}),env,null,(value,u)=>{assert.equal(value,token);delegated=true;return Response.json({source:'test'})});assert.equal(r.status,200);assert.equal(delegated,true);
}finally{globalThis.fetch=originalFetch}
console.log('PASS: native TV browse, encrypted session gate, token isolation/fixed Google host, provider ordering, TV tiles, ads/Shorts, continuation/visitor and explicit unsupported-auth outcome');
