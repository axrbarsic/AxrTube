import assert from 'node:assert/strict';
import {sealAccount,openAccount,youtubeAccountResponse} from '../worker/youtube-account.js';
import app from '../worker/index.js';
const origin='https://axrtube.axrbarsic.workers.dev';
const env={GOOGLE_OAUTH_ENABLED:'true',GOOGLE_OAUTH_CLIENT_ID:'123-test.apps.googleusercontent.com',GOOGLE_OAUTH_CLIENT_SECRET:'test-only-secret',GOOGLE_OAUTH_COOKIE_KEY:'01'.repeat(32)};
const response=(path,options={})=>youtubeAccountResponse(new Request(origin+path,options),env);
const cookieHeader=res=>res.headers.getSetCookie().map(c=>c.split(';')[0]).join('; ');
const sessionName='__Host-axr-yt-session',epochName='__Host-axr-yt-epoch';
const plain={token:'private-test-access-token',epoch:'test-epoch',expires:Date.now()+60000};
assert.equal((await youtubeAccountResponse(new Request(origin+'/api/account'),{...env,GOOGLE_OAUTH_ENABLED:'false'})).status,503);
const sealed=await sealAccount(env,'session',plain);
assert(!sealed.includes(plain.token));assert.deepEqual(await openAccount(env,'session',sealed),plain);
assert.equal(await openAccount(env,'pending',sealed),null);assert.equal(await openAccount(env,'session',sealed+'x'),null);
assert.equal(await openAccount(env,'session',await sealAccount(env,'session',{...plain,expires:1})),null);
assert.equal((await response('/oauth/google/start')).status,405);
// HTML form POSTs under no-referrer send Origin:null. Fix the document policy,
// never accept an opaque/missing/foreign origin to work around that browser rule.
for(const path of ['/']){
  const page=await app.fetch(new Request(origin+path));
  assert.equal(page.headers.get('referrer-policy'),'same-origin');
  assert(!/<meta[^>]+name=["']referrer["']/i.test(await page.text()));
}
for(const path of ['/oauth/google/start','/oauth/google/logout']){
  for(const headers of [{},{origin:'null'},{origin:'https://evil.test'},{origin,'sec-fetch-site':'cross-site'}]){
    assert.equal((await response(path,{method:'POST',headers})).status,403);
  }
}
assert.equal((await response('/oauth/google/start',{method:'POST',headers:{origin:'https://evil.test'}})).status,403);
assert.equal((await response('/oauth/google/callback?code=x&state=x')).status,400);
const start=await response('/oauth/google/start',{method:'POST',headers:{origin}});assert.equal(start.status,303);
assert.equal(start.headers.get('referrer-policy'),'no-referrer');
assert.equal((await app.fetch(new Request(origin+'/oauth/google/start',{method:'POST',headers:{origin}}),env)).status,303);
const auth=new URL(start.headers.get('location'));assert.equal(auth.origin,'https://accounts.google.com');assert.equal(auth.searchParams.get('scope'),'https://www.googleapis.com/auth/youtube.readonly');assert.equal(auth.searchParams.get('code_challenge_method'),'S256');
for(const c of start.headers.getSetCookie()){assert(c.includes('HttpOnly'));assert(c.includes('Secure'));assert(c.includes('SameSite=Lax'));}
const pendingCookies=cookieHeader(start),state=auth.searchParams.get('state');
const oldFetch=globalThis.fetch;let exchanges=0;
try{
globalThis.fetch=async(url,options)=>{
  assert.equal(String(url),'https://oauth2.googleapis.com/token');exchanges++;
  const p=new URLSearchParams(options.body);assert.equal(p.get('grant_type'),'authorization_code');assert.equal(p.get('code'),'test-code');assert.equal(p.get('code_verifier').length,43);
  return new Response(JSON.stringify({access_token:plain.token,token_type:'Bearer',expires_in:3600,scope:'https://www.googleapis.com/auth/youtube.readonly',refresh_token:'must-not-store'}));
};
assert.equal((await response('/oauth/google/callback?code=test-code&state=wrong',{headers:{cookie:pendingCookies}})).status,400);assert.equal(exchanges,0);
const callback=await response('/oauth/google/callback?code=test-code&state='+state,{headers:{cookie:pendingCookies}});assert.equal(exchanges,1);assert.equal(callback.status,303);assert.equal(callback.headers.get('location'),'/#you');
const createdCookie=callback.headers.getSetCookie().find(c=>c.startsWith(sessionName+'='));assert(createdCookie);assert(!createdCookie.includes(plain.token));assert(!createdCookie.includes('must-not-store'));
const values=Object.fromEntries(pendingCookies.split('; ').map(c=>{const at=c.indexOf('=');return [c.slice(0,at),c.slice(at+1)]}));
const sessionValue=createdCookie.split(';')[0].slice(sessionName.length+1);const decoded=await openAccount(env,'session',sessionValue);assert.equal(decoded.token,plain.token);assert.equal(decoded.refresh_token,undefined);
const callbackEpoch=callback.headers.getSetCookie().find(c=>c.startsWith(epochName+'=')).split(';')[0];
assert.notEqual(callbackEpoch,epochName+'='+values[epochName]);
const sessionCookie=sessionName+'='+sessionValue+'; '+callbackEpoch;
globalThis.fetch=async(url,options)=>{assert.equal(options.headers.authorization,'Bearer '+plain.token);assert.equal(new URL(url).origin,'https://www.googleapis.com');return new Response(JSON.stringify({items:[{id:'UCkSKeRJBl41I1nDNaa7lNrw',snippet:{title:'Test channel'}}]}));};
const profile=await response('/api/account',{headers:{cookie:sessionCookie}});const profileText=await profile.text();assert(!profileText.includes(plain.token));assert(JSON.parse(profileText).signedIn);
// No cookie mutation on ordinary reads, so late data responses cannot restore login.
assert.equal(profile.headers.getSetCookie().length,0);
const logout=await response('/oauth/google/logout',{method:'POST',headers:{origin,cookie:sessionCookie}});
const newEpoch=logout.headers.getSetCookie().find(c=>c.startsWith(epochName+'=')).split(';')[0];
const stale=await response('/api/account',{headers:{cookie:createdCookie.split(';')[0]+'; '+newEpoch}});assert.equal((await stale.json()).signedIn,false);
assert.equal((await response('/api/account/subscriptions')).status,401);
assert.equal((await response('/oauth/google/logout',{method:'POST',headers:{origin:'https://evil.test'}})).status,403);
}finally{globalThis.fetch=oldFetch;}
console.log('PASS: OAuth state/PKCE, origin, encrypted/purpose-bound/expiring cookies, HttpOnly flags, token non-disclosure, read-only session and logout epoch');
