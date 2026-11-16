import assert from 'node:assert/strict';
import vm from 'node:vm';
import app,{appScript} from '../worker/index.js';
import {videoIdFrom,formatClock,transcriptText,countWords,relativeTime,compactNumber} from '../worker/app-client.js';
import {appPage} from '../worker/app-shell.js';
import {sealAccount,youtubeAccountResponse} from '../worker/youtube-account.js';
import {commentsResponse,cleanThread} from '../worker/comments.js';
import {transcriptResponse,panelSegments,panelLanguages} from '../worker/transcript.js';

// ---------- Pure helpers ----------
const id='dQw4w9WgXcQ';
for(const raw of [id,'https://www.youtube.com/watch?v='+id+'&t=10','https://youtu.be/'+id+'?si=x','https://m.youtube.com/watch?v='+id,'https://www.youtube.com/shorts/'+id,
  'https://www.youtube.com/live/'+id,'https://music.youtube.com/watch?v='+id,'Смотри: https://youtu.be/'+id+' круто','https://www.youtube.com/embed/'+id])assert.equal(videoIdFrom(raw),id,raw);
for(const raw of ['','hello world','https://evil.test/watch?v='+id,'https://youtube.com.evil.test/watch?v='+id,'https://www.youtube.com/watch?v=short','javascript:alert(1)'])assert.equal(videoIdFrom(raw),null,raw);
assert.equal(formatClock(0),'0:00');assert.equal(formatClock(65.9),'1:05');assert.equal(formatClock(3661),'1:01:01');assert.equal(formatClock(-5),'0:00');
const doc={id,title:'Название',channel:'Канал',sections:[{start:0,paragraphs:[{start:0,end:5,text:'Первый абзац.'},{start:65,end:70,text:'Второй абзац.'}]}]};
assert.equal(transcriptText(doc,false),'Название\nКанал\nhttps://youtu.be/'+id+'\n\nПервый абзац.\n\nВторой абзац.');
assert.equal(transcriptText(doc,true).split('\n\n').slice(1).join('|'),'[0:00] Первый абзац.|[1:05] Второй абзац.');
assert.equal(countWords("Привет, мир! It's a test — 42."),6);
const now=Date.parse('2026-11-16T12:00:00Z');
assert.equal(relativeTime('2026-11-16T11:59:30Z',now),'сейчас');assert.equal(relativeTime('2026-11-16T11:30:00Z',now),'30 мин');
assert.equal(relativeTime('2026-11-16T09:00:00Z',now),'3 ч');assert.equal(relativeTime('2026-11-14T12:00:00Z',now),'2 дн');
assert.equal(relativeTime('2026-03-05T12:00:00Z',now),'5 мар');assert.equal(relativeTime('2025-03-05T12:00:00Z',now),'5 мар 2025');assert.equal(relativeTime('bad',now),'');
assert.equal(compactNumber(999),'999');assert.equal(compactNumber(1234),'1,2 тыс.');assert.equal(compactNumber(56000),'56 тыс.');assert.equal(compactNumber(2500000),'2,5 млн');

// ---------- Shell and router ----------
new vm.Script(appScript);
assert(!appScript.includes('innerHTML'));assert(!appScript.includes('insertAdjacentHTML'));assert(!appScript.includes('eval('));
const ids=[...appPage('1').matchAll(/id="([^"]+)"/g)].map(m=>m[1]);assert.equal(ids.length,new Set(ids).size);
for(const hook of ['back','title','account','main','composer','replychip','field','send','sheet','toast','app'])assert(ids.includes(hook),'Missing hook '+hook);
for(const used of appScript.matchAll(/\$\('([a-z]+)'\)/g))assert(ids.includes(used[1])||['pane','threads','cfoot','tabc','vtitle','vchannel','q'].includes(used[1]),'Unknown element '+used[1]);
const origin='https://axrtube.axrbarsic.workers.dev';
const get=(path,env={})=>app.fetch(new Request(origin+path),env);
let r=await get('/');assert.equal(r.status,200);assert.equal(r.headers.get('referrer-policy'),'same-origin');
const csp=r.headers.get('content-security-policy');assert(csp.includes("script-src 'self'"));assert(!csp.includes('unsafe-inline'));assert(csp.includes("frame-ancestors 'none'"));
const html=await r.text();assert(!html.includes('<iframe'));assert(!/<script>/.test(html));assert(html.includes('/app.js?v='));
r=await get('/app.js');assert.equal(await r.text(),appScript);
r=await get('/app.css');assert(r.headers.get('content-type').startsWith('text/css'));
const manifest=await(await get('/manifest.webmanifest')).json();assert.equal(manifest.share_target.action,'/share');assert.equal(manifest.display,'standalone');
const png=new Uint8Array(await(await get('/icon-180.png')).arrayBuffer());assert.deepEqual([...png.slice(1,4)],[80,78,71]);
new vm.Script(await(await get('/sw.js')).text());
r=await get('/share?text='+encodeURIComponent('Смотри https://youtu.be/'+id));assert.equal(r.status,303);assert.equal(r.headers.get('location'),'/#v='+id);
r=await get('/share?text=nothing');assert.equal(r.headers.get('location'),'/');
for(const old of ['/api/resolve?id='+id,'/media?u=x','/lab','/engine.js','/api/probe'])assert.equal((await get(old)).status,404,old);
assert.equal((await get('/api/catalog?feed=home')).status,400);
assert.equal((await app.fetch(new Request(origin+'/api/transcript?id='+id,{method:'POST'}))).status,405);
assert.equal((await get('/api/video?id=bad')).status,400);

const originalFetch=globalThis.fetch;
try{
  // oEmbed metadata without the player endpoint.
  globalThis.fetch=async url=>{assert(String(url).startsWith('https://www.youtube.com/oembed?'));return Response.json({title:'<b>Ролик</b>',author_name:'Автор'})};
  assert.deepEqual(await(await get('/api/video?id='+id)).json(),{id,title:'<b>Ролик</b>',channel:'Автор'});

  // ---------- Comments ----------
  const env={GOOGLE_OAUTH_ENABLED:'true',GOOGLE_OAUTH_CLIENT_ID:'123-test.apps.googleusercontent.com',GOOGLE_OAUTH_CLIENT_SECRET:'test-only-secret',GOOGLE_OAUTH_COOKIE_KEY:'01'.repeat(32)};
  const epoch='e'.repeat(43),token='private-access-token';
  const session=await sealAccount(env,'session',{epoch,token,recommendationsAuthorized:true,expires:Date.now()+600000});
  const cookie='__Host-axr-yt-epoch='+epoch+'; __Host-axr-yt-session='+session;
  const call=(path,options={})=>app.fetch(new Request(origin+path,{...options,headers:{cookie,...(options.headers||{})}}),env);
  const thread=(cid,text,replies=[])=>({id:cid,snippet:{totalReplyCount:replies.length+3,canReply:true,topLevelComment:{id:cid,snippet:{authorDisplayName:'@user',authorChannelId:{value:'UCabc'},authorProfileImageUrl:'https://yt3.ggpht.com/a.jpg',textOriginal:text,likeCount:7,publishedAt:'2026-11-15T10:00:00Z',updatedAt:'2026-11-15T10:00:00Z'}}},
    replies:{comments:replies.map(([rid,t])=>({id:rid,snippet:{authorDisplayName:'@other',authorProfileImageUrl:'https://evil.test/x.png',textOriginal:t,likeCount:0,publishedAt:'2026-11-15T11:00:00Z',updatedAt:'2026-11-15T12:00:00Z'}}))}});
  const seen=[];
  globalThis.fetch=async(url,options={})=>{
    const u=new URL(url);seen.push({path:u.pathname,params:Object.fromEntries(u.searchParams),method:options.method,body:options.body&&JSON.parse(options.body),auth:options.headers.authorization});
    if(u.pathname.endsWith('/commentThreads')&&options.method==='GET')return Response.json({items:[thread('UgxThread1','Первый\nкомментарий',[['UgxThread1.r2','второй ответ'],['UgxThread1.r1','первый ответ']])],nextPageToken:'P2'});
    if(u.pathname.endsWith('/videos'))return Response.json({items:[{statistics:{commentCount:'1520'}}]});
    if(u.pathname.endsWith('/comments')&&options.method==='GET')return Response.json({items:[{id:'UgxThread1.r1',snippet:{textOriginal:'ответ',publishedAt:'2026-11-15T11:00:00Z'}}]});
    if(u.pathname.endsWith('/commentThreads')&&options.method==='POST')return Response.json(thread('UgxNew',JSON.parse(options.body).snippet.topLevelComment.snippet.textOriginal));
    if(u.pathname.endsWith('/comments')&&options.method==='POST')return Response.json({id:'UgxThread1.rNew',snippet:{authorDisplayName:'Я',textOriginal:JSON.parse(options.body).snippet.textOriginal,publishedAt:'2026-11-16T12:00:00Z'}});
    return new Response('{}',{status:404});
  };
  r=await call('/api/account/comments?id='+id+'&order=time');assert.equal(r.status,200);let d=await r.json();
  assert.equal(d.total,1520);assert.equal(d.nextPage,'P2');assert.equal(d.items[0].text,'Первый\nкомментарий');assert.equal(d.items[0].replyCount,5);
  assert.deepEqual(d.items[0].replies.map(x=>x.id),['UgxThread1.r1','UgxThread1.r2']);assert.equal(d.items[0].replies[0].avatar,'');assert.equal(d.items[0].replies[0].edited,true);assert.equal(d.items[0].avatar,'https://yt3.ggpht.com/a.jpg');
  assert.equal(seen[0].params.order,'time');assert.equal(seen[0].params.textFormat,'plainText');assert.equal(seen[0].auth,'Bearer '+token);assert(!JSON.stringify(d).includes(token));
  seen.length=0;r=await call('/api/account/comments?id='+id+'&page=P2');d=await r.json();assert.equal(d.total,null);assert.equal(seen.length,1);assert.equal(seen[0].params.pageToken,'P2');assert.equal(seen[0].params.order,'relevance');
  assert.equal((await call('/api/account/comments?id=bad')).status,400);
  assert.equal((await call('/api/account/comments?id='+id+'&page=bad%20token')).status,400);
  r=await call('/api/account/replies?parent=UgxThread1');assert.equal((await r.json()).items[0].parentId,'UgxThread1');
  // Posting requires same-origin POST.
  const post=(body,headers={origin})=>call('/api/account/comment',{method:'POST',headers:{...headers,'content-type':'application/json'},body:JSON.stringify(body)});
  for(const headers of [{},{origin:'https://evil.test'},{origin:'null'},{origin,'sec-fetch-site':'cross-site'}])assert.equal((await post({video:id,text:'x'},headers)).status,403);
  seen.length=0;r=await post({video:id,text:'  Новый комментарий  '});assert.equal(r.status,200);d=await r.json();assert.equal(d.item.id,'UgxNew');assert.equal(d.item.text,'Новый комментарий');
  assert.deepEqual(seen[0].body,{snippet:{videoId:id,topLevelComment:{snippet:{textOriginal:'Новый комментарий'}}}});assert.equal(seen[0].params.part,'snippet');
  seen.length=0;r=await post({parent:'UgxThread1',text:'Ответ'});d=await r.json();assert.equal(d.item.parentId,'UgxThread1');assert.deepEqual(seen[0].body,{snippet:{parentId:'UgxThread1',textOriginal:'Ответ'}});
  for(const bad of [{video:id,text:''},{video:id,text:'x'.repeat(10001)},{video:'bad',text:'x'},{parent:'<script>',text:'x'}])assert.equal((await post(bad)).status,400);
  // Signed-out users get 401, not an empty discussion.
  r=await app.fetch(new Request(origin+'/api/account/comments?id='+id),env);assert.equal(r.status,401);
  // Known Google reasons map to clear messages; provider bodies never leak.
  const fail=(status,reason)=>{globalThis.fetch=async()=>Response.json({error:{errors:[{reason}],message:'secret provider detail'}},{status})};
  fail(403,'commentsDisabled');r=await call('/api/account/comments?id='+id);d=await r.json();assert.equal(d.code,'COMMENTS_DISABLED');assert(!JSON.stringify(d).includes('secret'));
  fail(403,'insufficientPermissions');assert.equal((await(await post({video:id,text:'x'})).json()).code,'COMMENTS_SCOPE');
  fail(403,'quotaExceeded');assert.equal((await call('/api/account/comments?id='+id)).status,429);
  fail(401,'authError');assert.equal((await call('/api/account/comments?id='+id)).status,401);
  assert.equal(cleanThread({}).replyCount,0);
  assert.equal(await commentsResponse('/api/account/other',token,new Request(origin),new URL(origin)),null);

  // ---------- Transcripts ----------
  const vtt='WEBVTT\n\n00:00:00.000 --> 00:00:03.000\nПривет.\n\n00:00:03.000 --> 00:00:06.000\nМир.\n';
  const track=(client,proof)=>({baseUrl:'https://www.youtube.com/api/timedtext?v='+id+'&lang=ru&c='+client+(proof?'&exp=xpe':''),languageCode:'ru',name:{simpleText:'Русский'},kind:'asr'});
  const timed=[];
  globalThis.fetch=async(url,options={})=>{
    const u=String(url);
    if(u.includes('/player')){const c=JSON.parse(options.body).context.client.clientName;
      return Response.json({videoDetails:{videoId:id,title:'T',author:'A',lengthSeconds:'6'},captions:{playerCaptionsTracklistRenderer:{captionTracks:c==='WEB'?[track('WEB',true)]:c==='IOS'?[track('IOS',false),{...track('IOS',false),languageCode:'en',name:{simpleText:'English'},kind:undefined}]:[]}}})}
    if(u.includes('/api/timedtext')){timed.push(new URL(u).searchParams.get('c'));return new Response(vtt)}
    return new Response('',{status:404});
  };
  d=await(await transcriptResponse(new URL(origin+'/api/transcript?id='+id))).json();
  assert.deepEqual(timed,['IOS']);assert.equal(d.source,'youtube-captions');assert.deepEqual(d.languages.map(l=>l.code),['ru','en']);assert.equal(d.languages[0].auto,true);
  // Player bot-check: the watch-panel source answers instead.
  const seg=(s,e,t)=>({transcriptSegmentRenderer:{startMs:String(s),endMs:String(e),snippet:{runs:[{text:t}]}}});
  const panel={actions:[{x:{transcriptSearchPanelRenderer:{body:{initialSegments:[seg(0,2000,'Из панели.'),seg(2000,4000,'Второй сегмент.')]},footer:{transcriptFooterRenderer:{languageMenu:{sortFilterSubMenuRenderer:{subMenuItems:[{title:'Русский',selected:true,continuation:{reloadContinuationData:{continuation:'RU'}}}]}}}}}}}]};
  assert.equal(panelSegments(panel).length,2);assert.deepEqual(panelLanguages(panel),[{name:'Русский',selected:true,params:'RU'}]);
  globalThis.fetch=async(url,options={})=>{
    const u=String(url);
    if(u.includes('/player'))return Response.json({playabilityStatus:{status:'LOGIN_REQUIRED'}});
    if(u.includes('/next'))return Response.json({contents:{videoPrimaryInfoRenderer:{title:{runs:[{text:'Панельный'}]}}},engagementPanels:[{getTranscriptEndpoint:{params:'P'}}]});
    if(u.includes('/get_transcript'))return Response.json(panel);
    return new Response('',{status:404});
  };
  r=await transcriptResponse(new URL(origin+'/api/transcript?id='+id));d=await r.json();
  assert.equal(r.status,200);assert.equal(d.source,'youtube-transcript-panel');assert.equal(d.title,'Панельный');assert.equal(d.sections[0].paragraphs[0].text,'Из панели. Второй сегмент.');
}finally{globalThis.fetch=originalFetch}
console.log('PASS: link parsing, clipboard text, time and counters, CSP shell, share target, legacy routes removed, comments read/reply/post with origin and scope guards, transcript app-client preference, languages and watch-panel fallback');
