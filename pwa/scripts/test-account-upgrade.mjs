import assert from 'node:assert/strict';
import {youtubeAccountResponse,sealAccount,openAccount} from '../worker/youtube-account.js';
const origin='https://axrtube.axrbarsic.workers.dev';
const env={GOOGLE_OAUTH_ENABLED:'true',GOOGLE_OAUTH_PERSONAL_HOME_ENABLED:'true',GOOGLE_OAUTH_CLIENT_ID:'123-test.apps.googleusercontent.com',GOOGLE_OAUTH_CLIENT_SECRET:'test-only',GOOGLE_OAUTH_COOKIE_KEY:'02'.repeat(32)};
const readonly='https://www.googleapis.com/auth/youtube.readonly',full='https://www.googleapis.com/auth/youtube.force-ssl';
const epoch='e'.repeat(43),prefix='__Host-axr-yt-';
const oldSession=await sealAccount(env,'session',{epoch,token:'old-private-test-token',expires:Date.now()+60000});
const oldCookies=prefix+'epoch='+epoch+'; '+prefix+'session='+oldSession;
const req=(path,options={},config=env)=>youtubeAccountResponse(new Request(origin+path,options),config);
const post={method:'POST',headers:{origin,cookie:oldCookies}};
const cookies=r=>r.headers.getSetCookie().map(c=>c.split(';')[0]).join('; ');
assert.equal((await req('/oauth/google/start?recommendations=1',post,{...env,GOOGLE_OAUTH_PERSONAL_HOME_ENABLED:'false'})).status,503);
assert.equal((await req('/oauth/google/start?recommendations=1',{method:'POST',headers:{origin:'https://evil.test'}})).status,403);
const normal=await req('/oauth/google/start',post);
assert.equal(new URL(normal.headers.get('location')).searchParams.get('scope'),readonly+' '+full);
const readonlyStart=await req('/oauth/google/start?readonly=1',post);assert.equal(new URL(readonlyStart.headers.get('location')).searchParams.get('scope'),readonly);
const start=await req('/oauth/google/start?recommendations=1',post),auth=new URL(start.headers.get('location'));
assert.equal(auth.searchParams.get('scope'),readonly+' '+full);
assert.equal(auth.searchParams.get('prompt'),'consent select_account');
assert.equal(auth.searchParams.get('access_type'),'offline');
assert.equal(auth.searchParams.get('code_challenge_method'),'S256');
assert(!start.headers.getSetCookie().some(c=>c.startsWith(prefix+'session=')));
assert(start.headers.getSetCookie().some(c=>c.startsWith(prefix+'epoch='+epoch+';')));
const pending=cookies(start)+'; '+prefix+'session='+oldSession,state=auth.searchParams.get('state');
const denied=await req('/oauth/google/callback?error=access_denied&state='+state,{headers:{cookie:pending}});
assert.equal(denied.headers.get('location'),'/?auth=denied#you');
assert(!denied.headers.getSetCookie().some(c=>c.startsWith(prefix+'session=')));
const logout=await req('/oauth/google/logout',post),newEpoch=logout.headers.getSetCookie().find(c=>c.startsWith(prefix+'epoch=')).split(';')[0];
const stale=pending.replace(prefix+'epoch='+epoch,newEpoch);
assert.equal((await req('/oauth/google/callback?code=test&state='+state,{headers:{cookie:stale}})).status,400);
const originalFetch=globalThis.fetch;
try{
 for(const [scope,authorized]of [[readonly,false],[full,true],[readonly+' '+full,true]]){
  globalThis.fetch=async()=>new Response(JSON.stringify({token_type:'Bearer',access_token:'new-private-test-token',expires_in:7200,scope,refresh_token:'never-retain-this'}));
  const callback=await req('/oauth/google/callback?code=test&state='+state,{headers:{cookie:pending}});
  assert.equal(callback.headers.get('location'),authorized?'/#you':'/?auth=partial#you');
  const value=callback.headers.getSetCookie().find(c=>c.startsWith(prefix+'session=')).split(';')[0].slice((prefix+'session=').length);
  const session=await openAccount(env,'session',value);
  assert.equal(session.recommendationsAuthorized,authorized);
  assert.notEqual(session.epoch,epoch);assert.equal(session.refresh_token,undefined);
  assert(session.expires<=Date.now()+3600000);
  assert(!JSON.stringify(session).includes('never-retain-this'));
  assert(!(await callback.text()).includes('new-private-test-token'));
 }
}finally{globalThis.fetch=originalFetch;}
console.log('PASS: unified login scopes, explicit readonly alternative, offline consent/PKCE, cancellation preserves session, account-switch binding, logout invalidation and actual granted scopes');
