import assert from 'node:assert/strict';
import vm from 'node:vm';
import app, {mediaURL, rewriteManifest,hasMP4Header,selectAudioRendition,hlsAttributes,audioMaster} from '../worker/index.js';

const masterBase='https://manifest.googlevideo.com/path/master.m3u8';
const renditions='#EXTM3U\n'+[
  '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="233",LANGUAGE="ar",NAME="Arabic - dubbed-auto",URI="ar.m3u8"',
  '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="233",LANGUAGE="en-US",NAME="English, US - original",URI="en-he.m3u8"',
  '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="234",LANGUAGE="en-US",NAME="English, US - original",URI="en-lc.m3u8"',
  '#EXT-X-STREAM-INF:BANDWIDTH=500000,CODECS="avc1.4d401e,mp4a.40.5",AUDIO="233"',
  'video-he.m3u8',
  '#EXT-X-STREAM-INF:BANDWIDTH=500000,CODECS="avc1.4d401e,mp4a.40.2",AUDIO="234"',
  'video-lc.m3u8'
].join('\n');
assert.equal(hlsAttributes('#EXT-X-MEDIA:NAME="English, US - original",TYPE=AUDIO').NAME,'English, US - original');
const selected=selectAudioRendition(renditions,masterBase);
assert.equal(selected.language,'en-US');assert.equal(selected.codec,'mp4a.40.2');
assert.equal(selected.raw,'https://manifest.googlevideo.com/path/en-lc.m3u8');
const onlyHE=renditions.replace(/#EXT-X-MEDIA:[^\n]*en-lc[^\n]*\n/,'');
assert.equal(selectAudioRendition(onlyHE,masterBase).codec,'mp4a.40.5');
const defaultTrack=renditions.replaceAll(' - original','').replace('NAME="Arabic - dubbed-auto"','DEFAULT=YES,NAME="Arabic - dubbed-auto"');
assert.equal(selectAudioRendition(defaultTrack,masterBase).language,'ar');
assert.throws(()=>selectAudioRendition(renditions.replace('en-lc.m3u8','https://evil.test/a'),masterBase));
assert.throws(()=>audioMaster(selected.raw,'avc1.123'));
const audioPath='https://lab.test/audio-master?u='+encodeURIComponent(selected.raw)+'&codec='+selected.codec;
const masterProbe=await app.fetch(new Request(audioPath,{headers:{Range:'bytes=0-1'}}));
assert.equal(masterProbe.status,206);assert.equal(await masterProbe.text(),'#E');
const audioPlaylist=await (await app.fetch(new Request(audioPath))).text();
assert.match(audioPlaylist,/CODECS="mp4a\.40\.2"/);assert.match(audioPlaylist,/\n\/media\?u=/);

const splitHeader=new ReadableStream({start(c){for(const bytes of [[0,0],[0,24,102],[116],[121,112]])c.enqueue(new Uint8Array(bytes));c.close()}});
assert(await hasMP4Header(splitHeader));
assert(!await hasMP4Header(new Response(new Uint8Array([0,0,0,24,98])).body));

for (const url of ['http://manifest.googlevideo.com/a','https://evil.test/a','https://googlevideo.com.evil.test/a','https://user:pass@manifest.googlevideo.com/a','https://127.0.0.1/a']) assert.throws(()=>mediaURL(url));
assert.equal(mediaURL('https://r1.googlevideo.com/a').hostname,'r1.googlevideo.com');
const rewritten = rewriteManifest('#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,URI="a.m3u8"\nv.m3u8\n', 'https://manifest.googlevideo.com/path/master.m3u8');
assert.match(rewritten,/URI="\/media\?u=/);
assert.match(rewritten,/\n\/media\?u=/);
assert.throws(()=>rewriteManifest('#EXTM3U\nhttps://evil.test/a', 'https://manifest.googlevideo.com/a'));
const html = await (await app.fetch(new Request('https://lab.test/lab'))).text();
for(const script of html.matchAll(/<script>([\s\S]*?)<\/script>/g))new vm.Script(script[1]);
// Execute the shipped handlers against small media-element fakes, not a second algorithm.
const elements=new Map();
function element(id){if(!elements.has(id))elements.set(id,{
  tagName:id==='video'?'VIDEO':'AUDIO',value:'',currentTime:0,paused:true,readyState:1,error:null,loads:0,playbackRate:2,defaultPlaybackRate:2,preservesPitch:false,listeners:{},
  addEventListener(name,fn){(this.listeners[name]??=[]).push(fn)},removeEventListener(name,fn){this.listeners[name]=(this.listeners[name]||[]).filter(item=>item!==fn)},removeAttribute(){this.src=''},load(){this.loads++;this.currentTime=0},
  pause(){this.paused=true},async play(){this.playCalls=(this.playCalls||0)+1;if(this.abortNext){this.abortNext=false;const error=Error('Interrupted by pause');error.name='AbortError';throw error}if(this.rejectNext){this.rejectNext=false;throw Error('NotAllowedError')}this.paused=false},
  canPlayType(){return 'probably'}
});return elements.get(id)}
const script=Array.from(html.matchAll(/<script>([\s\S]*?)<\/script>/g))[0][1];
let requests=0;
const sandbox=vm.createContext({
  document:{getElementById:element,visibilityState:'visible',addEventListener(){}},
  window:{addEventListener(){},location:{href:'https://lab.test/?video=asQM5v36J30&mode=audio'}},navigator:{},URL,Blob,setTimeout,clearTimeout,console,
  fetch:async()=>{requests++;return new Response(JSON.stringify({title:'Video',source:'/media?verified'}),{headers:{'content-type':'application/json'}})}
});
new vm.Script(script).runInContext(sandbox);
assert.equal(element('source').value,'youtube');
assert.equal(element('link').value,'asQM5v36J30');
assert.equal(element('mode').value,'audio');
element('source').value='control';element('mode').value='audio';
await element('play').onclick();const audio=element('offlineAudio');audio.currentTime=42;
assert.equal(audio.playbackRate,1);assert.equal(audio.defaultPlaybackRate,1);assert.equal(audio.preservesPitch,true);
audio.playbackRate=2;for(const fn of audio.listeners.loadedmetadata)fn();
assert.equal(audio.playbackRate,1);
element('pause').onclick();const loads=audio.loads;
await element('play').onclick();assert.equal(audio.currentTime,42);assert.equal(audio.loads,loads);assert.equal(audio.paused,false);
element('source').value='youtube';element('link').value='dQw4w9WgXcQ';audio.rejectNext=true;
await element('play').onclick();assert.equal(requests,1);assert.equal(audio.paused,true);
const youtubeLoads=audio.loads;await element('play').onclick();
assert.equal(requests,1);assert.equal(audio.loads,youtubeLoads);assert.equal(audio.paused,false);
const recorded=vm.runInContext('events',sandbox);
assert(recorded.some(e=>e.event==='button-pause'&&e.source==='control'));
assert(recorded.some(e=>e.event==='source-ready'&&e.source==='youtube'&&e.mode==='audio'));
assert(recorded.every(e=>!JSON.stringify(e).includes('/media?')));
// A failed resolver must retain its status and safe reason, not only start-failed.
sandbox.fetch=async()=>new Response(JSON.stringify({error:'failure https://private.test/?token=hidden',diagnostics:[{code:'PLAYER_HTTP_403'},{code:'https://private.test/?token=hidden'}]}),{status:502,headers:{'content-type':'application/json'}});
element('link').value='F1PEICLlEBk';await element('play').onclick();
const failed=vm.runInContext('events.at(-1)',sandbox);
assert.equal(failed.event,'start-failed');assert.equal(failed.failure.httpStatus,502);
assert.equal(failed.failure.codes.length,1);assert.equal(failed.failure.codes[0],'PLAYER_HTTP_403');
assert(!JSON.stringify(failed).includes('hidden'));
assert(!element('status').textContent.includes('private.test'));
// Only transient server access failures get one retry, never an endless loop.
let retryCalls=0;sandbox.fetch=async()=>{
  retryCalls++;return retryCalls===1
    ?new Response(JSON.stringify({diagnostics:[{code:'PLAYER_LOGIN_REQUIRED'},{code:'PLAYER_HTTP_403'}]}),{status:502})
    :new Response(JSON.stringify({title:'Recovered',kind:'hls',source:'/media?recovered'}));
};
element('link').value='xFrGuyw1V8s';await element('play').onclick();
assert.equal(retryCalls,2);assert.equal(audio.src,'/media?recovered');
assert.equal(vm.runInContext('context.videoId',sandbox),'xFrGuyw1V8s');
assert.equal(vm.runInContext('context.failure',sandbox),undefined);
assert(vm.runInContext("events.some(e=>e.event==='resolve-retry-result')",sandbox));
// Android v31 report: NO_HLS from IOS plus HTTP403 from VISIONOS was not retried.
retryCalls=0;sandbox.fetch=async()=>{retryCalls++;return retryCalls===1?Response.json({diagnostics:[{code:'NO_HLS'},{code:'PLAYER_HTTP_403'}]},{status:502}):Response.json({title:'Mixed retry recovered',kind:'hls',source:'/media?mixed-recovered'})};
element('link').value='eeeeeeeeeee';await element('play').onclick();assert.equal(retryCalls,2);assert.equal(audio.src,'/media?mixed-recovered');
retryCalls=0;sandbox.fetch=async()=>{retryCalls++;return Response.json({diagnostics:[{code:'NO_HLS'},{code:'NO_HLS'}]},{status:502})};
element('link').value='fffffffffff';await element('play').onclick();assert.equal(retryCalls,1);
retryCalls=0;sandbox.fetch=async()=>{retryCalls++;return new Response(JSON.stringify({diagnostics:[{code:'PLAYER_LOGIN_REQUIRED'}]}),{status:502})};
element('link').value='abcdefghijk';await element('play').onclick();assert.equal(retryCalls,2);
assert(element('status').textContent.includes('Это не запрос входа'));
assert(!element('status').textContent.includes('PLAYER_LOGIN_REQUIRED'));assert.equal(audio.paused,true);
retryCalls=0;sandbox.fetch=async()=>{retryCalls++;return new Response(JSON.stringify({diagnostics:[{code:'PLAYER_UNPLAYABLE'}]}),{status:502})};
element('link').value='lmnopqrstuv';await element('play').onclick();assert.equal(retryCalls,1);
// Closing a pending startup must not attach the stale response afterwards.
let finishResolve;sandbox.fetch=()=>new Promise(resolve=>{finishResolve=resolve});
element('link').value='asQM5v36J30';const pendingStart=element('play').onclick();
vm.runInContext('++playGeneration;reset();busy=false',sandbox);
finishResolve(new Response(JSON.stringify({title:'Late response',source:'/media?stale',kind:'hls'})));
await pendingStart;assert.equal(audio.src,'');assert.equal(element('video').src,'');
assert(!html.includes('<iframe'));
// Chromium/MSE: play must wait until the manifest has been parsed. Safari's
// native HLS branch above remains unchanged. Close cancels an unfinished start.
class FakeHls{
 static Events={ERROR:'error',MANIFEST_PARSED:'parsed'};static isSupported(){return true}
 constructor(){this.handlers=new Map();FakeHls.latest=this}
 on(event,fn){if(!this.handlers.has(event))this.handlers.set(event,new Set());this.handlers.get(event).add(fn)}
 off(event,fn){this.handlers.get(event)?.delete(fn)}
 emit(event,data){for(const fn of this.handlers.get(event)||[])fn(event,data)}
 loadSource(source){this.source=source}attachMedia(media){this.media=media}destroy(){this.destroyed=true}
}
sandbox.Hls=FakeHls;sandbox.window.Hls=FakeHls;
// Android Chrome may advertise native HLS too. Prefer the explicit MSE path.
sandbox.navigator.userAgent='Mozilla/5.0 (Linux; Android 10; K) Chrome/155.0.0.0 Mobile Safari/537.36';
for(const m of [audio,element('video')])m.canPlayType=()=>'probably';
sandbox.fetch=async()=>Response.json({title:'Chrome test',kind:'hls',source:'/media?chrome'});
for(const mode of ['audio','video']){
 element('source').value='youtube';element('mode').value=mode;element('link').value=mode==='audio'?'aaaaaaaaaaa':'bbbbbbbbbbb';
 const starting=element('play').onclick();await new Promise(resolve=>setImmediate(resolve));
 const instance=FakeHls.latest;assert(instance.media.paused);assert.equal(vm.runInContext('busy',sandbox),true);
 instance.emit('parsed');await starting;assert.equal(instance.media.paused,false);assert.equal(vm.runInContext('busy',sandbox),false);
 assert.equal(vm.runInContext('context.transport',sandbox),'mse-hls');
}
// Exact report ordering: metadata arrives after pipeline setup. Do not call
// play while readyState=0. Then a non-user AbortError gets one same-source retry.
element('mode').value='video';element('link').value='eeeeeeeeeee';const video=element('video');video.readyState=0;const playCalls=video.playCalls||0;
const preparing=element('play').onclick();await new Promise(resolve=>setImmediate(resolve));FakeHls.latest.emit('parsed');await new Promise(resolve=>setImmediate(resolve));assert.equal(video.playCalls||0,playCalls);assert.equal(vm.runInContext('busy',sandbox),true);
video.abortNext=true;video.readyState=4;for(const listener of [...video.listeners.loadedmetadata])listener();await preparing;assert.equal(video.playCalls,playCalls+2);assert.equal(video.paused,false);assert(vm.runInContext("events.some(e=>e.event==='startup-play-retry')",sandbox));
// Explicit pause during startup must never be overridden by the retry policy.
element('link').value='fffffffffff';const pausedCalls=video.playCalls;const pausing=element('play').onclick();await new Promise(resolve=>setImmediate(resolve));element('pause').onclick();FakeHls.latest.emit('parsed');await pausing;assert.equal(video.playCalls,pausedCalls);assert.equal(video.paused,true);
// Keep the proven Apple native-HLS branch: no MSE attach or metadata delay.
sandbox.navigator.vendor='Apple Computer, Inc.';const previousInstance=FakeHls.latest;video.readyState=0;element('link').value='ggggggggggg';await element('play').onclick();assert.equal(FakeHls.latest,previousInstance);assert.equal(vm.runInContext('context.transport',sandbox),'native-hls');assert.equal(video.paused,false);sandbox.navigator.vendor='';video.readyState=1;
element('link').value='ccccccccccc';const cancelled=element('play').onclick();await new Promise(resolve=>setImmediate(resolve));
const abandoned=FakeHls.latest;vm.runInContext('++playGeneration;reset();busy=false',sandbox);await cancelled;assert(abandoned.destroyed);assert(abandoned.media.paused);
element('link').value='ddddddddddd';const fatal=element('play').onclick();await new Promise(resolve=>setImmediate(resolve));FakeHls.latest.emit('error',{fatal:true,type:'networkError'});await fatal;assert.equal(vm.runInContext('busy',sandbox),false);assert(element('status').textContent.includes('HLS: networkError'));
assert.equal((await app.fetch(new Request('https://lab.test/api/resolve?id=bad'))).status,400);
assert.equal((await app.fetch(new Request('https://lab.test/media?u=https://localhost/a'))).status,400);
assert.equal((await app.fetch(new Request('https://lab.test/',{method:'POST'}))).status,405);
const manifest=await (await app.fetch(new Request('https://lab.test/manifest.webmanifest'))).json();
assert.equal(manifest.display,'standalone');
assert.equal((await app.fetch(new Request('https://lab.test/api/resolve',{method:'POST',headers:{origin:'https://evil.test'},body:'{}'}))).status,403);
const proofPage=await app.fetch(new Request('https://lab.test/phone-proof'));
assert.equal(proofPage.headers.get('content-security-policy'),'sandbox allow-scripts');
const proofHTML=await proofPage.text();
new vm.Script('(async()=>{'+proofHTML.replace(/import .*?;\n/g,'').match(/<script type="module">([\s\S]*?)<\/script>/)[1]+'})()');
const oldFetch=globalThis.fetch;
let rangeReceived=false;
try {
  // Emulate workerd: redirect:error must fail before making any request.
  globalThis.fetch=async(url,options)=>{
    if(options.redirect==='error')throw new TypeError('Invalid redirect value');
    assert.equal(options.redirect,'manual');
    assert.equal(String(url),'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3');
    assert.equal(options.headers.Range,'bytes=0-1');
    return new Response(new Uint8Array([0x49,0x44]),{status:206,headers:{'content-type':'audio/mpeg','content-length':'2','content-range':'bytes 0-1/8945229','accept-ranges':'bytes'}});
  };
  const control=await app.fetch(new Request('https://lab.test/control.mp3',{headers:{range:'bytes=0-1'}}));
  assert.equal(control.status,206);
  assert.equal(control.headers.get('content-type'),'audio/mpeg');
  assert.equal(control.headers.get('content-range'),'bytes 0-1/8945229');
  assert.equal((await control.arrayBuffer()).byteLength,2);
  globalThis.fetch=async()=>new Response(null,{status:302,headers:{location:'https://evil.test/a'}});
  assert.equal((await app.fetch(new Request('https://lab.test/control.mp3'))).status,502);
  globalThis.fetch=async()=>new Response('<html>not audio</html>',{headers:{'content-type':'text/html'}});
  assert.equal((await app.fetch(new Request('https://lab.test/control.mp3'))).status,502);
  // Real failure class: a completed broadcast returns direct AAC, no HLS.
  let claimedID='asQM5v36J30';
  globalThis.fetch=async(url)=>String(url).includes('youtubei/v1/player')
    ? new Response(JSON.stringify({playabilityStatus:{status:'OK'},videoDetails:{videoId:claimedID,title:'Broadcast archive'},streamingData:{adaptiveFormats:[{mimeType:'audio/mp4; codecs="mp4a.40.2"',bitrate:128000,url:'https://r1.googlevideo.com/audio'}]}}))
    : new Response(new Uint8Array([0,0,0,24,102,116,121,112,100,97,115,104]),{status:206,headers:{'content-type':'audio/mp4'}});
  const archive=await app.fetch(new Request('https://lab.test/api/resolve?id=asQM5v36J30&mode=audio'));
  assert.equal(archive.status,200);const archiveData=await archive.json();
  assert.equal(archiveData.kind,'file');assert(archiveData.source.startsWith('/media?'));
  claimedID='wrong-video';
  assert.equal((await app.fetch(new Request('https://lab.test/api/resolve?id=asQM5v36J30&mode=audio'))).status,502);
  claimedID='asQM5v36J30';
  assert.equal((await app.fetch(new Request('https://lab.test/api/resolve?id=asQM5v36J30&mode=video'))).status,502);
  globalThis.fetch=async()=>new Response(JSON.stringify({playabilityStatus:{status:'LOGIN_REQUIRED'}}));
  const denied=await (await app.fetch(new Request('https://lab.test/api/resolve?id=asQM5v36J30&mode=audio'))).json();
  assert(denied.diagnostics.every(a=>a.code==='PLAYER_LOGIN_REQUIRED'));
  assert(!JSON.stringify(denied).includes('https://'));
  // A 16-byte probe can pass while Safari's actual open-ended request is forbidden.
  globalThis.fetch=async(url,options)=>{
    if(String(url).includes('youtubei/v1/player'))return new Response(JSON.stringify({playabilityStatus:{status:'OK'},videoDetails:{videoId:'F1PEICLlEBk'},streamingData:{adaptiveFormats:[{mimeType:'audio/mp4',url:'https://r1.googlevideo.com/audio'}]}}));
    assert.equal(options.headers.Range,'bytes=0-');
    return new Response(null,{status:403});
  };
  const forbidden=await (await app.fetch(new Request('https://lab.test/api/resolve?id=F1PEICLlEBk&mode=audio'))).json();
  assert(forbidden.diagnostics.every(a=>a.code==='AUDIO_HTTP_403'));
  // Cold visitor handshake and headers must match; prefer HLS over fast iOS MP4.
  const attempts=[];let directProbes=0;
  globalThis.fetch=async(url,options)=>{
    if(!String(url).includes('youtubei/v1/player')){
      directProbes++;throw Error('Premature direct audio probe');
    }
    const body=JSON.parse(options.body);const client=body.context.client;
    attempts.push(client.clientName);
    assert.equal(options.headers.origin,'https://www.youtube.com');
    assert.equal(options.headers['x-youtube-client-version'],client.clientVersion);
    assert.equal(body.playbackContext.contentPlaybackContext.html5Preference,'HTML5_PREF_WANTS');
    if(client.clientName==='IOS')return new Response(JSON.stringify({playabilityStatus:{status:'OK'},videoDetails:{videoId:'F1PEICLlEBk'},streamingData:{adaptiveFormats:[{mimeType:'audio/mp4',url:'https://r1.googlevideo.com/audio'}]}}));
    assert.equal(options.headers['x-youtube-client-name'],'101');
    if(!client.visitorData)return new Response(JSON.stringify({playabilityStatus:{status:'LOGIN_REQUIRED'},responseContext:{visitorData:'anonymous-test-visitor'}}));
    assert.equal(client.visitorData,'anonymous-test-visitor');
    assert.equal(options.headers['x-goog-visitor-id'],client.visitorData);
    return new Response(JSON.stringify({playabilityStatus:{status:'OK'},videoDetails:{videoId:'F1PEICLlEBk'},streamingData:{hlsManifestUrl:'https://manifest.googlevideo.com/api/manifest/hls/master.m3u8'}}));
  };
  const recovered=await (await app.fetch(new Request('https://lab.test/api/resolve?id=F1PEICLlEBk&mode=video'))).json();
  assert.equal(recovered.kind,'hls');assert.equal(directProbes,0);
  assert.equal(attempts.filter(c=>c==='VISIONOS').length,2);
  let deniedCalls=0;
  globalThis.fetch=async()=>{deniedCalls++;return new Response(JSON.stringify({playabilityStatus:{status:'LOGIN_REQUIRED'},responseContext:{visitorData:'anonymous-test-visitor'}}))};
  assert.equal((await app.fetch(new Request('https://lab.test/api/resolve?id=F1PEICLlEBk&mode=audio'))).status,502);
  assert.equal(deniedCalls,6); // Two primary clients plus ANDROID_VR fallback, at most one seeded retry each.
  let protectedProbes=0;
  globalThis.fetch=async(url,options)=>{
    if(!String(url).includes('youtubei/v1/player')){protectedProbes++;throw Error('Known proof-required URL must not be offered')}
    const client=JSON.parse(options.body).context.client;
    return new Response(JSON.stringify(client.clientName==='IOS'
      ?{playabilityStatus:{status:'OK'},videoDetails:{videoId:'F1PEICLlEBk'},streamingData:{adaptiveFormats:[{mimeType:'audio/mp4',url:'https://r1.googlevideo.com/audio?rqh=1'}]}}
      :{playabilityStatus:{status:'LOGIN_REQUIRED'}}));
  };
  const protectedResult=await (await app.fetch(new Request('https://lab.test/api/resolve?id=F1PEICLlEBk&mode=audio'))).json();
  assert(protectedResult.diagnostics.some(a=>a.code==='PO_TOKEN_REQUIRED'));
  assert.equal(protectedProbes,0);
  // Safari probes two bytes before asking for the complete rewritten playlist.
  const playlist='#EXTM3U\n#EXTINF:5,\nhttps://r1.googlevideo.com/segment\n';
  let manifestReads=0;
  globalThis.fetch=async(url,options)=>{
    assert(!options.headers.Range,'Never range-fetch a playlist before rewriting it');
    manifestReads++;return new Response(playlist,{headers:{'content-type':'application/vnd.apple.mpegurl'}});
  };
  const playlistURL='https://lab.test/media?u='+encodeURIComponent('https://manifest.googlevideo.com/api/manifest/hls/playlist');
  const sniff=await app.fetch(new Request(playlistURL,{headers:{range:'bytes=0-1'}}));
  assert.equal(sniff.status,206);assert.equal(sniff.headers.get('content-length'),'2');
  assert.equal(await sniff.text(),'#E');
  const length=Number(sniff.headers.get('content-range').split('/')[1]);
  const full=await app.fetch(new Request(playlistURL,{headers:{range:'bytes=0-'+(length-1)}}));
  const fullBytes=new Uint8Array(await full.arrayBuffer());
  assert.equal(full.status,206);assert.equal(fullBytes.length,length);
  assert(new TextDecoder().decode(fullBytes).includes('/media?u='));
  assert.equal((await app.fetch(new Request(playlistURL,{headers:{range:'bytes='+length+'-'}}))).status,416);
  const head=await app.fetch(new Request(playlistURL,{method:'HEAD',headers:{range:'bytes=0-1'}}));
  assert.equal(head.status,206);assert.equal((await head.arrayBuffer()).byteLength,0);
  assert.equal(manifestReads,4);
  globalThis.fetch=async(url,options)=>{rangeReceived=options.headers.Range==='bytes=0-99';return new Response('media',{status:206,headers:{'content-type':'video/mp4','content-range':'bytes 0-99/1000'}})};
  const r=await app.fetch(new Request('https://lab.test/media?u=https://r1.googlevideo.com/v',{headers:{range:'bytes=0-99'}}));
  assert.equal(r.status,206);assert.equal(r.headers.get('content-range'),'bytes 0-99/1000');assert(rangeReceived);
  globalThis.fetch=async()=>new Response(null,{status:302,headers:{location:'https://127.0.0.1/private'}});
  assert.equal((await app.fetch(new Request('https://lab.test/media?u=https://r1.googlevideo.com/v'))).status,400);
} finally {globalThis.fetch=oldFetch}
console.log('PASS: host/redirect boundaries, HLS rewriting, HTML script syntax, manifest, HTTP methods, range forwarding; no iframe.');
