import assert from 'node:assert/strict';
import vm from 'node:vm';
import {parseCatalog,catalogResponse,suggestionResponse,cleanSponsorSegments} from '../worker/catalog.js';
import {appClient,sponsorSkipTarget} from '../worker/app-client.js';
import {appPage} from '../worker/app-shell.js';
import app from '../worker/index.js';
const video=(id,title)=>({videoRenderer:{videoId:id,title:{runs:[{text:title}]},ownerText:{runs:[{text:'Канал',navigationEndpoint:{browseEndpoint:{browseId:'UCkSKeRJBl41I1nDNaa7lNrw'}}}]},thumbnail:{thumbnails:[{url:'https://evil.test/track'}]},lengthText:{simpleText:'12:34'}}});
const fixture={contents:[video('abcdefghijk','Первое <script>'),{adSlotRenderer:{contents:video('adsadsads00','Реклама')}},video('lmnopqrstuv','Второе'),video('abcdefghijk','Дубликат'),{continuationItemRenderer:{continuationEndpoint:{continuationCommand:{token:'next-page'}}}}]};
const parsed=parseCatalog(fixture);assert.deepEqual(parsed.videos.map(v=>v.id),['abcdefghijk','lmnopqrstuv']);assert.equal(parsed.continuation,'next-page');assert.equal(parsed.videos[0].title,'Первое <script>');assert.equal(parsed.videos[0].thumbnail,'https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg');assert.equal(parsed.videos[0].channelId,'UCkSKeRJBl41I1nDNaa7lNrw');
assert.equal(parseCatalog({contents:[{promotedVideoRenderer:video('abcdefghijk','ad')}]}).videos.length,0);
// Current WEB channel Videos tab uses lockupViewModel, not TV tileRenderer.
const lockup=(id,type='LOCKUP_CONTENT_TYPE_VIDEO')=>({lockupViewModel:{contentId:id,contentType:type,metadata:{lockupMetadataViewModel:{title:{content:'Channel upload'},metadata:{contentMetadataViewModel:{metadataRows:[{metadataParts:[{text:{content:'Channel name'}}]}]}}}},contentImage:{thumbnailViewModel:{image:{sources:[{url:'https://i.ytimg.com/vi/'+id+'/hqdefault.jpg'}]}}}}});
const channelFixture={contents:[lockup('abcdefghijk'),lockup('lmnopqrstuv'),lockup('playlist000','LOCKUP_CONTENT_TYPE_PLAYLIST'),{adSlotRenderer:{content:lockup('adsadsads00')}},{continuationItemRenderer:{continuationEndpoint:{continuationCommand:{token:'channel-next'}}}}]};
const channelParsed=parseCatalog(channelFixture);assert.deepEqual(channelParsed.videos.map(v=>v.id),['abcdefghijk','lmnopqrstuv']);assert.equal(channelParsed.videos[0].channel,'Channel name');assert.equal(channelParsed.continuation,'channel-next');assert.equal(channelParsed.videos[0].isShort,false);
const segments=cleanSponsorSegments([{category:'sponsor',segment:[10,20]},{category:'selfpromo',segment:[18,25]},{category:'intro',segment:[1,4]},{category:'sponsor',segment:[-2,5]},{category:'sponsor',segment:[2,NaN]}]);
assert.equal(segments.length,2);assert.equal(sponsorSkipTarget(segments,12,100),25);assert.equal(sponsorSkipTarget(segments,30,100),null);assert.equal(sponsorSkipTarget(segments,12,Infinity),null);assert.equal(sponsorSkipTarget([{start:90,end:101}],95,100),null);
new vm.Script(appClient);
const ids=[...appPage.matchAll(/id="([^"]+)"/g)].map(m=>m[1]);assert.equal(ids.length,new Set(ids).size);
for(const id of ['video','offlineAudio','source','mode','link','play','pause','save','offline','status','events','install','installHelp','report'])assert(ids.includes(id),'Missing player hook: '+id);
assert(!appPage.includes('<iframe'));assert(!appClient.includes('innerHTML'));
assert.equal((await catalogResponse(new URL('https://lab.test/api/catalog?feed=channel&channel=bad'))).status,400);
const originalFetch=globalThis.fetch;
try{
let calls=[];globalThis.fetch=async(url,options)=>{calls.push({url,body:JSON.parse(options.body)});return new Response(JSON.stringify(fixture))};
const r=await catalogResponse(new URL('https://lab.test/api/catalog?q=hello&continuation=page2'));assert.equal(r.status,200);assert.equal(calls[0].body.continuation,'page2');assert.equal(calls[0].body.query,undefined);assert.equal(calls[0].body.context.client.clientName,'WEB');
globalThis.fetch=async()=>new Response('Denied',{status:403});assert.equal((await catalogResponse(new URL('https://lab.test/api/catalog?q=hello'))).body.code,'CATALOG_HTTP_403');
globalThis.fetch=async()=>new Response('callback(["q",[["first",0],["second",0]]])');assert.deepEqual((await suggestionResponse(new URL('https://lab.test/api/suggest?q=q'))).suggestions,['first','second']);
}finally{globalThis.fetch=originalFetch}
const engine=await(await app.fetch(new Request('https://lab.test/engine.js'))).text();new vm.Script(engine);assert(engine.includes('window.axrPlayer'));
console.log('PASS: catalog order, ad exclusion, text/thumbnail boundaries, continuation, suggestions, shell hooks and shipped JS syntax');
