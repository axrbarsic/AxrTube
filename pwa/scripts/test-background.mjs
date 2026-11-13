import assert from 'node:assert/strict';
import {createBackgroundPlayback} from '../worker/background-playback.js';
function target(properties={}){
  const listeners=new Map();return {...properties,addEventListener(name,fn){if(!listeners.has(name))listeners.set(name,[]);listeners.get(name).push(fn)},emit(name){for(const fn of listeners.get(name)||[])fn()}};
}
function fixture({audioSession=true,android=false,standalone=false}={}){
  let clock=1000,timerId=0;const timers=new Map();const document=target({visibilityState:'visible'});
  const media=target({paused:false,ended:false,error:null,muted:false,volume:1,calls:0,currentTime:42,src:'unchanged',play(){this.calls++;this.paused=false;return this.reject?Promise.reject(Error('NotAllowedError')):Promise.resolve()}});
  const navigator={standalone,userAgent:android?'Mozilla/5.0 (Linux; Android 10; K) Chrome/155.0.0.0 Mobile Safari/537.36':'',mediaSession:{playbackState:'none'},...(audioSession?{audioSession:target({type:'auto',state:'active'})}:{})};
  const logs=[];const controller=createBackgroundPlayback({document,navigator,elements:[media],getMedia:()=>media,log:event=>logs.push(event),now:()=>clock,setTimer:(fn,delay)=>{const id=++timerId;timers.set(id,{fn,at:clock+delay});return id},clearTimer:id=>timers.delete(id)});
  return {controller,document,navigator,media,logs,advance(ms){clock+=ms;for(const [id,timer]of [...timers])if(timer.at<=clock){timers.delete(id);timer.fn()}},hide(){document.visibilityState='hidden';document.emit('visibilitychange')},pause(){media.paused=true;media.emit('pause')},start(){controller.userPlay();media.paused=false;media.emit('playing')}};
}
const flush=()=>new Promise(resolve=>queueMicrotask(resolve));
// A real hidden-transition pause gets one synchronous play(), same source/time.
let f=fixture();f.start();assert.equal(f.navigator.audioSession.type,'playback');f.hide();f.pause();
assert.equal(f.media.calls,1);assert.equal(f.media.src,'unchanged');assert.equal(f.media.currentTime,42);await flush();assert(f.logs.includes('background-resume-accepted'));
f.pause();assert.equal(f.media.calls,1);
// No gratuitous play call when background playback continues normally.
f=fixture();f.start();f.hide();assert.equal(f.media.calls,0);
// Manual app or Lock Screen pause revokes intent before pause is dispatched.
f=fixture();f.start();f.hide();f.controller.userPause();f.pause();assert.equal(f.media.calls,0);assert.equal(f.navigator.mediaSession.playbackState,'paused');
// Reproduce BOTH measured iPhone sequences, including partial Audio Session API.
for(const delta of [139,171]){
  f=fixture();delete f.navigator.audioSession.state;f.start();f.pause();
  assert.equal(f.media.calls,0);f.advance(delta);f.hide();assert.equal(f.media.calls,1);
  assert.equal(f.media.currentTime,42);assert.equal(f.media.src,'unchanged');
  assert(f.logs.includes('background-pause-before-hidden'));f.pause();assert.equal(f.media.calls,1);
}
// Visible native pause with observed user input followed by hide is respected.
for(const input of ['pointerdown','touchstart','keydown']){
  f=fixture();f.start();f.media.emit(input);f.pause();f.advance(139);f.hide();assert.equal(f.media.calls,0);
}
// Explicit app/remote pause during the pending window revokes the candidate.
f=fixture();f.start();f.pause();f.controller.userPause();f.advance(171);f.hide();assert.equal(f.media.calls,0);
// Older/uncorrelated visible pauses and closed sources never resume.
f=fixture();f.start();f.pause();f.advance(401);f.hide();assert.equal(f.media.calls,0);
f=fixture();f.start();f.pause();f.controller.reset();f.advance(139);f.hide();assert.equal(f.media.calls,0);
f=fixture();f.start();f.pause();f.navigator.audioSession.state='interrupted';f.navigator.audioSession.emit('statechange');f.advance(139);f.hide();assert.equal(f.media.calls,0);
// A pointer interaction with native controls is not a background suspension.
f=fixture();f.start();f.hide();f.media.emit('pointerdown');f.pause();assert.equal(f.media.calls,0);
// No retries on long-hidden pages, source reset, media errors or end-of-stream.
for(const revoke of [f=>f.advance(2100),f=>f.controller.reset(),f=>{f.media.ended=true},f=>{f.media.error={code:2}},f=>{f.media.muted=true},f=>{f.media.volume=0}]){
  f=fixture();f.start();f.hide();revoke(f);f.pause();assert.equal(f.media.calls,0);
}
// Do not fight an incoming call or another exclusive audio session.
f=fixture();f.start();f.hide();f.navigator.audioSession.state='interrupted';f.navigator.audioSession.emit('statechange');f.pause();assert.equal(f.media.calls,0);
// A rejected resume is logged, never retried in a loop.
f=fixture();f.start();f.hide();f.media.reject=true;f.pause();await flush();assert(f.logs.includes('background-resume-blocked'));f.pause();assert.equal(f.media.calls,1);
// Returning to the foreground does not auto-start a paused player.
f=fixture();f.start();f.hide();f.document.visibilityState='visible';f.document.emit('visibilitychange');f.pause();assert.equal(f.media.calls,0);
// Unsupported/throwing Audio Session API does not break the player.
f=fixture({audioSession:false});f.start();f.hide();f.pause();assert.equal(f.media.calls,1);
f=fixture();Object.defineProperty(f.navigator.audioSession,'type',{set(){throw Error('Unsupported')}});assert.doesNotThrow(()=>f.start());
f=fixture();f.start();f.hide();f.controller.stop();f.pause();assert.equal(f.media.calls,0);assert.equal(f.navigator.audioSession.type,'auto');
console.log('PASS: one-shot background recovery, same source/time, explicit/native/remote pause, interruptions, close/reset/end, unsupported API and blocked play');
// Actual Android v32 sequence: hidden, Pause, accepted Play, 31ms, Pause.
f=fixture({android:true,audioSession:false});f.start();f.hide();f.pause();f.media.emit('playing');await flush();f.advance(31);f.pause();assert.equal(f.media.calls,1);assert(f.logs.includes('background-followup-scheduled'));f.advance(119);assert.equal(f.media.calls,1);f.advance(1);assert.equal(f.media.calls,2);assert.equal(f.media.currentTime,42);assert.equal(f.media.src,'unchanged');await flush();assert(f.logs.includes('background-followup-accepted'));f.pause();f.advance(1000);assert.equal(f.media.calls,2);
// Every explicit cancellation and incompatible state wins over a pending timer.
for(const revoke of [f=>f.controller.userPause(),f=>f.controller.reset(),f=>f.controller.stop(),f=>f.media.emit('pointerdown'),f=>{f.document.visibilityState='visible';f.document.emit('visibilitychange')},f=>{f.media.ended=true},f=>{f.media.error={code:2}},f=>{f.media.muted=true},f=>{f.media.volume=0},f=>{f.navigator.audioSession.state='interrupted';f.navigator.audioSession.emit('statechange')}]){
 f=fixture({android:true});f.start();f.hide();f.pause();await flush();f.advance(31);f.pause();revoke(f);f.advance(120);assert.equal(f.media.calls,1);
}
f=fixture({android:true});f.start();f.hide();f.pause();await flush();f.advance(251);f.pause();f.advance(120);assert.equal(f.media.calls,1);
f=fixture({android:true});f.start();f.hide();f.pause();await flush();f.advance(31);f.pause();f.media.reject=true;f.advance(120);await flush();assert(f.logs.includes('background-followup-blocked'));f.pause();f.advance(1000);assert.equal(f.media.calls,2);
console.log('PASS: Android double-pause report replay, single delayed followup, all cancellation paths, 250ms correlation, fixed source/time and hard two-attempt ceiling');
// Regression-isolation candidate: installed iOS returns to the pre-v15 automatic
// Audio Session policy, but retains custom MediaSession controls and recovery.
f=fixture({standalone:true});const writes=[];let audioType='playback';Object.defineProperty(f.navigator.audioSession,'type',{get:()=>audioType,set:value=>{writes.push(value);audioType=value}});f.start();assert.equal(audioType,'auto');assert.deepEqual(writes,['auto']);assert(f.logs.includes('audio-session-browser-owned'));f.hide();f.pause();await flush();assert.equal(f.media.calls,1);assert.equal(f.media.src,'unchanged');assert.equal(f.media.currentTime,42);assert.equal(audioType,'auto');f.controller.userPause();f.pause();assert.equal(f.media.calls,1);f.controller.stop();assert(writes.every(type=>type==='auto'));
f=fixture({standalone:true,audioSession:false});f.start();f.hide();f.pause();assert.equal(f.media.calls,1);
console.log('PASS: installed iOS automatic Audio Session policy, stale override release, unchanged source/time/recovery, explicit pause and missing API');
