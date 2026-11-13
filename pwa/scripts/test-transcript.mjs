import assert from 'node:assert/strict';
import {captionText,parseCaptionVTT,transcriptDocument,safeCaptionURL,transcriptResponse} from '../worker/transcript.js';
import {transcriptExport,transcriptTimestamp,createTranscriptUI} from '../worker/transcript-ui.js';
import {languageRows} from '../worker/i18n.js';
const id='abcdefghijk';
const vtt='WEBVTT\n\n00:00:00.000 --> 00:00:03.000\nHello &amp; welcome.\n\n00:00:03.000 --> 00:00:06.000\nwelcome. This is complete.\n\n00:05:01.000 --> 00:05:04.000\nFinal words &#x1F44B;.\n';
const cues=parseCaptionVTT(vtt);assert.equal(cues.length,3);assert.equal(cues[0].text,'Hello & welcome.');assert(cues[2].text.includes('👋'));
const sections=transcriptDocument(cues);assert.equal(sections.length,2);assert.equal(sections[0].paragraphs[0].text,'Hello & welcome. This is complete.');assert(sections[1].paragraphs[0].text.startsWith('Final words'));
assert.equal(captionText('<b>safe</b> &lt;script&gt; &#39;'),'safe <script> \'');
assert.throws(()=>parseCaptionVTT('<html>captcha</html>'));
const rollup=parseCaptionVTT('WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nold line\n<00:00:00.100>new words\n\n00:00:01.000 --> 00:00:01.010\nnew words\n');assert.equal(rollup.length,1);assert.equal(rollup[0].text,'new words');
assert.equal(transcriptTimestamp(3661),'1:01:01');assert.equal(safeCaptionURL('https://www.youtube.com/api/timedtext?v='+id,id).searchParams.get('fmt'),'vtt');
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
const document={id,title:'Video',channel:'Channel',duration:304,generatedAt:'2026-11-10T00:00:00Z',language:'ru',languageName:'Русский',sections};
const full=transcriptExport(document);assert(full.includes('00:00  Hello & welcome. This is complete.'));assert(full.includes('05:01  Final words 👋.'));assert(full.endsWith('https://www.youtube.com/watch?v='+id+'\n'));
const huge={...document,sections:[{start:0,paragraphs:Array.from({length:10000},(_,i)=>({start:i,text:i===9999?'LAST_SENTINEL':'Words '+i}))}]};assert(transcriptExport(huge).includes('LAST_SENTINEL'));assert(transcriptExport({...document,title:'<script>'},x=>x,true).includes('\\<script\\>'));
function element(tag){return {tag,children:[],dataset:{},attrs:{},className:'',append(...children){this.children.push(...children)},prepend(...children){this.children.unshift(...children)},replaceChildren(...children){this.children=children},setAttribute(k,v){this.attrs[k]=v},addEventListener(){},showModal(){},close(){},remove(){this.removed=true},focus(){},select(){this.selected=true}}}
const body=element('body'),doc={body,createElement:element,activeElement:{focus(){}}};let copied='';const win={navigator:{clipboard:{writeText:async value=>{copied=value}}},fetch:async()=>Response.json({...document,complete:true}),URL, setTimeout};
const ui=createTranscriptUI({doc,win,t:x=>x,language:()=> 'ru'});await ui.open({id});let dialog=body.children.at(-1);const copy=dialog.children[1].children[0];await copy.onclick();assert.equal(copied,full);assert.equal(copy.textContent,'Скопировано');ui.close();assert.equal(dialog.removed,true);
// An old request cannot populate a panel opened for another video.
let release;win.fetch=()=>new Promise(resolve=>release=resolve);const pending=ui.open({id:'lmnopqrstuv'});ui.close();release(Response.json({...document,id:'lmnopqrstuv',complete:true}));await pending;assert.equal(body.children.at(-1).removed,true);
const dictionary=new Set(languageRows.map(row=>row[0]));for(const text of ['Стенограмма','Копировать всё','Скопировано','Сохранить Markdown','Создано'])assert(dictionary.has(text));
console.log('PASS: full captions, ASR roll-up cleanup, iOS paragraph/section policy, safe timedtext URLs, no token leakage, unavailable/error distinction, full export tail, copy-all payload and stale-panel cancellation');
