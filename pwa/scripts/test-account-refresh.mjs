import assert from 'node:assert/strict';
import {sealAccount,openAccount,youtubeAccountResponse} from '../worker/youtube-account.js';
const origin='https://axrtube.axrbarsic.workers.dev',prefix='__Host-axr-yt-';
const env={GOOGLE_OAUTH_ENABLED:'true',GOOGLE_OAUTH_PERSONAL_HOME_ENABLED:'true',GOOGLE_OAUTH_CLIENT_ID:'123-test.apps.googleusercontent.com',GOOGLE_OAUTH_CLIENT_SECRET:'test-only',GOOGLE_OAUTH_COOKIE_KEY:'03'.repeat(32)};
const full='https://www.googleapis.com/auth/youtube.force-ssl',epoch='e'.repeat(43),refreshToken='test-private-refresh-token';
const expires=Date.now()+180*86400000;
const sealed=await sealAccount(env,'refresh',{epoch,token:refreshToken,recommendationsAuthorized:true,expires});
const cookie=prefix+'epoch='+epoch+'; '+prefix+'refresh='+sealed;
const req=(path='/api/account',cookies=cookie,options={})=>youtubeAccountResponse(new Request(origin+path,{headers:{cookie:cookies,...options.headers},...options}),env,null,async token=>{assert.equal(token,'fresh-private-access-token');return Response.json({source:'youtube-personal-home',personalized:true,videos:[]})});
const originalFetch=globalThis.fetch;let exchanges=0,mode='success',release;
globalThis.fetch=async(url,options)=>{
 if(String(url)==='https://oauth2.googleapis.com/token'){
  exchanges++;assert.equal(options.redirect,'manual');const body=new URLSearchParams(options.body);assert.equal(body.get('grant_type'),'refresh_token');assert.equal(body.get('refresh_token'),refreshToken);
  if(mode==='network')throw Error('Network down');if(mode==='revoked')return Response.json({error:'invalid_grant'},{status:400});if(mode==='server')return Response.json({error:'temporarily_unavailable'},{status:503});
  if(mode==='wait')await new Promise(resolve=>release=resolve);
  return Response.json({token_type:'Bearer',access_token:'fresh-private-access-token',expires_in:3600,...(mode==='downgrade'?{scope:'https://www.googleapis.com/auth/youtube.readonly'}:{})});
 }
 assert.equal(new URL(url).origin,'https://www.googleapis.com');assert.equal(options.headers.authorization,'Bearer fresh-private-access-token');return Response.json({items:[{snippet:{title:'Test account'}}]});
};
try{
 const r=await req(),data=await r.json();assert.equal(data.signedIn,true);assert.equal(data.remembered,true);assert.equal(data.recommendationsAuthorized,true);assert(!JSON.stringify(data).includes('private'));
 const sessionCookie=r.headers.getSetCookie().find(c=>c.startsWith(prefix+'session='));assert(sessionCookie.includes('HttpOnly'));assert(sessionCookie.includes('Max-Age=3600'));assert(!sessionCookie.includes('private'));
 const value=sessionCookie.split(';')[0].slice((prefix+'session=').length),session=await openAccount(env,'session',value);assert.equal(session.refresh_token,undefined);
 const restored=cookie+'; '+prefix+'session='+value;const before=exchanges;await req('/api/account',restored);assert.equal(exchanges,before); // ordinary reload
 const realNow=Date.now;try{const later=realNow()+7200000;Date.now=()=>later;assert.equal((await(await req('/api/account',restored)).json()).signedIn,true)}finally{Date.now=realNow} // restart two hours later
 await req('/api/account/home');assert.equal(exchanges,before+2); // absent/expired access cookie renewed for home too
 for(const transient of ['network','server']){mode=transient;const failed=await req();assert.equal(failed.status,503);assert.equal(failed.headers.getSetCookie().length,0);assert.equal((await failed.json()).signedIn,undefined)}
 mode='success';assert.equal((await(await req()).json()).signedIn,true);
 mode='wait';const startCount=exchanges,one=req(),two=req();await new Promise(resolve=>setTimeout(resolve,30));assert.equal(typeof release,'function');assert.equal(exchanges,startCount+1);release();await Promise.all([one,two]);assert.equal(exchanges,startCount+1);
 mode='downgrade';assert.equal((await(await req()).json()).recommendationsAuthorized,false);
 mode='revoked';const revoked=await req();assert.equal(revoked.status,401);assert.equal((await revoked.json()).code,'SESSION_REVOKED');assert(revoked.headers.getSetCookie().some(c=>c.startsWith(prefix+'refresh=;')));
 mode='success';const oldCount=exchanges;const logout=await req('/oauth/google/logout',cookie,{method:'POST',headers:{origin,cookie}});const newEpoch=logout.headers.getSetCookie().find(c=>c.startsWith(prefix+'epoch=')).split(';')[0];const late=await req('/api/account',newEpoch+'; '+prefix+'refresh='+sealed);assert.equal((await late.json()).signedIn,false);assert.equal(exchanges,oldCount);
 assert.equal((await req('/api/account',cookie.replace(epoch,'z'.repeat(43)))).status,200);assert.equal(exchanges,oldCount);
 assert.equal(await openAccount(env,'session',sealed),null);
 // End-to-end synthetic grant: both scopes requested in a single login and
 // durable credentials issued only after a valid callback, never in JSON.
 globalThis.fetch=async(url,options)=>{assert.equal(String(url),'https://oauth2.googleapis.com/token');assert.equal(new URLSearchParams(options.body).get('grant_type'),'authorization_code');return Response.json({access_token:'new-private-access-token',refresh_token:refreshToken,token_type:'Bearer',scope:full,expires_in:3600,refresh_token_expires_in:604800})};
 const start=await req('/oauth/google/start','',{method:'POST',headers:{origin}}),auth=new URL(start.headers.get('location'));assert.equal(auth.searchParams.get('access_type'),'offline');assert(auth.searchParams.get('scope').includes(full));
 const pending=start.headers.getSetCookie().map(c=>c.split(';')[0]).join('; ');const callback=await req('/oauth/google/callback?code=test&state='+auth.searchParams.get('state'),pending);
 const newBinding=callback.headers.getSetCookie().find(c=>c.startsWith(prefix+'epoch=')).split(';')[0].slice((prefix+'epoch=').length);
 const rememberedName=prefix+'refresh-'+newBinding,rememberedCookie=callback.headers.getSetCookie().find(c=>c.startsWith(rememberedName+'='));assert(rememberedCookie.includes('Max-Age=604800'));assert(rememberedCookie.includes('HttpOnly'));assert(!rememberedCookie.includes(refreshToken));
 const decoded=await openAccount(env,'refresh',rememberedCookie.split(';')[0].slice(rememberedName.length+1));assert.equal(decoded.token,refreshToken);assert.equal(decoded.recommendationsAuthorized,true);assert(decoded.expires<=Date.now()+604800000);
}finally{globalThis.fetch=originalFetch}
console.log('PASS: reload without reauth, automatic access renewal, home renewal, encrypted refresh isolation, transient preservation, concurrent single-flight, scope downgrade, revocation and logout binding');
