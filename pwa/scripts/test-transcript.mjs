import assert from 'node:assert/strict';
import {captionText,parseCaptionVTT,transcriptDocument,safeCaptionURL,transcriptResponse} from '../worker/transcript.js';
import {formatClock} from '../worker/app-client.js';
const id='abcdefghijk';
const vtt='WEBVTT\n\n00:00:00.000 --> 00:00:03.000\nHello &amp; welcome.\n\n00:00:03.000 --> 00:00:06.000\nwelcome. This is complete.\n\n00:05:01.000 --> 00:05:04.000\nFinal words &#x1F44B;.\n';
const cues=parseCaptionVTT(vtt);assert.equal(cues.length,3);assert.equal(cues[0].text,'Hello & welcome.');assert(cues[2].text.includes('👋'));
const sections=transcriptDocument(cues);assert.equal(sections.length,2);assert.equal(sections[0].paragraphs[0].text,'Hello & welcome. This is complete.');assert(sections[1].paragraphs[0].text.startsWith('Final words'));
assert.equal(captionText('<b>safe</b> &lt;script&gt; &#39;'),'safe <script> \'');
assert.throws(()=>parseCaptionVTT('<html>captcha</html>'));
const rollup=parseCaptionVTT('WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nold line\n<00:00:00.100>new words\n\n00:00:01.000 --> 00:00:01.010\nnew words\n');assert.equal(rollup.length,1);assert.equal(rollup[0].text,'new words');
assert.equal(formatClock(3661),'1:01:01');assert.equal(safeCaptionURL('https://www.youtube.com/api/timedtext?v='+id,id).searchParams.get('fmt'),'vtt');
for(const url of ['http://www.youtube.com/api/timedtext?v='+id,'https://evil.test/api/timedtext?v='+id,'https://www.youtube.com/redirect?v='+id,'https://www.youtube.com/api/timedtext?v=other','https://user:secret@www.youtube.com/api/timedtext?v='+id])assert.throws(()=>safeCaptionURL(url,id));
const originalFetch=globalThis.fetch;let captionError=false,noTracks=false,fetches=0;
try{
  globalThis.fetch=async(url,options)=>{fetches++;assert(!options.headers.authorization);assert(!options.headers.cookie);
    if(String(url).includes('/youtubei/'))return Response.json({videoDetails:{videoId:id,title:'<b>Untrusted title</b>',author:'Channel',lengthSeconds:'304'},captions:{playerCaptionsTracklistRenderer:{captionTracks:noTracks?[]:[{baseUrl:'https://www.youtube.com/api/timedtext?v='+id,languageCode:'ru',name:{simpleText:'Русский'}}]}}});
    assert.equal(new URL(url).hostname,'www.youtube.com');assert.equal(new URL(url).pathname,'/api/timedtext');return captionError?new Response('',{status:403}):new Response(vtt);
  };
  const response=await transcriptResponse(new URL('https://lab.test/api/transcript?id='+id));const d=await response.json();assert.equal(response.status,200);assert.equal(response.headers.get('cache-control'),'no-store');assert.equal(d.complete,true);assert.equal(d.id,id);assert.equal(d.sections.length,2);assert(!JSON.stringify(d).includes('baseUrl'));
  captionError=true;assert.equal((await transcriptResponse(new URL('https://lab.test/api/transcript?id='+id))).status,502);captionError=false;noTracks=true;assert.equal((await transcriptResponse(new URL('https://lab.test/api/transcript?id='+id))).status,404);
  fetches=0;assert.equal((await transcriptResponse(new URL('https://lab.test/api/transcript?id=bad'))).status,400);assert.equal(fetches,0);
}finally{globalThis.fetch=originalFetch}
console.log('PASS: full captions, ASR roll-up cleanup, paragraph/section policy, safe timedtext URLs, no token leakage and unavailable/error distinction');
