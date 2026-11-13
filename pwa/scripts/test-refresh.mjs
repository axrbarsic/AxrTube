import assert from 'node:assert/strict';
import vm from 'node:vm';
import {installPullRefresh,appClient} from '../worker/app-client.js';
const events=new Map();let refreshes=0,allowed=true;
const indicator={style:{},setAttribute(){}};
const doc={createElement:()=>indicator,body:{append(){}},addEventListener:(event,fn)=>events.set(event,fn)};
const win={scrollY:0};installPullRefresh(win,doc,()=>allowed,async()=>{refreshes++});
function touch(x,y){return {touches:[{clientX:x,clientY:y}],target:{closest:()=>null},cancelable:true,preventDefault(){this.prevented=true}}}
events.get('touchstart')(touch(0,0));events.get('touchmove')(touch(1,50));await events.get('touchend')(touch(1,50));assert.equal(refreshes,0);
events.get('touchstart')(touch(0,0));const move=touch(1,100);events.get('touchmove')(move);assert.equal(move.prevented,true);await events.get('touchend')(touch(1,100));assert.equal(refreshes,1);assert.equal(indicator.hidden,true);
events.get('touchstart')(touch(0,0));events.get('touchmove')(touch(100,20));await events.get('touchend')(touch(100,20));assert.equal(refreshes,1);
win.scrollY=50;events.get('touchstart')(touch(0,0));events.get('touchmove')(touch(0,100));await events.get('touchend')(touch(0,100));assert.equal(refreshes,1);win.scrollY=0;
events.get('touchstart')(touch(0,0));events.get('touchmove')(touch(0,100));allowed=false;await events.get('touchend')(touch(0,100));assert.equal(refreshes,1);
// The shipped refresh action must advance the cursor, not reload the page or
// reset to the first channels. Failures keep the previously accepted cursor.
const calls=[],messages=[];let ok=true;
const scope=vm.createContext({t:value=>value,state:{route:'home',videos:[{id:'abcdefghijk'}],homeNextPage:'next-six'},account:{signedIn:true},toast:s=>messages.push(s),subscriptionHome:async(...args)=>{calls.push(args);return ok},catalog(){},home(){}});
new vm.Script(appClient.slice(appClient.indexOf('async function refreshHome(){'),appClient.indexOf('async function subscriptionHome('))).runInContext(scope);
await scope.refreshHome();assert.deepEqual(calls[0],['next-six',false,true]);assert.equal(messages.pop(),'Новых видео пока нет');
scope.state.homeNextPage='';await scope.refreshHome();assert.equal(calls[1][0],'');
scope.state.homeLoading=true;await scope.refreshHome();assert.equal(calls.length,2);scope.state.homeLoading=false;
ok=false;messages.length=0;await scope.refreshHome();assert.equal(messages.length,0);
console.log('PASS: top-only pull threshold, horizontal/scroll/navigation cancellation, next-batch refresh, end wrap, concurrent-load guard and truthful unchanged feedback');
